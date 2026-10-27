import { breadcrumb, live, now, record, state, whenReady, type Attributes } from './core';
import { template } from './network';

const event = (eventName: string, attributes: Attributes) => record({ type: 'event', eventName, timestamp: now(), attributes });

// Not `screen`: the bundle may run unwrapped, where that is `window.screen`.
let current: { name: string; start: number } | undefined;
/** The URL-derived name last reported, so one route is never reported twice (or after `trackScreen` named it). */
let route: string | undefined;

/** The screen the user is on (P2 name), for `ui.screen`. */
export const currentScreen = () => current?.name;

/** E4 / E5: leave the current screen (one `screen.duration`) and enter `name` (one `navigation`). */
export function enter(name: string, method: string, attrs: Attributes = {}) {
  const from = current;
  const t = performance.now();
  if (from) event('screen.duration', { 'screen.name': from.name, 'screen.duration_ms': Math.round(t - from.start), 'screen.exit_method': method });
  current = { name, start: t };
  state.activity++;
  breadcrumb('navigation', name);
  event('navigation', {
    ...attrs,
    ...(from && { 'navigation.from_screen': from.name }),
    'navigation.to_screen': name,
    'navigation.method': method,
    'navigation.timestamp': Date.now(),
  });
}

/** P2: hash route if present (`#/…`, `#!/…`), else path; query dropped; ids → `{id}`; host `screenName` overrides. */
function routeName() {
  const hash = /^#!?(\/[^?]*)/.exec(location.hash)?.[1];
  const path = hash ?? location.pathname;
  let name = template(path);
  try {
    const custom = state.options.screenName?.(path);
    if (typeof custom === 'string' && custom) name = custom;
  } catch {
    // A throwing host override keeps the built-in name.
  }
  return { name, type: hash ? 'hash' : 'path' };
}

/** Called after the URL changed; reports only a new route. */
function auto(method: string) {
  if (!state.options.captureScreens) return;
  const r = routeName();
  if (r.name === route) return;
  route = r.name;
  enter(r.name, method, { 'navigation.route_type': r.type });
}

/** `trackScreen()`: the host's name wins for the current URL. */
export function manual(name: string, attrs?: Attributes) {
  route = routeName().name;
  enter(name, 'manual', attrs);
}

if (live) {
  for (const [fn, method] of [['pushState', 'push'], ['replaceState', 'replace']] as const) {
    const original = history[fn];
    history[fn] = function (...args: Parameters<History['pushState']>) {
      const out = original.apply(this, args);
      auto(method);
      return out;
    };
  }
  // A hash link fires popstate then hashchange; the second sees the same route and is dropped.
  window.addEventListener('popstate', () => auto('pop'));
  window.addEventListener('hashchange', () => auto('hash'));
  // At deviceready, so a pre-deviceready `init({ captureScreens: false })` is honoured.
  whenReady(() => auto('initial'));
}
