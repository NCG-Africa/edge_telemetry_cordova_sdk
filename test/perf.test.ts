// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { EdgeRumEvent, EdgeRumOptions } from '../src/core';

type Fn = (...a: unknown[]) => void;
interface Call { action: string; args: unknown[] }

// web-vitals needs a real browser; the test plays the WebView by calling back itself.
const vitals = vi.hoisted(() => ({} as Record<string, Fn>));
vi.mock('web-vitals', () =>
  Object.fromEntries(['onLCP', 'onINP', 'onCLS', 'onFCP', 'onTTFB'].map((n) => [n, (cb: Fn) => (vitals[n] = cb)])),
);

// Spec Q1: a fake cordova.js shaped like the real one (cordova.js callbacks + callbackFromNative,
// iOS exec.js posting [callbackId, service, action, args] to the message handler).
async function load({ opts, nav, android = false }: { opts?: EdgeRumOptions; nav?: object; android?: boolean } = {}) {
  vi.resetModules();
  for (const k of Object.keys(vitals)) delete vitals[k];
  history.replaceState(null, '', '/');
  const calls: Call[] = [];
  const plugin: { id: string; service: string; action: string }[] = [];
  const native = (id: string, service: string, action: string, args: unknown[]) => {
    if (service !== 'EdgeRum') return plugin.push({ id, service, action });
    calls.push({ action, args });
    if (action !== 'subscribe') c.callbackFromNative(id, true, 1, [action === 'getState' ? { enabled: true, sessionId: 's1' } : undefined], false);
  };
  const c = {
    platformId: android ? 'android' : 'ios',
    callbackId: 1000,
    callbacks: {} as Record<string, { success?: Fn; fail?: Fn }>,
    callbackFromNative(id: string, isSuccess: boolean, _status: number, args: unknown[], keep: boolean) {
      const cb = c.callbacks[id];
      if (!cb) return;
      if (!keep) delete c.callbacks[id];
      (isSuccess ? cb.success : cb.fail)?.(...args);
    },
    require: (name: string) => {
      if (android && name === 'cordova/android/nativeapiprovider') return provider;
      throw new Error(`module ${name} not found`);
    },
    exec(ok: Fn, fail: Fn, service: string, action: string, args: unknown[]) {
      const id = service + c.callbackId++;
      c.callbacks[id] = { success: ok, fail };
      if (android) provider.get().exec('secret', service, action, id, JSON.stringify(args));
      else handler.postMessage([id, service, action, args]); // bound per load: earlier loads' listeners still fire
    },
  };
  let api: { exec: (s: unknown, service: string, action: string, id: string, args: string) => void } = {
    exec: (_s, service, action, id, args) => native(id, service, action, JSON.parse(args)),
  };
  const provider = { get: () => api, set: (a: typeof api) => (api = a) };
  const handler = { postMessage: ([id, service, action, args]: [string, string, string, unknown[]]) => native(id, service, action, args) };
  (window as unknown as Webkit).webkit = { messageHandlers: { cordova: handler } };
  (globalThis as { cordova?: unknown }).cordova = c;
  ticks = [];
  window.requestAnimationFrame = (cb: FrameRequestCallback) => ticks.push(cb);
  vi.spyOn(performance, 'getEntriesByType').mockReturnValue(nav ? [nav as PerformanceEntry] : []);
  const mod = await import('../src/index');
  const core = await import('../src/core');
  if (opts) mod.init(opts);
  document.dispatchEvent(new Event('deviceready'));
  vi.advanceTimersByTime(100); // the initial screen
  const named = (name: string) => {
    core.flush();
    return calls.filter((x) => x.action === 'enqueue').flatMap((x) => (x.args[0] as { events: EdgeRumEvent[] }).events).filter((e) => (e.eventName ?? e.metricName) === name);
  };
  /** A plugin call; returns its native answer. */
  const plugCall = (service = 'Camera', action = 'take') => {
    c.exec(() => {}, () => {}, service, action, []);
    const p = plugin[plugin.length - 1];
    return (ok = true) => c.callbackFromNative(p.id, ok, ok ? 1 : 9, [], false);
  };
  return { mod, calls, named, plugCall, attrs: (name: string) => named(name).map((e) => {
    const a = { ...e.attributes };
    delete a['session.id'];
    return a;
  }) };
}
interface Webkit { webkit: { messageHandlers: { cordova: object } } }

let ticks: FrameRequestCallback[] = [];
/** Run one rAF tick at time `t`. */
const frame = (t: number) => ticks.splice(0).forEach((cb) => cb(t));
const leaveScreen = () => {
  history.pushState(null, '', `/next${Math.random()}`);
  vi.advanceTimersByTime(100);
};
let visibility = 'visible';
Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => visibility });

beforeEach(() => {
  vi.useFakeTimers();
  visibility = 'visible';
});
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe('app.start phases (A5)', () => {
  it('sends responseEnd / DOMContentLoaded / load from navigation timing, then deviceready', async () => {
    const before = Date.now();
    const t = await load({ nav: { responseEnd: 120.4, domContentLoadedEventStart: 300, loadEventStart: 0 } });
    const marks = t.calls.filter((c) => c.action === 'markPhase').map((c) => c.args[0] as { phase: string; ts: number });
    expect(marks.map((m) => m.phase)).toEqual(['responseEnd', 'DOMContentLoaded', 'deviceready']); // load not reached yet
    expect(marks[0].ts).toBe(Math.round(performance.timeOrigin + 120.4));
    expect(marks[2].ts).toBeGreaterThanOrEqual(before - 1);
  });

  it('a phase known after deviceready (slow load) is sent once, when it lands', async () => {
    const nav = { responseEnd: 100, domContentLoadedEventStart: 200, loadEventStart: 0 };
    const t = await load({ nav });
    nav.loadEventStart = 5000;
    window.dispatchEvent(new Event('load'));
    window.dispatchEvent(new Event('load'));
    const phases = t.calls.filter((c) => c.action === 'markPhase').map((c) => (c.args[0] as { phase: string }).phase);
    expect(phases).toEqual(['responseEnd', 'DOMContentLoaded', 'deviceready', 'load']);
  });

  it('falls back to legacy performance.timing (already epoch ms)', async () => {
    Object.defineProperty(performance, 'timing', { configurable: true, value: { responseEnd: 1000, domContentLoadedEventStart: 2000, loadEventStart: 3000 } });
    const t = await load();
    delete (performance as { timing?: unknown }).timing;
    expect(t.calls.filter((c) => c.action === 'markPhase').slice(0, 3).map((c) => c.args[0])).toEqual([
      { phase: 'responseEnd', ts: 1000 },
      { phase: 'DOMContentLoaded', ts: 2000 },
      { phase: 'load', ts: 3000 },
    ]);
  });
});

describe('frame.summary (E20)', () => {
  it('one window per screen: counts, slow / frozen, max, rate, then a fresh window', async () => {
    const t = await load();
    for (const at of [0, 16, 32, 82, 900, 916]) frame(at); // gaps 16 16 50 818 16
    leaveScreen();
    expect(t.attrs('frame.summary')).toEqual([{
      'screen.name': '/',
      'frame.total_frames': 5,
      'frame.slow_frames': 2,
      'frame.frozen_frames': 1,
      'frame.max_total_duration_ms': 818,
      'frame.slow_frame_rate': 0.4,
      'frame.window_duration_ms': 916,
      'frame.source': 'raf',
    }]);
    frame(1000);
    frame(1016);
    leaveScreen();
    expect(t.attrs('frame.summary').map((a) => a['frame.total_frames'])).toEqual([5, 1]); // first tick after a window opens a gap, not a frame
  });

  it('hidden time is never a frame, and hiding ends the window', async () => {
    const t = await load();
    frame(0);
    frame(16);
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    expect(t.attrs('frame.summary')).toMatchObject([{ 'frame.total_frames': 1 }]);
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    frame(60_000);
    frame(60_016);
    leaveScreen();
    expect(t.attrs('frame.summary').at(-1)).toMatchObject({ 'frame.total_frames': 1, 'frame.frozen_frames': 0 });
  });

  it('honours frameSlowThresholdMs and captureFrames: false', async () => {
    let t = await load({ opts: { frameSlowThresholdMs: 17 } });
    frame(0);
    frame(18);
    leaveScreen();
    expect(t.attrs('frame.summary')[0]['frame.slow_frames']).toBe(1);
    t = await load({ opts: { captureFrames: false } });
    expect(ticks).toEqual([]);
  });
});

describe('bridge timing (E18, E19)', () => {
  it('bridge.summary per service + action with nearest-rank p50 / p95 / max; EdgeRum excluded', async () => {
    const t = await load();
    for (let ms = 1; ms <= 20; ms++) {
      const answer = t.plugCall();
      vi.advanceTimersByTime(ms);
      answer(ms !== 20);
    }
    t.plugCall('Device', 'getInfo')();
    t.plugCall('CoreAndroid', 'messageChannel'); // platform keep-callback: never timed
    vi.advanceTimersByTime(30_000);
    leaveScreen();
    expect(t.attrs('bridge.summary')).toEqual([
      { 'screen.name': '/', 'bridge.service': 'Camera', 'bridge.action': 'take', 'bridge.count': 20, 'bridge.error_count': 1, 'bridge.p50_ms': 10, 'bridge.p95_ms': 19, 'bridge.max_ms': 20 },
      { 'screen.name': '/', 'bridge.service': 'Device', 'bridge.action': 'getInfo', 'bridge.count': 1, 'bridge.error_count': 0, 'bridge.p50_ms': 0, 'bridge.p95_ms': 0, 'bridge.max_ms': 0 },
    ]);
    leaveScreen();
    expect(t.attrs('bridge.summary')).toHaveLength(2); // window reset
  });

  it('bridge.call outcomes: slow ≥ slowBridgeCallMs, error, no_callback after 30 s (late answer ignored)', async () => {
    const t = await load({ opts: { slowBridgeCallMs: 500 } });
    let answer = t.plugCall();
    vi.advanceTimersByTime(499);
    answer(); // fast: no single row
    answer = t.plugCall();
    vi.advanceTimersByTime(500);
    answer();
    t.plugCall('File', 'read')(false);
    const never = t.plugCall('Geo', 'watch');
    vi.advanceTimersByTime(30_000);
    never();
    expect(t.attrs('bridge.call')).toEqual([
      { 'bridge.service': 'Camera', 'bridge.action': 'take', 'bridge.duration_ms': 500, 'bridge.outcome': 'slow' },
      { 'bridge.service': 'File', 'bridge.action': 'read', 'bridge.duration_ms': 0, 'bridge.outcome': 'error' },
      { 'bridge.service': 'Geo', 'bridge.action': 'watch', 'bridge.duration_ms': 30_000, 'bridge.outcome': 'no_callback' },
    ]);
    leaveScreen();
    expect(t.attrs('bridge.summary').map((a) => a['bridge.service'])).toEqual(['Camera', 'File']);
  });

  it('reads the action on Android from the native API provider; captureBridge: false times nothing', async () => {
    let t = await load({ android: true });
    t.plugCall('Base64', 'encode')();
    leaveScreen();
    expect(t.attrs('bridge.summary')).toMatchObject([{ 'bridge.service': 'Base64', 'bridge.action': 'encode', 'bridge.count': 1 }]);
    t = await load({ opts: { captureBridge: false } });
    t.plugCall()(false);
    leaveScreen();
    expect([...t.attrs('bridge.summary'), ...t.attrs('bridge.call')]).toEqual([]);
  });
});

describe('Web Vitals (E21)', () => {
  it('each supported vital → a metric named after it; captureVitals: false registers none', async () => {
    let t = await load();
    vitals.onLCP({ name: 'LCP', value: 1234.5, rating: 'good' });
    vitals.onCLS({ name: 'CLS', value: 0.12, rating: 'needs-improvement' });
    expect(t.named('LCP')).toMatchObject([{ type: 'metric', value: 1234.5, attributes: { 'metric.unit': 'ms', 'metric.rating': 'good', 'metric.screen': '/' } }]);
    expect(t.named('CLS')[0].attributes['metric.unit']).toBe('score');
    t = await load({ opts: { captureVitals: false } });
    expect(Object.keys(vitals)).toEqual([]);
  });
});
