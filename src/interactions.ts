import { breadcrumb, flush, live, now, record, state, type Attributes } from './core';
import { currentScreen } from './screens';

const WINDOW_MS = 1000; // E25: rage and dead windows
const RAGE_TAPS = 3;
// P4: the elements whose visible text may name them.
const TEXT_OK = 'button, a, [role=button], [role=link], [role=tab], [role=menuitem]';

/** P4: trim, collapse, 64-char cap, digits → `#`. */
const clean = (s: string | null | undefined) => (s ?? '').replace(/\s+/g, ' ').trim().slice(0, 64).replace(/\d/g, '#');

/** P4 name chain. `el` is the control the tap is about (nearest text-eligible ancestor, else the target). */
function nameOf(target: Element, el: Element): [string, string] {
  if (!target.closest('[data-edge-private]')) {
    const action = clean(target.closest('[data-edge-action]')?.getAttribute('data-edge-action'));
    if (action) return [action, 'edge_action'];
    const aria = clean(el.getAttribute('aria-label'));
    if (aria) return [aria, 'aria_label'];
    if (clean(el.id)) return [clean(el.id), 'id'];
    const text = el.matches(TEXT_OK) && !el.closest('[contenteditable]:not([contenteditable=false])') ? clean(el.textContent) : '';
    if (text) return [text, 'text'];
  }
  return [el.tagName.toLowerCase(), 'none'];
}

let recent: { el: Element; at: number }[] = [];
/** ≥ 3 taps on the same control within the window, this one included. */
function rage(el: Element, at: number) {
  recent = recent.filter((r) => at - r.at < WINDOW_MS);
  recent.push({ el, at });
  return recent.filter((r) => r.el === el).length >= RAGE_TAPS;
}

const pending = new Set<{ attrs: Attributes; timer: ReturnType<typeof setTimeout> }>();
const emit = (attrs: Attributes) => record({ type: 'event', eventName: 'ui.interaction', timestamp: now(), attributes: attrs });

// Watching the DOM only while a dead-tap window is open: a whole-document observer is not free.
let observer: MutationObserver | undefined;
function watch(on: boolean) {
  if (on && !observer && typeof MutationObserver !== 'undefined') {
    observer = new MutationObserver(() => state.activity++);
    observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
  } else if (!on) {
    observer?.disconnect();
    observer = undefined;
  }
}

function onTap(ev: MouseEvent) {
  if (!state.options.captureInteractions || !(ev.target instanceof Element)) return;
  const target = ev.target;
  const control = target.closest(`${TEXT_OK}, [data-edge-action]`);
  const el = control ?? target;
  const [label, source] = nameOf(target, el);
  const type = (ev as PointerEvent).pointerType === 'touch' ? 'tap' : 'click';
  breadcrumb('ui', `${type} ${label}`);
  const attrs: Attributes = {
    'ui.type': type,
    'ui.target': label,
    'ui.name_source': source,
    'ui.x': Math.round(ev.clientX),
    'ui.y': Math.round(ev.clientY),
    ...(currentScreen() !== undefined && { 'ui.screen': currentScreen() as string }),
    ...(rage(el, performance.now()) && { 'ui.rage': true }),
  };
  // Dead is judged on controls only: a tap on whitespace or into a text field rightly does nothing.
  if (!control) return emit(attrs);
  const tick = state.activity;
  const entry = {
    attrs,
    timer: setTimeout(() => {
      pending.delete(entry);
      if (!pending.size) watch(false);
      emit(state.activity === tick ? { ...attrs, 'ui.dead': true } : attrs);
    }, WINDOW_MS),
  };
  pending.add(entry);
  watch(true);
}

/** The page may not come back: emit open taps now, unjudged (absent `ui.dead` never accuses). */
function drain() {
  if (!pending.size) return;
  for (const p of pending) {
    clearTimeout(p.timer);
    emit(p.attrs);
  }
  pending.clear();
  watch(false);
  flush();
}

if (live) {
  // E25: capture phase, so the tap is seen before the host's handler navigates or stops it.
  document.addEventListener('click', onTap, true);
  document.addEventListener('pause', drain, false);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') drain();
  });
}
