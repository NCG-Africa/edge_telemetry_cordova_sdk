// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { EdgeRumEvent, EdgeRumOptions } from '../src/core';

type Ok = (r?: unknown) => void;
interface Payload { events: EdgeRumEvent[]; breadcrumbs: { category: string; message: string }[] }

// Spec Q1: a fresh module + fake native per test, as in core.test.ts.
async function load(url = '/', opts?: EdgeRumOptions) {
  vi.resetModules();
  history.replaceState(null, '', url);
  document.body.innerHTML = '';
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
  window.fetch = async () => new Response(null);
  const api = await import('../src/index');
  const core = await import('../src/core');
  if (opts) api.init(opts);
  document.dispatchEvent(new Event('deviceready'));
  // Flushes without moving the clock, so the 1 s rage/dead windows stay where tests put them.
  const named = (name: string) => {
    core.flush();
    return payloads.flatMap((p) => p.events).filter((e) => e.eventName === name).map((e) => e.attributes);
  };
  return { api, payloads, named };
}

const click = (el: Element, init: MouseEventInit = {}) => el.dispatchEvent(new MouseEvent('click', { bubbles: true, ...init }));
const html = (s: string) => {
  document.body.innerHTML = s;
  return document.body.firstElementChild as HTMLElement;
};

// The listeners each load() adds stay on the shared document; only the newest module's matter.
beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

describe('screen names (P2)', () => {
  it.each([
    ['/', '/'],
    ['/orders/12345?tab=2', '/orders/{id}'],
    ['/index.html#/cart/550e8400-e29b-41d4-a716-446655440000?x=1', '/cart/{id}'],
    ['/index.html#!/profile', '/profile'],
    ['/shop#top', '/shop'], // in-page anchor, not a hash route
  ])('%s → %s', async (url, name) => {
    const t = await load(url);
    expect(t.named('navigation')[0]).toMatchObject({ 'navigation.to_screen': name, 'navigation.method': 'initial' });
  });

  it('screenName(path) overrides; a throwing or non-string one falls back', async () => {
    const t = await load('/#/orders/42', { screenName: (p) => (p.startsWith('/orders') ? 'Order' : (undefined as unknown as string)) });
    history.pushState(null, '', '/#/home');
    expect(t.named('navigation').map((a) => a['navigation.to_screen'])).toEqual(['Order', '/home']);
  });
});

describe('navigation + screen.duration (E4, E5)', () => {
  it('path routes: push / replace / pop, from → to, duration of the screen left', async () => {
    const t = await load('/home');
    vi.advanceTimersByTime(500);
    history.pushState(null, '', '/orders/7');
    history.replaceState(null, '', '/orders/7?sort=asc'); // same screen: nothing
    history.replaceState(null, '', '/search');
    window.dispatchEvent(new PopStateEvent('popstate')); // same route: nothing
    history.back();
    await vi.waitUntil(() => location.pathname === '/home');
    window.dispatchEvent(new PopStateEvent('popstate')); // jsdom may or may not fire its own; deduped either way
    expect(t.named('navigation').map((a) => [a['navigation.from_screen'], a['navigation.to_screen'], a['navigation.method'], a['navigation.route_type']])).toEqual([
      [undefined, '/home', 'initial', 'path'],
      ['/home', '/orders/{id}', 'push', 'path'],
      ['/orders/{id}', '/search', 'replace', 'path'],
      ['/search', '/home', 'pop', 'path'],
    ]);
    const [first] = t.named('screen.duration');
    expect(first).toMatchObject({ 'screen.name': '/home', 'screen.exit_method': 'push' });
    expect(first['screen.duration_ms']).toBeGreaterThanOrEqual(500);
  });

  it('hash routes via hashchange', async () => {
    const t = await load('/index.html#/home');
    location.hash = '#/cart';
    window.dispatchEvent(new HashChangeEvent('hashchange'));
    expect(t.named('navigation').at(-1)).toMatchObject({ 'navigation.from_screen': '/home', 'navigation.to_screen': '/cart', 'navigation.route_type': 'hash' });
  });

  it('trackScreen overrides the URL name; the same URL is not reported again', async () => {
    const t = await load('/orders/9');
    t.api.trackScreen('Order');
    history.replaceState(null, '', '/orders/9?x=1');
    history.pushState(null, '', '/home');
    expect(t.named('navigation').map((a) => [a['navigation.from_screen'], a['navigation.to_screen'], a['navigation.method']])).toEqual([
      [undefined, '/orders/{id}', 'initial'],
      ['/orders/{id}', 'Order', 'manual'],
      ['Order', '/home', 'push'],
    ]);
    expect(t.named('screen.duration').map((a) => a['screen.name'])).toEqual(['/orders/{id}', 'Order']);
  });

  it('going to the background closes the screen; returning restarts its clock', async () => {
    const t = await load('/home');
    vi.advanceTimersByTime(300);
    const hide = (state: string) => {
      Object.defineProperty(document, 'visibilityState', { value: state, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    };
    hide('hidden');
    vi.advanceTimersByTime(5000); // away: not counted
    hide('visible');
    delete (document as { visibilityState?: unknown }).visibilityState;
    vi.advanceTimersByTime(200);
    history.pushState(null, '', '/cart');
    expect(t.named('screen.duration').map((a) => [a['screen.exit_method'], a['screen.duration_ms']])).toEqual([['background', 300], ['push', 200]]);
  });

  it('captureScreens:false → only trackScreen', async () => {
    const t = await load('/home', { captureScreens: false });
    history.pushState(null, '', '/cart');
    t.api.trackScreen('Cart');
    expect(t.named('navigation').map((a) => a['navigation.to_screen'])).toEqual(['Cart']);
  });
});

describe('ui.target name chain (P4)', () => {
  it.each([
    ['<button data-edge-action="Pay now" aria-label="x" id="y">z</button>', 'Pay now', 'edge_action'],
    ['<div data-edge-action="Card"><span id="t">hi</span></div>', 'Card', 'edge_action'],
    ['<button aria-label="Close" id="y">z</button>', 'Close', 'aria_label'],
    ['<button id="save-2">z</button>', 'save-#', 'id'],
    ['<button>  Pay   KES 1,250  </button>', 'Pay KES #,###', 'text'],
    ['<a href="#">' + 'x'.repeat(80) + '</a>', 'x'.repeat(64), 'text'],
    ['<div role="tab">Inbox (3)</div>', 'Inbox (#)', 'text'],
    ['<div>plain text</div>', 'div', 'none'],
    ['<input value="secret 4111">', 'input', 'none'],
    ['<textarea>secret</textarea>', 'textarea', 'none'],
    ['<select><option>secret</option></select>', 'select', 'none'],
    ['<a href="#">Hi <span data-edge-private>Acct 123</span></a>', 'a', 'none'],
    ['<button>Edit <span contenteditable="true">secret</span></button>', 'button', 'none'],
    ['<div contenteditable="true"><button>secret</button></div>', 'button', 'none'],
    ['<div data-edge-private><button aria-label="Acct 123" id="i">secret</button></div>', 'button', 'none'],
  ])('%s → %s (%s)', async (markup, target, source) => {
    const t = await load();
    const root = html(markup);
    click(root.querySelector('button, a, input, textarea, select, span, [role]') ?? root, { clientX: 10.4, clientY: 20.6 });
    vi.advanceTimersByTime(1000);
    expect(t.named('ui.interaction').at(-1)).toMatchObject({ 'ui.type': 'click', 'ui.target': target, 'ui.name_source': source, 'ui.screen': '/', 'ui.x': 10, 'ui.y': 21 });
  });

  it('touch → tap; captureInteractions:false → nothing', async () => {
    const t = await load();
    const b = html('<button>Go</button>');
    b.dispatchEvent(Object.assign(new MouseEvent('click', { bubbles: true }), { pointerType: 'touch' }));
    vi.advanceTimersByTime(1000);
    expect(t.named('ui.interaction')[0]['ui.type']).toBe('tap');
    t.api.init({ captureInteractions: false });
    click(b);
    vi.advanceTimersByTime(1000);
    expect(t.named('ui.interaction')).toHaveLength(1);
  });
});

describe('rage and dead taps (E25)', () => {
  it('3 taps on the same target within 1 s → ui.rage on the 3rd onwards', async () => {
    const t = await load();
    const [a, b] = Array.from(html('<div><button>A</button><button>B</button></div>').children);
    click(a);
    click(b);
    click(a);
    vi.advanceTimersByTime(400);
    click(a);
    click(a);
    vi.advanceTimersByTime(1100);
    click(a); // window passed: calm again
    vi.advanceTimersByTime(1000);
    expect(t.named('ui.interaction').map((x) => x['ui.rage'])).toEqual([undefined, undefined, undefined, true, true, undefined]);
  });

  it('dead: an actionable tap with no mutation, navigation or request within 1 s', async () => {
    const t = await load();
    const b = html('<button>Go</button>');
    click(b); // dead
    vi.advanceTimersByTime(1000);
    click(b);
    b.textContent = 'Going'; // DOM mutation
    await Promise.resolve();
    vi.advanceTimersByTime(1000);
    click(b);
    history.pushState(null, '', '/next'); // navigation
    vi.advanceTimersByTime(1000);
    click(b);
    void fetch('/api'); // request
    vi.advanceTimersByTime(999);
    expect(t.named('ui.interaction').map((x) => x['ui.dead'])).toEqual([true, undefined, undefined]);
    vi.advanceTimersByTime(1);
    expect(t.named('ui.interaction')).toHaveLength(4);
    expect(t.named('ui.interaction')[3]['ui.dead']).toBeUndefined();
  });

  it('stamped at the tap, not when its dead window closes', async () => {
    const t = await load();
    const before = Date.now();
    click(html('<button>Go</button>'));
    vi.advanceTimersByTime(1000);
    t.named('ui.interaction');
    const [tap] = t.payloads.flatMap((p) => p.events).filter((e) => e.eventName === 'ui.interaction');
    expect(Date.parse(tap.timestamp)).toBe(before);
  });

  it('a tap on a non-control is never judged dead', async () => {
    const t = await load();
    click(html('<div>whitespace</div>'));
    vi.advanceTimersByTime(1000);
    expect(t.named('ui.interaction')[0]['ui.dead']).toBeUndefined();
  });

  it('going hidden emits pending taps unjudged, at once', async () => {
    const t = await load();
    click(html('<button>Go</button>'));
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
    delete (document as { visibilityState?: unknown }).visibilityState;
    const [tap] = t.payloads.flatMap((p) => p.events).filter((e) => e.eventName === 'ui.interaction');
    expect(tap.attributes['ui.dead']).toBeUndefined();
  });

  it('taps become breadcrumbs', async () => {
    const t = await load();
    click(html('<button>Pay</button>'));
    vi.advanceTimersByTime(3000);
    expect(t.payloads.flatMap((p) => p.breadcrumbs)).toContainEqual(expect.objectContaining({ category: 'ui', message: 'click Pay' }));
  });
});
