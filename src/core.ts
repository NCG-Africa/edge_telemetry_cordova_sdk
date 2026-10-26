import { applyBeforeSend, type BeforeSend } from './beforeSend';

/** A value an event attribute may hold. */
export type AttributeValue = string | number | boolean;
/** Flat key/value attributes carried by an event. */
export type Attributes = Record<string, AttributeValue>;

/**
 * One captured event, as `beforeSend` sees it. `type` is `"event"` for named events; rows
 * from `measure()` / `time()` carry their host-given name and a numeric `value` instead.
 */
export interface EdgeRumEvent {
  type: string;
  eventName?: string;
  /** UTC RFC 3339 capture time. */
  timestamp: string;
  attributes: Attributes;
  [key: string]: unknown;
}

/** `EdgeRum.init()` options (all optional). */
export interface EdgeRumOptions {
  /** Runtime API key; overrides the install-time value for this launch only (not stored). */
  apiKey?: string;
  /** Runtime ingest URL; overrides the install-time value for this launch only (not stored). */
  endpoint?: string;
  /** Capture uncaught errors and unhandled rejections. Default `true`. */
  captureErrors?: boolean;
  /** Capture `fetch` / XHR requests. Default `true`. */
  captureRequests?: boolean;
  /** Capture screen changes from the URL. Default `true`; set `false` when calling `trackScreen()` from a router. */
  captureScreens?: boolean;
  /** Capture taps and clicks. Default `true`. */
  captureInteractions?: boolean;
  /** Capture rendering smoothness. Default `true`. */
  captureFrames?: boolean;
  /** Capture Web Vitals. Default `true`. */
  captureVitals?: boolean;
  /** Capture Cordova plugin call timings. Default `true`. */
  captureBridge?: boolean;
  /** Capture per-resource load timings. Default `false`. */
  captureResourceTiming?: boolean;
  /** Report `console.error` calls as handled errors (otherwise breadcrumbs only). Default `false`. */
  captureConsoleErrors?: boolean;
  /** Hosts (exact string or RegExp) that receive a `traceparent` request header. Default none. */
  correlateRequestsTo?: (string | RegExp)[];
  /** Requests to these URLs (substring or RegExp) are not captured. */
  ignoreUrls?: (string | RegExp)[];
  /** Further scrub a request URL after the built-in scrub; can only remove more. */
  sanitizeUrl?: (url: string) => string;
  /** Map a route path to the screen name to report. */
  screenName?: (path: string) => string;
  /**
   * Inspect or edit each event before it leaves JS; return `null` to drop it. Must be synchronous.
   * Sees JS-captured events only: native-origin events (native crashes, launch time, lifecycle,
   * memory, network, sessions) bypass it. Session and sequence keys are restored after it runs.
   */
  beforeSend?: BeforeSend;
  /** Release name stamped on JS errors, for source-map lookup. */
  release?: string;
  /** A plugin call slower than this (ms) is reported on its own. Default `1000`. */
  slowBridgeCallMs?: number;
  /** A frame slower than this (ms) counts as slow. Default `34`. */
  frameSlowThresholdMs?: number;
  /** Log SDK warnings to the console. Default `false`. */
  debug?: boolean;
}

export const DEFAULTS: EdgeRumOptions = {
  captureErrors: true, captureRequests: true, captureScreens: true, captureInteractions: true,
  captureFrames: true, captureVitals: true, captureBridge: true,
  captureResourceTiming: false, captureConsoleErrors: false,
  correlateRequestsTo: [], ignoreUrls: [], slowBridgeCallMs: 1000, frameSlowThresholdMs: 34, debug: false,
};

interface NativeState { enabled?: boolean; sessionId?: string | null; userId?: string | null; type?: string }
type Exec = (ok: (r: unknown) => void, fail: (e: unknown) => void, service: string, action: string, args: unknown[]) => void;

const FLUSH_MS = 2000; // T1
const FLUSH_AT = 20; // T1
const BUFFER_CAP = 500; // A4

// Captured at load: native is whatever cordova this bundle was loaded under.
const cordova = (globalThis as { cordova?: { platformId?: string; exec?: Exec } }).cordova;
/** A8 / R16: no native on browser / electron (or outside cordova) → every API method is a silent no-op. */
export const live = !!cordova?.exec && cordova.platformId !== 'browser' && cordova.platformId !== 'electron';

export const state = {
  ready: false,
  enabled: true,
  sessionId: undefined as string | undefined,
  userId: undefined as string | undefined,
  options: { ...DEFAULTS },
  globals: {} as Attributes,
  /** Called when native reports a new session (E29 abandons open tasks). */
  onSessionChange: () => {},
};

let buffer: EdgeRumEvent[] = [];
const drops: Record<string, number> = {};
const pending: (() => void)[] = [];
let consentOverride: boolean | undefined;
let timer: ReturnType<typeof setTimeout> | undefined;

function exec(action: string, args: unknown[], ok: (r: unknown) => void = () => {}, fail: (e: unknown) => void = () => {}) {
  try {
    (cordova?.exec as Exec)(ok, fail, 'EdgeRum', action, args);
  } catch (e) {
    fail(e);
  }
}

/** Fire-and-forget A2 action; held until `deviceready`. */
export function call(action: string, arg?: object) {
  if (!live) return;
  const run = () => exec(action, arg ? [arg] : []);
  if (state.ready) run();
  else pending.push(run);
}

/** Run once native state is known (immediately if it already is). */
export function whenReady(f: () => void) {
  if (state.ready) f();
  else pending.push(f);
}

export function setEnabled(on: boolean) {
  if (!state.ready) consentOverride = on;
  state.enabled = on;
  if (!on) discard();
}

/** Drop everything buffered, uncounted (consent / reset, not loss). */
export function discard() {
  buffer = [];
}

function count(reason: string, n = 1) {
  drops[reason] = (drops[reason] ?? 0) + n;
}

export function record(e: EdgeRumEvent) {
  if (!live || !state.enabled) return;
  e.attributes = { ...state.globals, ...e.attributes };
  buffer.push(e);
  if (buffer.length > BUFFER_CAP) {
    buffer.shift();
    count('js_buffer_full');
  }
  if (!state.ready) return;
  // T1: a crash may be the page's last act, so it doesn't wait for the timer.
  if (e.eventName === 'app.crash' || buffer.length >= FLUSH_AT) flush();
  else if (timer === undefined) timer = setTimeout(flush, FLUSH_MS);
}

/** T1 hand-off: one `enqueue` with everything buffered, after `beforeSend` (P5). */
export function flush() {
  clearTimeout(timer);
  timer = undefined;
  if (!state.ready || !state.enabled) return;
  const events: EdgeRumEvent[] = [];
  const hook = state.options.beforeSend;
  for (const e of buffer.splice(0)) {
    if (state.sessionId) e.attributes['session.id'] = state.sessionId;
    if (state.userId) e.attributes['user.id'] = state.userId;
    if (!hook) {
      events.push(e);
      continue;
    }
    const out = applyBeforeSend(e, hook);
    if (out.kind === 'kept') events.push(out.event);
    else {
      count(out.kind === 'dropped' ? 'before_send_null' : 'before_send_error');
      if (out.kind === 'failed' && state.options.debug) console.warn('EdgeRum: beforeSend threw or returned a non-event; event dropped');
    }
  }
  // T8: JS-side drops ride the next hand-off; native folds them into its `sdk.health`.
  // Cleared only once native has them, so a failed exec resends them.
  const sent = { ...drops };
  const hasDrops = Object.keys(sent).length > 0;
  if (!events.length && !hasDrops) return;
  exec('enqueue', [{ events, breadcrumbs: [], ...(hasDrops && { drops: sent }) }], () => {
    for (const [k, n] of Object.entries(sent)) {
      drops[k] -= n;
      if (!drops[k]) delete drops[k];
    }
  }, () => count('js_exec_failed', events.length)); // A4: no JS fallback sender
}

function applyNativeState(s: unknown) {
  if (!s || typeof s !== 'object') return; // keep-callback NO_RESULT
  const n = s as NativeState;
  const before = state.sessionId;
  if (typeof n.enabled === 'boolean') setEnabled(consentOverride ?? n.enabled);
  consentOverride = undefined;
  state.sessionId = n.sessionId ?? undefined;
  if (n.userId !== undefined) state.userId = n.userId ?? undefined;
  if (before && state.sessionId !== before) state.onSessionChange();
}

function onReady() {
  const go = () => {
    if (state.ready) return;
    state.ready = true;
    for (const f of pending.splice(0)) f();
    flush();
  };
  exec('subscribe', [], applyNativeState);
  exec('getState', [], (s) => {
    applyNativeState(s);
    go();
  }, go);
}

if (live) {
  document.addEventListener('deviceready', onReady, false);
  document.addEventListener('pause', flush, false);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') flush();
  });
}
