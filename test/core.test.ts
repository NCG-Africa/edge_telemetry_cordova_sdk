// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { EdgeRumEvent } from '../src/core';

type Ok = (r?: unknown) => void;
interface Call { action: string; args: unknown[] }

// Spec Q1: cordova.exec stubbed. Each load gets a fresh module + fake native; the bundle
// captures `cordova` at load, so listeners left by earlier loads talk to their own fake.
async function load({ platformId = 'android', state = {} as object, cordova = true } = {}) {
  vi.resetModules();
  const calls: Call[] = [];
  const native = { failEnqueue: false, throwOnExec: false, subscriber: undefined as Ok | undefined };
  (globalThis as { cordova?: unknown }).cordova = cordova
    ? {
        platformId,
        exec(ok: Ok, fail: Ok, service: string, action: string, args: unknown[]) {
          expect(service).toBe('EdgeRum');
          if (native.throwOnExec) throw new Error('no bridge');
          calls.push({ action, args });
          if (action === 'getState') ok({ enabled: true, sessionId: 's1', sampled: true, configured: true, sdkVersion: '1', deviceStartedAt: 0, ...state });
          else if (action === 'subscribe') native.subscriber = ok;
          else if (action === 'enqueue' && native.failEnqueue) fail('append failed');
          else ok();
        },
      }
    : undefined;
  const api = await import('../src/index');
  const core = await import('../src/core');
  const enqueues = () => calls.filter((c) => c.action === 'enqueue').map((c) => (c.args[0] as { events: EdgeRumEvent[] }).events);
  return {
    api,
    core,
    calls,
    native,
    enqueues,
    events: () => enqueues().flat(),
    ready: () => document.dispatchEvent(new Event('deviceready')),
  };
}

const health = (events: EdgeRumEvent[]) => events.find((e) => e.eventName === 'sdk.health')?.attributes;

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

describe('pre-deviceready buffer (A4)', () => {
  it('holds events until deviceready, then subscribes, pulls state and hands off once', async () => {
    const t = await load();
    t.api.track('a');
    t.api.track('b');
    expect(t.calls).toEqual([]);
    t.ready();
    expect(t.calls.map((c) => c.action)).toEqual(['subscribe', 'getState', 'enqueue']);
    expect(t.calls[2].args).toEqual([{ events: expect.any(Array), breadcrumbs: [] }]);
    expect(t.events().map((e) => e.attributes['event.name'])).toEqual(['a', 'b']);
    expect(t.events()[0].attributes['session.id']).toBe('s1');
  });

  it('caps at 500, dropping oldest, and counts the drops', async () => {
    const t = await load();
    for (let i = 0; i < 505; i++) t.api.track('e' + i);
    t.ready();
    const events = t.events();
    expect(events[0].attributes['event.name']).toBe('e5');
    expect(events.filter((e) => e.eventName === 'custom_event')).toHaveLength(500);
    expect(health(events)).toEqual({ 'events_dropped.js_buffer_full': 5 });
  });

  it('runs bridge calls made before deviceready ahead of the first hand-off', async () => {
    const t = await load();
    t.api.identify({ id: 'u1' });
    t.api.track('a');
    t.ready();
    expect(t.calls.map((c) => c.action)).toEqual(['subscribe', 'getState', 'identify', 'enqueue']);
    expect(t.events()[0].attributes['user.id']).toBe('u1');
  });

  it('discards the buffer, uncounted, when native says capture is off (P7)', async () => {
    const t = await load({ state: { enabled: false } });
    t.api.track('a');
    t.ready();
    t.api.track('b');
    vi.advanceTimersByTime(5000);
    expect(t.enqueues()).toEqual([]);
  });

  it('enable() before deviceready wins over a stale native state', async () => {
    const t = await load({ state: { enabled: false } });
    t.api.enable();
    t.ready();
    t.api.track('a');
    vi.advanceTimersByTime(2000);
    expect(t.events().map((e) => e.attributes['event.name'])).toEqual(['a']);
  });
});

describe('hand-off triggers (T1)', () => {
  it('flushes after 2 s', async () => {
    const t = await load();
    t.ready();
    t.api.track('a');
    vi.advanceTimersByTime(1999);
    expect(t.enqueues()).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(t.enqueues()).toHaveLength(1);
  });

  it('flushes at 20 events', async () => {
    const t = await load();
    t.ready();
    for (let i = 0; i < 20; i++) t.api.track('e' + i);
    expect(t.enqueues()).toHaveLength(1);
    expect(t.enqueues()[0]).toHaveLength(20);
  });

  it('flushes immediately on a captured app.crash', async () => {
    const t = await load();
    t.ready();
    t.api.track('a');
    t.api.captureError(new TypeError('boom'));
    expect(t.events().map((e) => e.eventName)).toEqual(['custom_event', 'app.crash']);
  });

  it('flushes immediately on visibilitychange→hidden and on pause', async () => {
    const t = await load();
    t.ready();
    t.api.track('a');
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
    expect(t.enqueues()).toHaveLength(1);
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
    t.api.track('b');
    document.dispatchEvent(new Event('pause'));
    expect(t.enqueues()).toHaveLength(2);
  });
});

describe('exec failure (A4, T8)', () => {
  it('counts a failed enqueue as dropped and reports it with the next hand-off', async () => {
    const t = await load();
    t.ready();
    t.native.failEnqueue = true;
    t.api.track('a');
    t.api.track('b');
    vi.advanceTimersByTime(2000);
    t.native.failEnqueue = false;
    t.api.track('c');
    vi.advanceTimersByTime(2000);
    const last = t.enqueues()[1];
    expect(last.map((e) => e.attributes['event.name'])).toEqual(['c', undefined]);
    expect(health(last)).toEqual({ 'events_dropped.js_exec_failed': 2 });
    // Delivered → cleared.
    t.api.track('d');
    vi.advanceTimersByTime(2000);
    expect(health(t.enqueues()[2])).toBeUndefined();
  });

  it('counts a throwing exec the same way', async () => {
    const t = await load();
    t.ready();
    t.native.throwOnExec = true;
    t.api.track('a');
    vi.advanceTimersByTime(2000);
    t.native.throwOnExec = false;
    t.api.track('b');
    vi.advanceTimersByTime(2000);
    expect(health(t.events())).toEqual({ 'events_dropped.js_exec_failed': 1 });
  });
});

describe('beforeSend (P5)', () => {
  it('null drops the event and counts it', async () => {
    const t = await load();
    t.api.init({ beforeSend: (e) => (e.attributes['event.name'] === 'secret' ? null : e) });
    t.ready();
    t.api.track('secret');
    t.api.track('ok');
    vi.advanceTimersByTime(2000);
    expect(t.events().map((e) => e.attributes['event.name'])).toEqual(['ok', undefined]);
    expect(health(t.events())).toEqual({ 'events_dropped.before_send_null': 1 });
  });

  it('a throw or non-event drops the event (fail closed) and counts it', async () => {
    const t = await load();
    let n = 0;
    t.api.init({
      beforeSend: () => {
        if (n++ === 0) throw new Error('bug');
        return undefined as unknown as null;
      },
    });
    t.ready();
    t.api.track('a');
    t.api.track('b');
    vi.advanceTimersByTime(2000);
    expect(t.events().filter((e) => e.eventName === 'custom_event')).toEqual([]);
    expect(health(t.events())).toEqual({ 'events_dropped.before_send_error': 2 });
  });

  it('re-stamps session/sequence keys and the event name after the hook', async () => {
    const t = await load();
    t.api.init({
      beforeSend: (e) => {
        delete e.attributes['session.id'];
        e.attributes['app.version'] = 'forged';
        e.attributes.email = 'redacted';
        return { ...e, eventName: 'app.crash' };
      },
    });
    t.ready();
    t.api.track('a', { email: 'a@b.c' });
    vi.advanceTimersByTime(2000);
    const [e] = t.events();
    expect(e.eventName).toBe('custom_event');
    expect(e.attributes).toEqual({ 'event.name': 'a', email: 'redacted', 'session.id': 's1' });
  });

  it('cannot see or drop the SDK’s own sdk.health row', async () => {
    const t = await load();
    t.api.init({ beforeSend: () => null });
    t.ready();
    t.api.track('a');
    vi.advanceTimersByTime(2000);
    expect(t.events().map((e) => e.eventName)).toEqual(['sdk.health']);
  });
});

describe('init / auto-start (C2, C3)', () => {
  it('starts with defaults when init() is never called', async () => {
    const t = await load();
    expect(t.core.state.options).toMatchObject({ captureErrors: true, captureResourceTiming: false, slowBridgeCallMs: 1000, frameSlowThresholdMs: 34 });
    t.ready();
    t.api.track('a');
    vi.advanceTimersByTime(2000);
    expect(t.events()).toHaveLength(1);
  });

  it('before deviceready, each init() replaces the whole configuration', async () => {
    const t = await load();
    t.api.init({ captureErrors: false });
    t.api.init({ debug: true });
    expect(t.core.state.options).toMatchObject({ captureErrors: true, debug: true });
  });

  it('after deviceready, init() layers onto the current configuration', async () => {
    const t = await load();
    t.api.init({ captureErrors: false });
    t.ready();
    t.api.init({ debug: true });
    expect(t.core.state.options).toMatchObject({ captureErrors: false, debug: true });
  });

  it('sends a runtime key/endpoint to native via configure', async () => {
    const t = await load();
    t.api.init({ apiKey: 'k', endpoint: 'https://ingest' });
    t.ready();
    expect(t.calls.find((c) => c.action === 'configure')?.args).toEqual([{ apiKey: 'k', endpoint: 'https://ingest' }]);
  });
});

describe('no-op platforms (A8)', () => {
  for (const [label, opts] of [['browser', { platformId: 'browser' }], ['electron', { platformId: 'electron' }], ['no cordova', { cordova: false }]] as const) {
    it(`${label}: every method exists, nothing reaches native`, async () => {
      const t = await load(opts);
      const a = t.api;
      a.init({ apiKey: 'k' });
      a.identify({ id: 'u' });
      a.clearUser();
      a.track('a');
      a.measure('m', 1);
      a.time('t').end();
      a.trackScreen('s');
      a.captureError(new Error('x'));
      a.startTask('t');
      a.completeTask('t');
      a.failTask('t');
      a.markReady();
      a.setAttribute('k', 'v');
      a.removeAttribute('k');
      a.enable();
      a.disable();
      a.reset();
      t.ready();
      vi.advanceTimersByTime(5000);
      expect(t.calls).toEqual([]);
      await expect(a.getSessionId()).resolves.toBe('');
    });
  }
});

describe('API methods (C4)', () => {
  async function started() {
    const t = await load();
    t.ready();
    const flushed = () => {
      vi.advanceTimersByTime(2000);
      return t.events().filter((e) => e.eventName !== 'sdk.health');
    };
    return { ...t, flushed };
  }

  it('track → custom_event with event.name', async () => {
    const t = await started();
    t.api.track('checkout', { plan: 'pro' });
    t.api.track('');
    expect(t.flushed()).toEqual([
      { type: 'event', eventName: 'custom_event', timestamp: expect.stringMatching(/Z$/), attributes: { plan: 'pro', 'event.name': 'checkout', 'session.id': 's1' } },
    ]);
  });

  it('measure → host-named numeric row; non-finite values ignored', async () => {
    const t = await started();
    t.api.measure('cart.items', 3, { tier: 'gold' });
    t.api.measure('bad', NaN);
    expect(t.flushed()).toEqual([
      { type: 'metric', metricName: 'cart.items', value: 3, timestamp: expect.any(String), attributes: { tier: 'gold', 'session.id': 's1' } },
    ]);
  });

  it('time().end() → measure of the elapsed ms, once', async () => {
    const t = await started();
    const timer = t.api.time('load');
    vi.advanceTimersByTime(250);
    timer.end({ cached: true });
    timer.end();
    const rows = t.flushed();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ metricName: 'load', attributes: { cached: true } });
    expect(rows[0].value).toBeGreaterThanOrEqual(250);
  });

  it('trackScreen → navigation from the previous screen', async () => {
    const t = await started();
    t.api.trackScreen('home');
    t.api.trackScreen('cart', { tab: 2 });
    const [a, b] = t.flushed();
    expect(a.attributes).toMatchObject({ 'navigation.to_screen': 'home', 'navigation.method': 'manual' });
    expect(a.attributes['navigation.from_screen']).toBeUndefined();
    expect(b.attributes).toMatchObject({ 'navigation.from_screen': 'home', 'navigation.to_screen': 'cart', tab: 2 });
  });

  it('captureError → handled, non-fatal app.crash with release', async () => {
    const t = await started();
    t.api.init({ release: 'web@1' });
    t.api.captureError(new RangeError('nope'), { step: 'pay' });
    t.api.captureError('plain string');
    const [a, b] = t.events();
    expect(a.attributes).toMatchObject({ message: 'nope', exception_type: 'RangeError', handled: true, is_fatal: false, runtime: 'webview', release: 'web@1', step: 'pay' });
    expect(a.attributes.stacktrace).toContain('RangeError');
    expect(b.attributes).toMatchObject({ message: 'plain string', exception_type: 'Error' });
  });

  it('tasks → one task.complete per terminal; unknown names ignored', async () => {
    const t = await started();
    t.api.startTask('pay', { amount: 5 });
    vi.advanceTimersByTime(100);
    t.api.completeTask('pay');
    t.api.completeTask('pay');
    t.api.startTask('ship');
    t.api.failTask('ship', 'timeout');
    t.api.failTask('never-started');
    const [done, failed] = t.flushed();
    expect(done.attributes).toMatchObject({ 'task.name': 'pay', 'task.outcome': 'completed', amount: 5 });
    expect(done.attributes['span.duration_ms']).toBeGreaterThanOrEqual(100);
    expect(failed.attributes).toMatchObject({ 'task.name': 'ship', 'task.outcome': 'failed', 'task.failure_reason': 'timeout' });
    expect(t.flushed()).toHaveLength(2);
  });

  it('tasks still open at session end → abandoned', async () => {
    const t = await started();
    t.api.startTask('pay');
    t.native.subscriber?.({ type: 'session', enabled: true, sessionId: 's2' });
    const [e] = t.flushed();
    expect(e.attributes).toMatchObject({ 'task.outcome': 'abandoned', 'task.abandon_source': 'session_end', 'session.id': 's2' });
  });

  it('identify / clearUser → native actions with only the known traits; user.id stamped', async () => {
    const t = await started();
    t.api.identify({ id: 'u1', email: 'a@b.c', extra: 'x' } as never);
    t.api.track('a');
    t.flushed();
    t.api.clearUser();
    t.api.track('b');
    const [a, b] = t.flushed();
    expect(t.calls.find((c) => c.action === 'identify')?.args).toEqual([{ id: 'u1', email: 'a@b.c' }]);
    expect(t.calls.find((c) => c.action === 'clearUser')?.args).toEqual([]);
    expect(a.attributes['user.id']).toBe('u1');
    expect(b.attributes['user.id']).toBeUndefined();
  });

  it('markReady → markPhase', async () => {
    const t = await started();
    t.api.markReady();
    expect(t.calls.find((c) => c.action === 'markPhase')?.args).toEqual([{ phase: 'markReady', ts: expect.any(Number) }]);
  });

  it('setAttribute / removeAttribute → global attrs on JS events', async () => {
    const t = await started();
    t.api.setAttribute('tenant', 'acme');
    t.api.track('a');
    t.api.removeAttribute('tenant');
    t.api.track('b');
    const [a, b] = t.flushed();
    expect(a.attributes.tenant).toBe('acme');
    expect(b.attributes.tenant).toBeUndefined();
  });

  it('disable stops capture and drops the buffer; enable resumes; reset clears the user', async () => {
    const t = await started();
    t.api.track('lost');
    t.api.disable();
    t.api.track('ignored');
    t.api.enable();
    t.api.identify({ id: 'u1' });
    t.api.reset();
    t.api.track('kept');
    const rows = t.flushed();
    expect(rows.map((e) => e.attributes['event.name'])).toEqual(['kept']);
    expect(rows[0].attributes['user.id']).toBeUndefined();
    expect(t.calls.map((c) => c.action).filter((a) => ['disable', 'enable', 'reset'].includes(a))).toEqual(['disable', 'enable', 'reset']);
  });

  it('getSessionId resolves once native state is known', async () => {
    const t = await load();
    const id = t.api.getSessionId();
    t.ready();
    await expect(id).resolves.toBe('s1');
  });
});
