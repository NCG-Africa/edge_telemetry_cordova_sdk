import { breadcrumb, breadcrumbsJson, live, record, state, type Attributes } from './core';

// Y2: the origins Cordova serves www/ from. Path kept, query/hash dropped, line:col kept.
// The lazy path stops at the first `:line(:col)` that ends the frame. Ports aren't ours.
const SAME_ORIGIN = /(?:(?:https?|app|ionic):\/\/localhost|file:\/\/\/[^\s()]*?\/www)\/([^\s()?#]*?)(?:[?#][^\s()]*?)?(?=(?::\d+){1,2}(?![^\s)])|[\s)]|$)/g;

/** Y2: rewrite same-origin frames to `app:///<path under www>`; other origins untouched. */
export const normaliseStack = (stack: string) => stack.replace(SAME_ORIGIN, 'app:///$1');

const text = (v: unknown) => {
  if (typeof v === 'string') return v;
  if (v instanceof Error) return `${v.name}: ${v.message}`;
  try {
    return JSON.stringify(v) ?? String(v);
  } catch {
    return String(v);
  }
};

/**
 * E9–E11: one `app.crash`. `where` is a fallback frame when there is no Error to read a stack
 * from; `type` names non-Error throws.
 */
export function crash(err: unknown, handled: boolean, attrs?: Attributes, where?: string, type = 'Error') {
  const e = err instanceof Error ? err : undefined;
  const stack = e?.stack || where;
  record({
    type: 'event',
    eventName: 'app.crash',
    timestamp: new Date().toISOString(),
    attributes: {
      ...attrs,
      message: e ? e.message : text(err),
      exception_type: e ? e.name : type,
      ...(stack && { stacktrace: normaliseStack(stack) }),
      handled,
      is_fatal: !handled,
      runtime: 'webview',
      'crash.breadcrumbs': breadcrumbsJson(),
      ...(state.options.release && { release: state.options.release }),
    },
  });
}

if (live) {
  window.addEventListener('error', (ev) => {
    if (!state.options.captureErrors) return;
    const where = ev.filename ? `at ${ev.filename}:${ev.lineno}:${ev.colno}` : undefined;
    crash(ev.error instanceof Error ? ev.error : ev.message, false, {}, where);
  });
  window.addEventListener('unhandledrejection', (ev) => {
    if (state.options.captureErrors) crash(ev.reason, false, {}, undefined, 'UnhandledRejection');
  });

  // A3 / E11: console.* → breadcrumbs; console.error → handled crash only when opted in.
  for (const level of ['log', 'info', 'warn', 'error', 'debug'] as const) {
    /* eslint-disable no-console -- wrapping the host's console, not writing to it */
    const original = console[level];
    console[level] = function (...args: unknown[]) {
      try {
        if (level === 'error' && state.options.captureConsoleErrors) {
          const err = args.find((a) => a instanceof Error);
          crash(err ?? args.map(text).join(' '), true, {}, undefined, 'ConsoleError');
        }
        breadcrumb('console', args.map(text).join(' '), { level });
      } catch {
        // Capture must never break the host's logging.
      }
      return original.apply(this, args);
    };
    /* eslint-enable no-console */
  }
}
