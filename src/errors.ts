import { breadcrumb, breadcrumbsJson, live, now, record, state, type Attributes } from './core';

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
export function crash(err: unknown, handled: boolean, { attrs, where, type = 'Error' }: { attrs?: Attributes; where?: string; type?: string } = {}) {
  const e = err instanceof Error ? err : undefined;
  const stack = e?.stack || where;
  record({
    type: 'event',
    eventName: 'app.crash',
    timestamp: now(),
    attributes: {
      ...attrs,
      message: normaliseStack(e ? e.message : text(err)), // Y2: no raw copy
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
    // A non-Error throw (`throw 'x'`) is the value itself; cross-origin "Script error." has none.
    crash(ev.error ?? ev.message, false, { where });
  });
  window.addEventListener('unhandledrejection', (ev) => {
    if (state.options.captureErrors) crash(ev.reason, false, { type: 'UnhandledRejection' });
  });

  // A3 / E11: console.* → breadcrumbs; console.error → handled crash only when opted in.
  // `busy`: a host `beforeSend` that logs would otherwise re-enter crash → flush → hook forever.
  let busy = false;
  for (const level of ['log', 'info', 'warn', 'error', 'debug'] as const) {
    /* eslint-disable no-console -- wrapping the host's console, not writing to it */
    const original = console[level];
    console[level] = function (...args: unknown[]) {
      if (!busy) {
        busy = true;
        try {
          const line = args.map(text).join(' ');
          if (level === 'error' && state.options.captureConsoleErrors) crash(args.find((a) => a instanceof Error) ?? line, true, { type: 'ConsoleError' });
          breadcrumb('console', line, { level });
        } catch {
          // Capture must never break the host's logging.
        } finally {
          busy = false;
        }
      }
      return original.apply(this, args);
    };
    /* eslint-enable no-console */
  }
}
