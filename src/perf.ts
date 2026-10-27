import { onCLS, onFCP, onINP, onLCP, onTTFB, type Metric } from 'web-vitals';
import { call, event, flush, live, now, record, state, whenReady, type Attributes } from './core';
import { currentScreen } from './screens';

/** The cordova.js internals E18 / E19 hook (cordova.js callbacks, exec.js sinks). */
interface Cordova {
  callbackId: number;
  callbacks: Record<string, unknown>;
  callbackFromNative: (id: string, isSuccess: boolean, ...rest: unknown[]) => void;
  require?: (id: string) => unknown;
}
interface NativeApi {
  exec(secret: unknown, service: string, action: string, id: string, args: string): unknown;
  setNativeToJsBridgeMode(...a: unknown[]): unknown;
  retrieveJsMessages(...a: unknown[]): unknown;
}

// A5: navigation-timing key per phase. Native turns each into `app.start.*`.
const PHASES = [['responseEnd', 'responseEnd'], ['DOMContentLoaded', 'domContentLoadedEventStart'], ['load', 'loadEventStart']] as const;

const marked = new Set<string>();

/**
 * Each phase once, as soon as it is known: `deviceready` can beat `load` (slow images), and
 * native assembles `app.start` from whatever marks it has when `markReady()` arrives.
 */
function markPhases() {
  const nav = performance.getEntriesByType?.('navigation')[0] as PerformanceNavigationTiming | undefined;
  for (const [phase, key] of PHASES) {
    // Navigation Timing 2 counts from timeOrigin; the legacy `performance.timing` is already epoch ms.
    const t = nav ? nav[key] && performance.timeOrigin + nav[key] : performance.timing?.[key];
    if (!t || marked.has(phase)) continue;
    marked.add(phase);
    call('markPhase', { phase, ts: Math.round(t) });
  }
}

/** E21: one metric per vital the WebView supports; web-vitals never calls back for the rest. */
function observeVitals() {
  if (!state.options.captureVitals) return;
  const report = (m: Metric) => {
    const screen = currentScreen();
    record({
      type: 'metric',
      metricName: m.name,
      value: m.value,
      timestamp: now(),
      attributes: { 'metric.unit': m.name === 'CLS' ? 'score' : 'ms', 'metric.rating': m.rating, ...(screen && { 'screen.name': screen }) },
    });
    // LCP / CLS / INP are final as the page hides, after core's hidden flush.
    if (document.visibilityState === 'hidden') flush();
  };
  for (const on of [onLCP, onINP, onCLS, onFCP, onTTFB]) on(report);
}

// E20: rAF frame sampler. A frame is the gap between two visible rAF ticks.
const FROZEN_MS = 700; // Android vitals' frozen frame
const freshFrames = () => ({ total: 0, slow: 0, frozen: 0, max: 0, time: 0, longTasks: 0 });
let frames = freshFrames();
let lastTick: number | undefined;
let longTasks = false;

function tick(t: number) {
  const visible = document.visibilityState === 'visible';
  if (visible && lastTick !== undefined) {
    const d = t - lastTick;
    frames.total++;
    frames.time += d;
    frames.max = Math.max(frames.max, d);
    if (d >= (state.options.frameSlowThresholdMs ?? 34)) frames.slow++;
    if (d >= FROZEN_MS) frames.frozen++;
  }
  lastTick = visible ? t : undefined;
  requestAnimationFrame(tick);
}

function sampleFrames() {
  if (!state.options.captureFrames || typeof requestAnimationFrame !== 'function') return;
  requestAnimationFrame(tick);
  if (typeof PerformanceObserver === 'undefined' || !PerformanceObserver.supportedEntryTypes?.includes('longtask')) return;
  longTasks = true;
  new PerformanceObserver((list) => {
    frames.longTasks += list.getEntries().length;
  }).observe({ type: 'longtask' });
}

// E18 / E19: plugin calls timed from `cordova.callbacks` registration to `callbackFromNative`.
const NO_CALLBACK_MS = 30_000;
// Ours, and cordova-android's own `messageChannel` keep-callback (silent until pause / resume).
const UNTIMED = ['EdgeRum', 'CoreAndroid'];
interface Call { service: string; action: string; start: number; timer?: ReturnType<typeof setTimeout> }
const calls = new Map<string, Call>();
const groups = new Map<string, { service: string; action: string; ms: number[]; errors: number }>();

function reportCall(c: Call, ms: number, outcome: string) {
  event('bridge.call', { 'bridge.service': c.service, 'bridge.action': c.action, 'bridge.duration_ms': Math.round(ms), 'bridge.outcome': outcome });
}

function answered(c: Call, ok: boolean) {
  const ms = performance.now() - c.start;
  const key = `${c.service}\n${c.action}`;
  const g = groups.get(key) ?? { service: c.service, action: c.action, ms: [], errors: 0 };
  groups.set(key, g);
  g.ms.push(ms);
  if (!ok) {
    g.errors++;
    reportCall(c, ms, 'error');
  } else if (ms >= (state.options.slowBridgeCallMs ?? 1000)) reportCall(c, ms, 'slow');
}

// ponytail: nearest-rank, no interpolation; windows hold few calls, so the gap rarely shows.
const percentile = (sorted: number[], p: number) => sorted[Math.max(0, Math.ceil((p / 100) * sorted.length) - 1)];

function patchBridge(cordova: Cordova) {
  const original = cordova.callbackFromNative;
  if (!cordova.callbacks || typeof original !== 'function' || typeof Proxy === 'undefined') return;
  cordova.callbacks = new Proxy(cordova.callbacks, {
    set(target, id, value) {
      if (typeof id === 'string' && state.options.captureBridge && !calls.has(id)) {
        // exec registers `service + cordova.callbackId++`: the counter is already past this id.
        const n = String(cordova.callbackId - 1);
        const service = id.endsWith(n) ? id.slice(0, -n.length) : id.replace(/\d+$/, '');
        if (!UNTIMED.includes(service)) {
          const c: Call = { service, action: 'unknown', start: performance.now() };
          c.timer = setTimeout(() => {
            if (calls.get(id) !== c) return;
            calls.delete(id);
            reportCall(c, performance.now() - c.start, 'no_callback');
          }, NO_CALLBACK_MS);
          calls.set(id, c);
        }
      }
      return Reflect.set(target, id, value);
    },
  });
  // ponytail: first result ends the call; a keep-callback stream's later results are not timed.
  cordova.callbackFromNative = function (this: unknown, id: string, isSuccess: boolean, ...rest: unknown[]) {
    const c = calls.get(id);
    if (c) {
      calls.delete(id);
      clearTimeout(c.timer);
      answered(c, !!isSuccess);
    }
    return original.call(this, id, isSuccess, ...rest);
  };
  tagActions(cordova);
}

/**
 * The action never reaches `cordova.callbacks`; it is read where exec hands the call to native,
 * just after registering the callback. Untagged calls keep `bridge.action=unknown`.
 */
function tagActions(cordova: Cordova) {
  const tag = (id: unknown, action: unknown) => {
    const c = calls.get(String(id));
    if (c && typeof action === 'string') c.action = action;
  };
  // iOS exec.js: `messageHandlers.cordova.postMessage([callbackId, service, action, args])`.
  const handler = (window as { webkit?: { messageHandlers?: { cordova?: { postMessage(cmd: unknown): void } } } }).webkit?.messageHandlers?.cordova;
  if (handler) {
    const post = handler.postMessage;
    handler.postMessage = function (cmd: unknown) {
      if (Array.isArray(cmd)) tag(cmd[0], cmd[2]);
      return post.call(this, cmd);
    };
  }
  // Android exec.js: `nativeApiProvider.get().exec(secret, service, action, callbackId, args)` on every call.
  let provider: { get(): NativeApi; set(api: NativeApi): void } | undefined;
  try {
    provider = cordova.require?.('cordova/android/nativeapiprovider') as typeof provider;
  } catch {
    return; // not Android
  }
  const api = provider?.get();
  if (!provider || !api) return;
  provider.set({
    exec: (secret, service, action, id, args) => {
      tag(id, action);
      return api.exec(secret, service, action, id, args);
    },
    setNativeToJsBridgeMode: (...a) => api.setNativeToJsBridgeMode(...a),
    retrieveJsMessages: (...a) => api.retrieveJsMessages(...a),
  });
}

/** E18 / E20: one `frame.summary` and one `bridge.summary` per service + action for the window ending. */
function endWindow(screen?: string) {
  lastTick = undefined; // the next frame starts a fresh gap (hidden time is never a frame)
  const at: Attributes = screen ? { 'screen.name': screen } : {};
  const f = frames;
  frames = freshFrames();
  if (f.total) {
    event('frame.summary', {
      ...at,
      'frame.total_frames': f.total,
      'frame.slow_frames': f.slow,
      'frame.frozen_frames': f.frozen,
      'frame.max_total_duration_ms': Math.round(f.max),
      'frame.slow_frame_rate': Math.round((f.slow / f.total) * 1e4) / 1e4,
      'frame.window_duration_ms': Math.round(f.time),
      'frame.source': 'raf',
      ...(longTasks && { 'frame.long_task_count': f.longTasks }),
    });
  }
  for (const g of groups.values()) {
    const ms = g.ms.sort((a, b) => a - b);
    event('bridge.summary', {
      ...at,
      'bridge.service': g.service,
      'bridge.action': g.action,
      'bridge.count': ms.length,
      'bridge.error_count': g.errors,
      'bridge.p50_ms': Math.round(percentile(ms, 50)),
      'bridge.p95_ms': Math.round(percentile(ms, 95)),
      'bridge.max_ms': Math.round(ms[ms.length - 1]),
    });
  }
  groups.clear();
}

if (live) {
  markPhases();
  document.addEventListener('DOMContentLoaded', markPhases);
  window.addEventListener('load', markPhases);
  // Stamped at the event, not when this listener runs after core's own deviceready work.
  document.addEventListener('deviceready', (e) => {
    markPhases();
    call('markPhase', { phase: 'deviceready', ts: Math.round(performance.timeOrigin + e.timeStamp) });
  }, false);
  patchBridge((globalThis as unknown as { cordova: Cordova }).cordova);
  state.onScreenLeave = endWindow;
  // At deviceready, so a pre-deviceready `init()` decides; web-vitals replays buffered entries.
  whenReady(observeVitals);
  whenReady(sampleFrames);
}
