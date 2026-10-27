import { breadcrumb, live, now, record, state, whenReady, type Attributes } from './core';

// P1: all digits, canonical UUID, or ≥ 20 hex.
const ID = /^(?:\d+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{20,})$/i;
const template = (path: string) => path.split('/').map((s) => (ID.test(s) ? '{id}' : s)).join('/');

const absolute = (url: string) => {
  try {
    return new URL(url, location.href);
  } catch {
    return undefined;
  }
};

/**
 * P1: scheme + host + explicit port + templated path; query, fragment and userinfo dropped.
 * Host `sanitizeUrl` runs after and only ever sees the scrubbed form.
 */
export function scrubUrl(url: string): string {
  const u = absolute(url);
  // ponytail: unparseable → cut by hand, as Flutter's redactUnparsedUrl.
  const scrubbed = u ? `${u.protocol}//${u.host}${template(u.pathname)}` : template(url.split(/[?#]/)[0]);
  const sanitize = state.options.sanitizeUrl;
  if (!sanitize) return scrubbed;
  try {
    const out = sanitize(scrubbed);
    return typeof out === 'string' ? out : scrubbed;
  } catch {
    return scrubbed;
  }
}

const matches = (rules: (string | RegExp)[] | undefined, s: string, exact = false) =>
  (rules ?? []).some((r) => (typeof r === 'string' ? (exact ? s === r : s.includes(r)) : r.test(s)));

/** E6: own endpoint and `ignoreUrls` are never captured. */
const ignored = (url: string) => {
  const { endpoint, ignoreUrls } = state.options;
  return (!!endpoint && url.startsWith(endpoint)) || matches(ignoreUrls, url);
};

const hex = (bytes: number) => Array.from(crypto.getRandomValues(new Uint8Array(bytes)), (b) => b.toString(16).padStart(2, '0')).join('');

/** E8: a W3C `traceparent` for hosts in `correlateRequestsTo` only. */
function trace(url: string) {
  const host = absolute(url)?.hostname;
  if (!host || !matches(state.options.correlateRequestsTo, host, true)) return undefined;
  const ids = { 'trace.id': hex(16), 'span.id': hex(8) };
  return { ids, header: `00-${ids['trace.id']}-${ids['span.id']}-01` };
}

/** E6: one `http.request` (N1 keys). Status 0 = no response. P3: no headers, no bodies. */
function report(url: string, method: string, status: number, start: number, ids?: Attributes) {
  const scrubbed = scrubUrl(url);
  method = method.toUpperCase();
  breadcrumb('http', `${method} ${scrubbed} ${status}`);
  record({
    type: 'event',
    eventName: 'http.request',
    timestamp: now(),
    attributes: {
      ...ids,
      'http.url': scrubbed,
      'http.method': method,
      'http.status_code': status,
      'http.duration_ms': Math.round(performance.now() - start),
      'http.success': status >= 200 && status < 400,
    },
  });
}

const capturing = (url: string) => state.options.captureRequests && !ignored(url);

function patchFetch() {
  const original = window.fetch;
  if (!original) return;
  window.fetch = function (input: RequestInfo | URL, init?: RequestInit) {
    const req = typeof Request !== 'undefined' && input instanceof Request ? input : undefined;
    // Resolved, as XHR's: ignore rules see one form whichever API the host used.
    const url = req ? req.url : absolute(String(input))?.href ?? String(input);
    if (!capturing(url)) return original.call(this, input, init);
    const method = init?.method ?? req?.method ?? 'GET';
    // no-cors forbids non-safelisted headers: adding one would make fetch throw.
    const t = (init?.mode ?? req?.mode) === 'no-cors' ? undefined : trace(url);
    if (t) {
      // A copy: the host's Headers / Request are never mutated. Their own traceparent wins.
      const headers = new Headers(init?.headers ?? req?.headers);
      if (!headers.has('traceparent')) {
        headers.set('traceparent', t.header);
        init = { ...init, headers };
      }
    }
    const start = performance.now();
    return original.call(this, input, init).then(
      (res) => {
        report(url, method, res.status, start, t?.ids);
        return res;
      },
      (err: unknown) => {
        report(url, method, 0, start, t?.ids);
        throw err;
      },
    );
  };
}

interface Pending { method: string; url: string; start: number; hasTrace?: boolean; ids?: Attributes }
type Xhr = XMLHttpRequest & { __edgeRum?: Pending; __edgeRumListening?: boolean };

function patchXhr() {
  const proto = window.XMLHttpRequest?.prototype as Xhr | undefined;
  if (!proto) return;
  const { open, send, setRequestHeader } = proto;
  proto.open = function (this: Xhr, method: string, url: string | URL) {
    this.__edgeRum = { method, url: absolute(String(url))?.href ?? String(url), start: 0 };
    // eslint-disable-next-line prefer-rest-params -- forwarded verbatim (sync/user/password overloads)
    return open.apply(this, arguments as unknown as Parameters<typeof open>);
  } as typeof open;
  proto.setRequestHeader = function (this: Xhr, name: string, value: string) {
    if (this.__edgeRum && name.toLowerCase() === 'traceparent') this.__edgeRum.hasTrace = true;
    return setRequestHeader.call(this, name, value);
  };
  proto.send = function (this: Xhr, body?: Document | XMLHttpRequestBodyInit | null) {
    const p = this.__edgeRum;
    if (p && capturing(p.url)) {
      const t = p.hasTrace ? undefined : trace(p.url);
      if (t) setRequestHeader.call(this, 'traceparent', t.header);
      p.ids = t?.ids;
      p.start = performance.now();
      // One listener per instance: a reused XHR would otherwise report N times.
      if (!this.__edgeRumListening) {
        this.__edgeRumListening = true;
        this.addEventListener('loadend', () => {
          const done = this.__edgeRum;
          this.__edgeRum = undefined;
          if (done) report(done.url, done.method, this.status, done.start, done.ids);
        });
      }
    } else this.__edgeRum = undefined;
    return send.call(this, body);
  };
}

/** E7: one `resource_timing` metric per finished resource, when opted in. */
function observeResources() {
  if (typeof PerformanceObserver === 'undefined' || !PerformanceObserver.supportedEntryTypes?.includes('resource')) return;
  new PerformanceObserver((list) => {
    if (!state.options.captureResourceTiming) return;
    for (const r of list.getEntries() as PerformanceResourceTiming[]) {
      if (ignored(r.name)) continue;
      record({
        type: 'metric',
        metricName: 'resource_timing',
        value: Math.round(r.duration),
        timestamp: now(),
        attributes: { 'resource.url': scrubUrl(r.name), 'resource.initiator_type': r.initiatorType },
      });
    }
  }).observe({ type: 'resource', buffered: true });
}

if (live) {
  patchFetch();
  patchXhr();
  // At deviceready, so `buffered` replays page-load entries into a pre-deviceready `init()`'s choice.
  whenReady(observeResources);
}
