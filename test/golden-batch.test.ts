// @vitest-environment jsdom
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import type { EdgeRumEvent } from '../src/core';

// #61, spec 2026-11-23 stable goldens: every JS-captured event, recorded through the real SDK (fake
// cordova.js), dumped as handed to `enqueue` to the gitignored `test/golden-raw/js-rows.json`. The
// Android test `JsGoldenTest` stamps and sends them through the real native sender into
// `test/golden-raw/js`; `scripts/conform.sh` runs both, then checks the shape.

const RAW = join(process.cwd(), 'test/golden-raw'); // vitest runs from the repo root

/** Every name JS sends, canonical per the catalogue. */
const JS_EVENTS = [
  'app.crash', 'app.error', 'bridge.call', 'bridge.summary', 'custom.event', 'custom.metric', 'frame.summary',
  'http.request', 'navigation', 'perf.cls', 'perf.fcp', 'perf.inp', 'perf.lcp', 'perf.resource_timing', 'perf.ttfb',
  'screen.duration', 'task.complete', 'ui.interaction',
];

type Fn = (...a: unknown[]) => void;
const vitals = vi.hoisted(() => ({}) as Record<string, Fn>);
vi.mock('web-vitals', () =>
  Object.fromEntries(['onLCP', 'onINP', 'onCLS', 'onFCP', 'onTTFB'].map((n) => [n, (cb: Fn) => (vitals[n] = cb)])),
);

const g = globalThis as Record<string, unknown>;
const recorded = new Map<string, EdgeRumEvent>();
const raf: FrameRequestCallback[] = [];
const observers: { type?: string; cb: (list: { getEntries: () => object[] }) => void }[] = [];

/** cordova.js as on iOS: callbacks + callbackFromNative, exec posting to the message handler. */
function fakeCordova() {
  const plugin: string[] = [];
  const c = {
    platformId: 'ios',
    callbackId: 1000,
    callbacks: {} as Record<string, { success?: Fn; fail?: Fn }>,
    callbackFromNative(id: string, ok: boolean, _status: number, args: unknown[], keep: boolean) {
      const cb = c.callbacks[id];
      if (!keep) delete c.callbacks[id];
      (ok ? cb?.success : cb?.fail)?.(...args);
    },
    exec(ok: Fn, fail: Fn, service: string, action: string, args: unknown[]) {
      const id = service + c.callbackId++;
      c.callbacks[id] = { success: ok, fail };
      handler.postMessage([id, service, action, args]);
    },
  };
  const handler = {
    postMessage([id, service, action, args]: [string, string, string, unknown[]]) {
      if (service !== 'EdgeRum') return plugin.push(id);
      if (action === 'enqueue') for (const e of (args[0] as { events: EdgeRumEvent[] }).events) recorded.set(String(e.eventName ?? e.metricName), e);
      if (action !== 'subscribe') c.callbackFromNative(id, true, 1, [action === 'getState' ? { enabled: true, sessionId: 'session_1' } : undefined], false);
    },
  };
  (window as unknown as { webkit: object }).webkit = { messageHandlers: { cordova: handler } };
  g.cordova = c;
  /** A plugin call answered after `ms`, or never. */
  return (ms: number, ok = true) => {
    c.exec(() => {}, () => {}, 'Camera', 'takePicture', []);
    const id = plugin[plugin.length - 1];
    if (ms >= 0) setTimeout(() => c.callbackFromNative(id, ok, ok ? 1 : 9, [], false), ms);
  };
}

beforeAll(async () => {
  vi.useFakeTimers();
  const plugCall = fakeCordova();
  window.requestAnimationFrame = (cb) => raf.push(cb);
  class FakeObserver {
    static supportedEntryTypes = ['longtask', 'resource'];
    private entry: (typeof observers)[number];
    constructor(cb: (typeof observers)[number]['cb']) {
      this.entry = { cb };
      observers.push(this.entry);
    }
    observe(o: { type?: string }) {
      this.entry.type = o.type;
    }
    disconnect() {}
  }
  g.PerformanceObserver = FakeObserver;
  window.fetch = async () => new Response('{}', { status: 200 });

  const EdgeRum = await import('../src/index');
  EdgeRum.init({ captureResourceTiming: true, release: 'app@1.4.2' });
  document.dispatchEvent(new Event('deviceready'));
  await vi.advanceTimersByTimeAsync(100);

  EdgeRum.trackScreen('/home');
  EdgeRum.trackScreen('/products/:id'); // navigation, and screen.duration for /home
  EdgeRum.track('cart.opened');
  EdgeRum.measure('cart.total', 42.5);
  EdgeRum.startTask('checkout');
  EdgeRum.completeTask('checkout');
  EdgeRum.captureError(new TypeError('handled boom'));
  window.dispatchEvent(new ErrorEvent('error', { error: new Error('boom'), message: 'boom' }));
  await fetch('https://api.example.com/v2/users/42');
  document.body.innerHTML = '<button id="buy">Buy now</button>';
  document.getElementById('buy')?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  plugCall(5);
  plugCall(5, false); // bridge.call, outcome error
  for (const [name, value] of [['LCP', 812.5], ['INP', 96], ['CLS', 0.05], ['FCP', 410], ['TTFB', 120]] as const) {
    vitals[`on${name}`]?.({ name, value, rating: 'good', delta: value, id: 'v1', entries: [], navigationType: 'navigate' });
  }
  for (const o of observers) {
    o.cb({
      getEntries: () => [o.type === 'longtask'
        ? { name: 'self', duration: 120, entryType: 'longtask' }
        : { name: 'https://cdn.example.com/a.js', duration: 80, initiatorType: 'script', transferSize: 2048 }],
    });
  }
  // Three frames, one slow: the window closes on the next screen change.
  for (const ts of [0, 16, 60, 76]) raf.splice(0).forEach((f) => f(ts));
  await vi.advanceTimersByTimeAsync(1100); // the tap's dead-tap window, the plugin calls' answers
  EdgeRum.trackScreen('/cart');
  Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
  document.dispatchEvent(new Event('visibilitychange'));
  await vi.advanceTimersByTimeAsync(0);
});

afterAll(() => {
  vi.useRealTimers();
  delete g.cordova;
});

describe('golden batches (#61, stable goldens)', () => {
  it('JS sends exactly the catalogue names', () => {
    expect([...recorded.keys()].sort()).toEqual(JS_EVENTS);
  });

  it('dumps the rows for the native sender', () => {
    mkdirSync(RAW, { recursive: true });
    writeFileSync(join(RAW, 'js-rows.json'), `${JSON.stringify([...recorded.values()], null, 2)}\n`);
  });
});
