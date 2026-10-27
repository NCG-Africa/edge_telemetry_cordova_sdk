import { call, DEFAULTS, discard, event, live, now, record, setEnabled, state, whenReady, type Attributes, type AttributeValue, type EdgeRumOptions } from './core';
import { crash } from './errors';
import './interactions';
import './network';
import './perf';
import { manual } from './screens';

// Self-import: the global's type is this module's exports, so typings never drift from the bundle.
import type * as EdgeRumModule from './index';

export type { AttributeValue, Attributes, EdgeRumEvent, EdgeRumOptions } from './core';
export type { BeforeSend } from './beforeSend';

/** Traits passed to `identify()`. */
export interface UserTraits {
  id?: string;
  name?: string;
  email?: string;
  phone?: string;
}

/** Handle returned by `time()`. */
export interface Timer {
  /** Stop the timer and record the elapsed milliseconds under the timer's name. */
  end(attrs?: Attributes): void;
}

declare global {
  interface Window {
    /** The Edge RUM plugin. Every method is fire-and-forget, safe before `deviceready`, and a no-op on browser / electron. */
    EdgeRum: typeof EdgeRumModule;
  }
}

/** Version of this plugin, e.g. `1.0.0`. */
export const sdkVersion: string = __SDK_VERSION__;

/**
 * Optional. Capture starts on load with defaults; call this to change them. Before
 * `deviceready` it replaces the whole configuration; later calls apply to new captures only.
 */
export function init(opts: EdgeRumOptions = {}): void {
  if (!live) return;
  state.options = state.ready ? { ...state.options, ...opts } : { ...DEFAULTS, ...opts };
  if (opts.apiKey || opts.endpoint) call('configure', { apiKey: opts.apiKey, endpoint: opts.endpoint });
}

/**
 * Attach a user to every event from now on (kept across launches until `clearUser()`).
 * `name` / `email` / `phone` are sent once, when they change.
 */
export function identify(traits: UserTraits): void {
  if (!traits || typeof traits !== 'object') return;
  const clean: UserTraits = {};
  for (const k of ['id', 'name', 'email', 'phone'] as const) if (typeof traits[k] === 'string') clean[k] = traits[k];
  if (clean.id) state.userId = clean.id;
  call('identify', clean);
}

/** Forget the user set by `identify()`. */
export function clearUser(): void {
  state.userId = undefined;
  call('clearUser');
}

/** Record a named host event. */
export function track(name: string, attrs?: Attributes): void {
  if (typeof name === 'string' && name) event('custom_event', { ...attrs, 'event.name': name });
}

/** Record a host-named numeric value, e.g. `measure('cart.items', 3)`. */
export function measure(name: string, value: number, attrs?: Attributes): void {
  if (typeof name !== 'string' || !name || typeof value !== 'number' || !isFinite(value)) return;
  record({ type: 'metric', metricName: name, value, timestamp: now(), attributes: { ...attrs } });
}

/** Start a timer; `end()` records the elapsed milliseconds via `measure()`. */
export function time(name: string): Timer {
  const start = performance.now();
  let ended = false;
  return {
    end(attrs) {
      if (ended) return;
      ended = true;
      measure(name, performance.now() - start, attrs);
    },
  };
}

/** Report a screen change by name; use with `init({ captureScreens: false })` from a router. */
export function trackScreen(name: string, attrs?: Attributes): void {
  if (typeof name === 'string' && name) manual(name, attrs);
}

/** Report an error the app caught. */
export function captureError(err: unknown, attrs?: Attributes): void {
  crash(err, true, { attrs });
}

// E29, copied from edge_telemetry_flutter: a start costs nothing on the wire; one
// `task.complete` at the terminal. Restarting an open name restarts its clock.
const tasks = new Map<string, { start: number; attrs: Attributes }>();

function endTask(name: string, outcome: string, extra: Attributes = {}) {
  const t = tasks.get(name);
  if (!t) return;
  tasks.delete(name);
  event('task.complete', {
    ...t.attrs,
    ...extra,
    'task.name': name,
    'task.outcome': outcome,
    'span.duration_ms': Math.round(performance.now() - t.start),
  });
}

state.onSessionChange = () => {
  for (const name of [...tasks.keys()]) endTask(name, 'abandoned', { 'task.abandon_source': 'session_end' });
};

/** Start a named user journey (e.g. `checkout`); close it with `completeTask` or `failTask`. */
export function startTask(name: string, attrs?: Attributes): void {
  if (live && typeof name === 'string' && name) tasks.set(name, { start: performance.now(), attrs: { ...attrs } });
}

/** Close an open journey as completed. Unknown names are ignored. */
export function completeTask(name: string): void {
  endTask(name, 'completed');
}

/** Close an open journey as failed, with an optional reason. Unknown names are ignored. */
export function failTask(name: string, reason?: string): void {
  endTask(name, 'failed', typeof reason === 'string' ? { 'task.failure_reason': reason } : {});
}

/** Mark the app as ready for the user; the launch time ends here if called within 30 s of `deviceready`. */
export function markReady(): void {
  call('markPhase', { phase: 'markReady', ts: Date.now() });
}

/** Add an attribute to every JS event captured from now on. */
export function setAttribute(key: string, value: AttributeValue): void {
  if (typeof key === 'string' && key && ['string', 'number', 'boolean'].includes(typeof value)) state.globals[key] = value;
}

/** Stop adding an attribute set by `setAttribute()`. */
export function removeAttribute(key: string): void {
  delete state.globals[key];
}

/** Turn capture on (remembered across launches). */
export function enable(): void {
  if (!live) return;
  setEnabled(true);
  call('enable');
}

/** Turn capture off (remembered across launches) and delete anything not yet sent. */
export function disable(): void {
  if (!live) return;
  setEnabled(false);
  call('disable');
}

/** Start over as a new device: new session, user cleared, unsent data deleted. */
export function reset(): void {
  if (!live) return;
  discard();
  state.userId = undefined;
  call('reset');
}

/** The current session id, once `deviceready` has fired (empty string when there is none, e.g. on browser). */
export function getSessionId(): Promise<string> {
  if (!live) return Promise.resolve('');
  return new Promise((resolve) => whenReady(() => resolve(state.sessionId ?? '')));
}
