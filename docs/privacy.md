# Privacy

## What leaves the device by default

- **Request URLs** (`http.url`): scheme, host, explicit port and path only. Query, fragment and `user:pass@` are dropped. Path segments that are all digits, a UUID, or 20+ hex characters become `{id}` (`/orders/1234` → `/orders/{id}`). `sanitizeUrl(url)` runs after this and can remove more.
- **Request and response headers and bodies**: never captured.
- **Screen names**: the hash route if there is one, else the path; query dropped, ids → `{id}` as above. `screenName(path)` or `trackScreen()` override.
- **Tap names** (`ui.target`), first match wins: `data-edge-action` → `aria-label` → `id` → visible text → tag name. Visible text only for buttons, links and `role=button|link|tab|menuitem`; trimmed, max 64 chars, digits → `#`. Values of `input`, `textarea`, `select` and `contenteditable` are never read. Anything inside a `[data-edge-private]` element gets no name.
- **Device id**: a random UUID kept by the plugin (Android SharedPreferences, iOS Keychain). Not an advertising or hardware id.
- **User**: nothing, until you call `identify()`. `id` is then sent on every event; `name`, `email`, `phone` only in one `user.profile.update` each time they change.

Error messages and stack traces are sent as they are; the plugin does not scrub them. Use `beforeSend` if yours may contain personal data.

```html
<div data-edge-private>
  <button>Pay Jane Doe</button> <!-- reported without a name -->
</div>
<button data-edge-action="pay">Pay Jane Doe</button> <!-- reported as "pay" -->
```

## `beforeSend`

`beforeSend(event)` sees every JS-captured event before it leaves the WebView. Return the event (edited or not) to keep it, `null` to drop it. It must be synchronous. If it throws, the event is dropped. Session, user and sequence keys are put back after it runs.

Native events (native crashes, launch time, lifecycle, memory, network, sessions) do not pass through `beforeSend`.

## Consent

| You want | Do |
|---|---|
| Nothing captured until the user agrees | Install with `--variable EDGE_RUM_ENABLED=false`, call `EdgeRum.enable()` on consent. Until then nothing is captured or kept and native crash handlers are not installed. |
| The user opts out | `EdgeRum.disable()`. Remembered across launches; deletes unsent data and the stored user. |
| The user opts back in | `EdgeRum.enable()`. |
| Forget this device | `EdgeRum.reset()`: new device id, new session, user and unsent data deleted. Capture stays on. |

## Storage

Unsent events are kept in app storage excluded from backups (Android `filesDir/edge_rum/`, iOS Application Support), at most 5 MB or 200 batches, and for at most 7 days.
