// @vitest-environment jsdom
/* eslint-disable no-console -- these tests drive the console wrapper */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { EdgeRumEvent } from '../src/core';

type Ok = (r?: unknown) => void;
interface Payload { events: EdgeRumEvent[]; breadcrumbs: { category: string; message: string }[] }

const METHODS = ['log', 'info', 'warn', 'error', 'debug'] as const;
const originalConsole = Object.fromEntries(METHODS.map((m) => [m, console[m]]));

// Spec Q1: a fresh module + fake native per test, as in core.test.ts.
async function load() {
  vi.resetModules();
  const payloads: Payload[] = [];
  // `held`: when set, enqueue callbacks wait here so a test can settle them out of order.
  const native = { held: undefined as { ok: Ok; fail: Ok }[] | undefined };
  (globalThis as { cordova?: unknown }).cordova = {
    platformId: 'android',
    exec(ok: Ok, fail: Ok, _service: string, action: string, args: unknown[]) {
      if (action === 'getState') ok({ enabled: true, sessionId: 's1' });
      else if (action === 'enqueue') {
        payloads.push(args[0] as Payload);
        if (native.held) native.held.push({ ok, fail });
        else ok();
      } else if (action !== 'subscribe') ok();
    },
  };
  const api = await import('../src/index');
  const errors = await import('../src/errors');
  document.dispatchEvent(new Event('deviceready'));
  const events = () => payloads.flatMap((p) => p.events);
  const crashes = () => events().filter((e) => e.eventName === 'app.crash');
  const flushed = () => {
    vi.advanceTimersByTime(2000);
    return payloads;
  };
  return { api, errors, native, payloads, events, crashes, flushed };
}

beforeEach(() => {
  vi.useFakeTimers();
  for (const m of METHODS) console[m] = () => {};
});
afterEach(() => {
  vi.useRealTimers();
  Object.assign(console, originalConsole);
});

describe('app:/// frame normalisation (Y2)', () => {
  it.each([
    ['https://localhost/js/app.js:10:5', 'app:///js/app.js:10:5'],
    ['http://localhost/js/app.js:10:5', 'app:///js/app.js:10:5'],
    ['app://localhost/js/app.js:10:5', 'app:///js/app.js:10:5'],
    ['ionic://localhost/js/app.js:10:5', 'app:///js/app.js:10:5'],
    ['file:///android_asset/www/js/app.js:10:5', 'app:///js/app.js:10:5'],
    ['file:///var/containers/Bundle/Application/X/App.app/www/js/app.js:10:5', 'app:///js/app.js:10:5'],
  ])('%s → %s', async (from, to) => {
    const { errors } = await load();
    expect(errors.normaliseStack(`TypeError: x\n    at f (${from})\n    at ${from}`)).toBe(`TypeError: x\n    at f (${to})\n    at ${to}`);
    expect(errors.normaliseStack(`f@${from}`)).toBe(`f@${to}`); // WebKit form
  });

  it('strips query and hash, keeps line:col', async () => {
    const { errors } = await load();
    expect(errors.normaliseStack('at f (https://localhost/js/app.js?v=3:10:5)')).toBe('at f (app:///js/app.js:10:5)');
    expect(errors.normaliseStack('at https://localhost/index.html#/cart:2:1')).toBe('at app:///index.html:2:1');
  });

  it('leaves foreign origins untouched', async () => {
    const { errors } = await load();
    const foreign = 'at f (https://cdn.example.com/lib.js?v=1:1:2)\n at g (https://localhost.evil.com/x.js:1:2)\n at h (http://localhost:8100/x.js:3:4)';
    expect(errors.normaliseStack(foreign)).toBe(foreign);
  });
});

describe('JS errors (E9–E11)', () => {
  it('uncaught error → fatal app.crash, flushed at once, frames normalised', async () => {
    const t = await load();
    const error = new TypeError('boom');
    error.stack = 'TypeError: boom\n    at f (https://localhost/js/app.js:10:5)';
    window.dispatchEvent(new ErrorEvent('error', { error, message: 'Uncaught TypeError: boom' }));
    expect(t.crashes()[0].attributes).toMatchObject({
      message: 'boom', exception_type: 'TypeError', stacktrace: 'TypeError: boom\n    at f (app:///js/app.js:10:5)',
      handled: false, is_fatal: true, runtime: 'webview',
    });
  });

  it('error event without an Error (cross-origin) → message + location frame', async () => {
    const t = await load();
    window.dispatchEvent(new ErrorEvent('error', { message: 'Script error.', filename: 'file:///android_asset/www/a.js', lineno: 3, colno: 7 }));
    expect(t.crashes()[0].attributes).toMatchObject({ message: 'Script error.', exception_type: 'Error', stacktrace: 'at app:///a.js:3:7', handled: false });
  });

  it('non-Error throw → the thrown value as message', async () => {
    const t = await load();
    window.dispatchEvent(new ErrorEvent('error', { error: 'plain', message: 'Uncaught plain' }));
    expect(t.crashes()[0].attributes).toMatchObject({ message: 'plain', exception_type: 'Error' });
  });

  it('unhandled rejection → fatal app.crash; non-Error reasons kept as text', async () => {
    const t = await load();
    window.dispatchEvent(Object.assign(new Event('unhandledrejection'), { reason: new RangeError('nope') }));
    window.dispatchEvent(Object.assign(new Event('unhandledrejection'), { reason: { code: 7 } }));
    const [a, b] = t.crashes();
    expect(a.attributes).toMatchObject({ message: 'nope', exception_type: 'RangeError', handled: false, is_fatal: true });
    expect(b.attributes).toMatchObject({ message: '{"code":7}', exception_type: 'UnhandledRejection', is_fatal: true });
    expect(b.attributes.stacktrace).toBeUndefined();
  });

  it('captureError → handled, non-fatal, normalised, with release (Y1)', async () => {
    const t = await load();
    t.api.init({ release: 'web@1' });
    const error = new Error('caught');
    error.stack = 'Error: caught\n    at ionic://localhost/main.js:1:2';
    t.api.captureError(error);
    expect(t.crashes()[0].attributes).toMatchObject({
      handled: true, is_fatal: false, release: 'web@1', stacktrace: 'Error: caught\n    at app:///main.js:1:2',
    });
  });

  it('captureErrors=false ignores uncaught errors but not captureError()', async () => {
    const t = await load();
    t.api.init({ captureErrors: false });
    window.dispatchEvent(new ErrorEvent('error', { error: new Error('x') }));
    t.api.captureError(new Error('y'));
    expect(t.crashes().map((e) => e.attributes.message)).toEqual(['y']);
  });

  it('console.error → breadcrumb only by default; handled app.crash when captureConsoleErrors', async () => {
    const t = await load();
    console.error('first');
    expect(t.flushed().flatMap((p) => p.events)).toEqual([]);
    t.api.init({ captureConsoleErrors: true });
    console.error('failed to load', new SyntaxError('bad json'));
    expect(t.crashes()[0].attributes).toMatchObject({ message: 'bad json', exception_type: 'SyntaxError', handled: true, is_fatal: false });
    console.error('just text');
    expect(t.crashes()[1].attributes).toMatchObject({ message: 'just text', exception_type: 'ConsoleError' });
  });

  it('a beforeSend that logs errors does not loop', async () => {
    const t = await load();
    t.api.init({ captureConsoleErrors: true, beforeSend: (e) => (console.error('hook saw', e.eventName), e) });
    console.error('once');
    expect(t.crashes()).toHaveLength(1);
  });

  it('still calls the original console method', async () => {
    const seen: unknown[][] = [];
    console.warn = (...a: unknown[]) => seen.push(a);
    await load();
    console.warn('a', 1);
    expect(seen).toEqual([['a', 1]]);
  });
});

describe('breadcrumbs (A3)', () => {
  it('console.* and screens become crumbs, shipped once each with the next enqueue', async () => {
    const t = await load();
    console.log('hello', { n: 1 });
    t.api.trackScreen('cart');
    const [first] = t.flushed();
    expect(first.breadcrumbs).toMatchObject([
      { category: 'console', message: 'hello {"n":1}', level: 'log' },
      { category: 'navigation', message: 'cart' },
    ]);
    console.info('later');
    t.api.track('x');
    expect(t.flushed()[1].breadcrumbs.map((b) => b.message)).toEqual(['later']);
  });

  it('a failed hand-off resends exactly its own crumbs, even with a later one in flight', async () => {
    const t = await load();
    t.native.held = [];
    console.log('c1');
    t.flushed(); // A: c1
    console.log('c2');
    t.flushed(); // B: c2
    const [a, b] = t.native.held;
    b.ok();
    a.fail();
    t.native.held = undefined;
    console.log('c3');
    expect(t.flushed()[2].breadcrumbs.map((c) => c.message)).toEqual(['c1', 'c3']);
  });

  it('disable() forgets the ring', async () => {
    const t = await load();
    console.log('private');
    t.api.disable();
    t.api.enable();
    t.api.captureError(new Error('x'));
    expect(t.crashes()[0].attributes['crash.breadcrumbs']).toBe('[]');
    expect(t.payloads.flatMap((p) => p.breadcrumbs)).toEqual([]);
  });

  it('crash carries the ring, oldest first, capped at 50', async () => {
    const t = await load();
    for (let i = 0; i < 55; i++) console.log('c' + i);
    t.api.captureError(new Error('x'));
    const ring = JSON.parse(t.crashes()[0].attributes['crash.breadcrumbs'] as string) as { message: string }[];
    expect(ring).toHaveLength(50);
    expect(ring[0].message).toBe('c5');
    expect(ring[49].message).toBe('c54');
    expect(t.payloads[0].breadcrumbs).toHaveLength(50);
  });
});
