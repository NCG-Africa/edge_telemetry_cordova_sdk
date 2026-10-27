// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { EdgeRumEvent } from '../src/core';

type Ok = (r?: unknown) => void;
interface Payload { events: EdgeRumEvent[]; breadcrumbs: { category: string; message: string }[] }

/** Minimal XHR: records headers, `finish(status)` fires loadend like a real one. */
class FakeXhr extends EventTarget {
  status = 0;
  headers: Record<string, string> = {};
  opened: string[] = [];
  open(method: string, url: string) {
    this.opened = [method, url];
  }
  setRequestHeader(name: string, value: string) {
    this.headers[name] = value;
  }
  send() {}
  finish(status: number) {
    this.status = status;
    this.dispatchEvent(new Event('loadend'));
  }
}

// Spec Q1: a fresh module + fake native + fake fetch/XHR per test.
async function load(respond: (url: string) => Promise<Response> = async () => new Response(null, { status: 200 })) {
  vi.resetModules();
  const payloads: Payload[] = [];
  (globalThis as { cordova?: unknown }).cordova = {
    platformId: 'android',
    exec(ok: Ok, _fail: Ok, _service: string, action: string, args: unknown[]) {
      if (action === 'getState') ok({ enabled: true, sessionId: 's1' });
      else if (action === 'enqueue') {
        payloads.push(args[0] as Payload);
        ok();
      } else if (action !== 'subscribe') ok();
    },
  };
  const fetchCalls: { input: unknown; init?: RequestInit }[] = [];
  window.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    fetchCalls.push({ input, init });
    return respond(input instanceof Request ? input.url : String(input));
  };
  window.XMLHttpRequest = class extends FakeXhr {} as unknown as typeof XMLHttpRequest;
  const api = await import('../src/index');
  const network = await import('../src/network');
  document.dispatchEvent(new Event('deviceready'));
  const flushed = () => {
    vi.advanceTimersByTime(2000);
    return payloads;
  };
  const requests = () => flushed().flatMap((p) => p.events).filter((e) => e.eventName === 'http.request');
  const xhr = () => new XMLHttpRequest() as unknown as FakeXhr;
  return { api, network, fetchCalls, requests, flushed, xhr };
}

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

describe('URL scrub (P1)', () => {
  it.each([
    ['https://api.example.com/users?token=abc#frag', 'https://api.example.com/users'],
    ['https://user:pw@api.example.com/a', 'https://api.example.com/a'],
    ['https://api.example.com:8443/orders/12345', 'https://api.example.com:8443/orders/{id}'],
    ['https://api.example.com/u/550e8400-e29b-41d4-a716-446655440000/x', 'https://api.example.com/u/{id}/x'],
    ['https://api.example.com/blob/deadbeefdeadbeefdead', 'https://api.example.com/blob/{id}'],
    ['https://api.example.com/blob/deadbeefdeadbeefdea', 'https://api.example.com/blob/deadbeefdeadbeefdea'],
    ['https://api.example.com/v2/items/abc123', 'https://api.example.com/v2/items/abc123'],
    ['/api/orders/42?x=1', 'http://localhost:3000/api/orders/{id}'],
    ['https://api.example.com:443/a', 'https://api.example.com/a'], // default port: URL drops it, as Dart's Uri
  ])('%s → %s', async (from, to) => {
    const { network } = await load();
    expect(network.scrubUrl(from)).toBe(to);
  });

  it('host sanitizeUrl runs after, on the scrubbed URL; a throwing one is ignored', async () => {
    const { api, network } = await load();
    const seen: string[] = [];
    api.init({ sanitizeUrl: (u) => (seen.push(u), u.replace('/users', '/u')) });
    expect(network.scrubUrl('https://a.com/users/7?q=1')).toBe('https://a.com/u/{id}');
    expect(seen).toEqual(['https://a.com/users/{id}']);
    api.init({ sanitizeUrl: () => { throw new Error('x'); } });
    expect(network.scrubUrl('https://a.com/users/7')).toBe('https://a.com/users/{id}');
  });
});

describe('fetch (E6)', () => {
  it('records http.request with N1 keys and an http breadcrumb', async () => {
    const t = await load(async () => new Response(null, { status: 404 }));
    await window.fetch('https://api.example.com/orders/9?secret=1', { method: 'post', headers: { authorization: 'x' }, body: 'pii' });
    const [r] = t.requests();
    expect(r.attributes).toMatchObject({
      'http.url': 'https://api.example.com/orders/{id}', 'http.method': 'POST', 'http.status_code': 404, 'http.success': false,
    });
    expect(typeof r.attributes['http.duration_ms']).toBe('number');
    expect(JSON.stringify(r)).not.toMatch(/secret|authorization|pii/); // P3
    expect(t.flushed().flatMap((p) => p.breadcrumbs)).toContainEqual(expect.objectContaining({ category: 'http', message: 'POST https://api.example.com/orders/{id} 404' }));
  });

  it('network failure → status 0, success false, error rethrown', async () => {
    const t = await load(async () => { throw new TypeError('Failed to fetch'); });
    await expect(window.fetch('https://api.example.com/x')).rejects.toThrow('Failed to fetch');
    expect(t.requests()[0].attributes).toMatchObject({ 'http.status_code': 0, 'http.success': false, 'http.method': 'GET' });
  });

  it('Request input: method and URL read from it', async () => {
    const t = await load();
    await window.fetch(new Request('https://api.example.com/a', { method: 'PUT' }));
    expect(t.requests()[0].attributes).toMatchObject({ 'http.url': 'https://api.example.com/a', 'http.method': 'PUT', 'http.success': true });
  });

  it('skips ignoreUrls, own endpoint, and everything when captureRequests=false', async () => {
    const t = await load();
    t.api.init({ endpoint: 'https://ingest.example.com/v1', ignoreUrls: ['/health', /analytics\./] });
    await window.fetch('https://ingest.example.com/v1/batch');
    await window.fetch('https://api.example.com/health');
    await window.fetch('https://analytics.example.com/x');
    await window.fetch('https://api.example.com/kept');
    t.api.init({ captureRequests: false });
    await window.fetch('https://api.example.com/off');
    expect(t.requests().map((r) => r.attributes['http.url'])).toEqual(['https://api.example.com/kept']);
    expect(t.fetchCalls).toHaveLength(5); // all still sent
  });
});

describe('traceparent (E8)', () => {
  const TP = /^00-([0-9a-f]{32})-([0-9a-f]{16})-01$/;

  it('off by default: no header, no trace keys', async () => {
    const t = await load();
    await window.fetch('https://api.example.com/a');
    expect(t.fetchCalls[0].init).toBeUndefined();
    expect(t.requests()[0].attributes['trace.id']).toBeUndefined();
  });

  it('only allowlisted hosts (exact or RegExp) get it; ids match the event', async () => {
    const t = await load();
    t.api.init({ correlateRequestsTo: ['api.example.com', /\.internal$/] });
    const host = { 'x-host': 'kept' };
    await window.fetch('https://api.example.com/a', { headers: host });
    await window.fetch('https://svc.internal/b');
    await window.fetch('https://sub.api.example.com/c');
    const [a, b, c] = t.fetchCalls.map((f) => new Headers(f.init?.headers).get('traceparent'));
    const [ra] = t.requests();
    expect(a).toMatch(TP);
    expect(a).toBe(`00-${ra.attributes['trace.id']}-${ra.attributes['span.id']}-01`);
    expect(b).toMatch(TP);
    expect(c).toBeNull();
    await window.fetch('https://api.example.com/opaque', { mode: 'no-cors' });
    expect(new Headers(t.fetchCalls[3].init?.headers).get('traceparent')).toBeNull();
    expect(new Headers(t.fetchCalls[0].init?.headers).get('x-host')).toBe('kept');
    expect(host).toEqual({ 'x-host': 'kept' }); // host's object untouched
  });

  it("host's own traceparent wins", async () => {
    const t = await load();
    t.api.init({ correlateRequestsTo: ['api.example.com'] });
    const mine = '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01';
    await window.fetch('https://api.example.com/a', { headers: { traceparent: mine } });
    expect(new Headers(t.fetchCalls[0].init?.headers).get('traceparent')).toBe(mine);
    const x = t.xhr();
    x.open('GET', 'https://api.example.com/b');
    x.setRequestHeader('traceparent', mine);
    x.send();
    expect(x.headers.traceparent).toBe(mine);
  });

  it('XHR to an allowlisted host gets it', async () => {
    const t = await load();
    t.api.init({ correlateRequestsTo: ['api.example.com'] });
    const x = t.xhr();
    x.open('GET', 'https://api.example.com/a');
    x.send();
    x.finish(200);
    expect(x.headers.traceparent).toMatch(TP);
    expect(t.requests()[0].attributes['span.id']).toBe(TP.exec(x.headers.traceparent)?.[2]);
  });
});

describe('XHR (E6)', () => {
  it('records on loadend; failure → status 0', async () => {
    const t = await load();
    const ok = t.xhr();
    ok.open('delete', '/api/items/77?x=1');
    ok.send();
    ok.finish(204);
    const failed = t.xhr();
    failed.open('GET', 'https://api.example.com/down');
    failed.send();
    failed.finish(0);
    expect(t.requests().map((r) => r.attributes)).toEqual([
      expect.objectContaining({ 'http.url': 'http://localhost:3000/api/items/{id}', 'http.method': 'DELETE', 'http.status_code': 204, 'http.success': true }),
      expect.objectContaining({ 'http.url': 'https://api.example.com/down', 'http.status_code': 0, 'http.success': false }),
    ]);
  });

  it('a reused XHR reports once per send; ignored URLs not at all', async () => {
    const t = await load();
    t.api.init({ ignoreUrls: ['/skip'] });
    const x = t.xhr();
    for (const path of ['/a', '/b', '/skip']) {
      x.open('GET', `https://api.example.com${path}`);
      x.send();
      x.finish(200);
    }
    expect(t.requests().map((r) => r.attributes['http.url'])).toEqual(['https://api.example.com/a', 'https://api.example.com/b']);
  });
});

describe('resource timing (E7)', () => {
  it('opt-in; scrubbed URL, own endpoint skipped', async () => {
    let emit: (entries: object[]) => void = () => {};
    vi.stubGlobal('PerformanceObserver', Object.assign(function (cb: (l: { getEntries: () => object[] }) => void) {
      emit = (entries) => cb({ getEntries: () => entries });
      return { observe() {} };
    }, { supportedEntryTypes: ['resource'] }));
    const t = await load();
    const entries = [
      { name: 'https://cdn.example.com/img/123.png?v=2', duration: 41.6, initiatorType: 'img' },
      { name: 'https://ingest.example.com/v1/batch', duration: 5, initiatorType: 'fetch' },
    ];
    emit(entries);
    t.api.init({ captureResourceTiming: true, endpoint: 'https://ingest.example.com/v1' });
    emit(entries);
    vi.unstubAllGlobals();
    const metrics = t.flushed().flatMap((p) => p.events).filter((e) => e.metricName === 'resource_timing');
    expect(metrics).toEqual([expect.objectContaining({
      type: 'metric', value: 42, attributes: expect.objectContaining({ 'resource.url': 'https://cdn.example.com/img/123.png', 'resource.initiator_type': 'img' }),
    })]);
  });
});
