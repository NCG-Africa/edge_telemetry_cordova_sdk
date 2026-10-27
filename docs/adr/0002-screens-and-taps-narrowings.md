# 0002 — How screens and taps read the stricter-than-written rules

Status: accepted 2026-10-27 (#31)

## Context

P2 says "hash route if present, else path". E25 says `ui.dead=true` when a tap gets "no DOM mutation/nav/request within 1 s", says nothing about which taps, and capture is "click/touch". E4 says `trackScreen()` "overrides". Read literally, each of these gives noisy or wrong data in a real app.

## Decision

- **Hash routes** are hashes starting `#/` or `#!/`. Any other hash (`#top`, `#section-2`) is an in-page anchor and the screen stays the path.
- **`ui.dead`** is judged only on taps on a control: `button`, `a`, `[role=button|link|tab|menuitem]`, or anything inside `[data-edge-action]`. A tap on blank space or into a text field rightly does nothing, so judging it would flood the signal. `ui.dead` is sent only when `true`, like `ui.rage`. Taps still open when the page hides or unloads are sent without a verdict.
- **Touch**: one capture-phase `click` listener, so a tap is never counted twice. `ui.type` is `tap` when the click's `pointerType` is `touch`, or a `touchstart` came less than 1 s before it (older WebViews send a plain MouseEvent). Otherwise it is `click`.
- **`trackScreen()` overrides** the URL screen in either order. URL changes are reported 100 ms late (timed and stamped at the change, so the delay never shows in the data). A `trackScreen()` in that window cancels the URL screen. A URL change within 100 ms after `trackScreen()` belongs to it.

## Consequences

- A router that names its screen more than 100 ms after its URL change still reports twice with auto capture on. The router recipes in the README turn auto capture off, so this case should not come up.
- `navigation` rows arrive up to 100 ms after the URL changes. Each `navigation` row still records the time of the URL change itself, so the timeline is right.
- Dead-tap counts cover controls only. If a host wants dead taps on custom controls, it marks them with `data-edge-action`.
