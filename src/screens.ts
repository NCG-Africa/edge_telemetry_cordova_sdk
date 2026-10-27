import { breadcrumb, event, flush, live, now, state, template, whenReady, type Attributes } from './core';

// E4: a router's URL change and its `trackScreen()` are one screen, in either order, when
// they land this close together. URL changes wait this long for a manual name to replace them.
// ponytail: fixed window; a router that names its screen later than this double-reports.
const SETTLE_MS = 100;

// Not `screen`: the bundle may run unwrapped, where that is `window.screen`.
// `start` unset while backgrounded: that time was already reported.
let current: { name: string; start?: number } | undefined;
/** The URL-derived name last reported, so one route is never reported twice (or after `trackScreen` named it). */
let route: string | undefined;
/** URL changes waiting out `SETTLE_MS`. */
const waiting = new Set<ReturnType<typeof setTimeout>>();
/** Until this time (performance.now), URL changes belong to the last `trackScreen()`. */
let claimedUntil = -Infinity;

/** The screen the user is on (P2 name), for `ui.screen`. */
export const currentScreen = () => current?.name;

/** E4 / E5: leave the current screen (one `screen.duration`) and enter `name` (one `navigation`). */
export function enter(name: string, method: string, attrs: Attributes = {}, at = performance.now(), timestamp = now()) {
  const from = current;
  close(method, at);
  current = { name, start: at };
  breadcrumb('navigation', name);
  event('navigation', {
    ...attrs,
    ...(from && { 'navigation.from_screen': from.name }),
    'navigation.to_screen': name,
    'navigation.method': method,
    'navigation.timestamp': Date.parse(timestamp),
  }, timestamp);
}

/** E5: report the time on the current screen so far. */
function close(method: string, at = performance.now()) {
  // E18 / E20: the first screen inherits what came before it; with no screens, hiding still ends the window.
  if (current || method === 'background') state.onScreenLeave(current?.name);
  if (current?.start === undefined) return;
  event('screen.duration', { 'screen.name': current.name, 'screen.duration_ms': Math.round(at - current.start), 'screen.exit_method': method });
  current.start = undefined;
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
  state.activity++; // E25: a navigation answers a tap now, not when it is reported
  const at = performance.now();
  if (at < claimedUntil) return;
  // Timed from the URL change, so the wait never shows in durations or timestamps.
  const timestamp = now();
  const id = setTimeout(() => {
    waiting.delete(id);
    enter(r.name, method, { 'navigation.route_type': r.type }, at, timestamp);
  }, SETTLE_MS);
  waiting.add(id);
}

/** `trackScreen()`: the host's name wins for the current URL. */
export function manual(name: string, attrs?: Attributes) {
  for (const id of waiting) clearTimeout(id);
  waiting.clear();
  route = routeName().name;
  claimedUntil = performance.now() + SETTLE_MS;
  state.activity++;
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
  // E5: the last screen before backgrounding (or never coming back) still gets its duration.
  const away = () => {
    close('background');
    flush(); // core's own hidden flush ran before this listener
  };
  const back = () => {
    if (current && current.start === undefined) current.start = performance.now();
  };
  document.addEventListener('pause', away, false);
  document.addEventListener('resume', back, false);
  document.addEventListener('visibilitychange', () => (document.visibilityState === 'hidden' ? away() : back()));
  // At deviceready, so a pre-deviceready `init({ captureScreens: false })` is honoured.
  whenReady(() => auto('initial'));
}
