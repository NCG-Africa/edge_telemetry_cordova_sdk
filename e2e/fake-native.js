// Spec Q2: fake native for the browser harness, shaped like cordova.js + cordova-ios exec.js
// (callbacks map, callbackFromNative, message handler) so E18 bridge timing runs as on device.
// Logs every EdgeRum exec (the specs pin the A2 table against it) and posts each `enqueue` to
// mock-ingest as a contract-4 batch, as the sender would. Other services answer after `delayMs`.
window.__exec = [];
window.__plugin = { delayMs: 0 };

function answer(id, ok, result, keep) {
  cordova.callbackFromNative(id, ok, ok ? 1 : 9, [result], keep);
}

function native([id, service, action, args]) {
  if (service !== 'EdgeRum') {
    setTimeout(() => answer(id, true, 'ok', false), window.__plugin.delayMs);
    return;
  }
  window.__exec.push({ service, action, args: JSON.parse(JSON.stringify(args)) });
  if (action === 'subscribe') return;
  if (action === 'getState') {
    const state = { enabled: true, sessionId: 'harness-session', sampled: true, configured: true, sdkVersion: '0.0.0', deviceStartedAt: Date.now() };
    setTimeout(() => answer(id, true, state, false));
    return;
  }
  if (action !== 'enqueue') {
    setTimeout(() => answer(id, true, undefined, false));
    return;
  }
  const { events } = args[0];
  const batch = {
    type: 'telemetry_batch',
    contract_version: '4.0.0',
    timestamp: new Date().toISOString(),
    batch_size: events.length,
    device_id: 'harness-device',
    sdk: { name: 'cordova', version: '0.0.0' },
    app: { name: 'harness', version: '1.0.0', build_number: '1', platform: 'ios' },
    events,
  };
  fetch('http://localhost:4319/collector/telemetry', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-Key': 'edge_test_key' },
    body: JSON.stringify(batch),
  }).then((r) => answer(id, r.ok, r.status, false), () => answer(id, false, 0, false));
}

window.webkit = { messageHandlers: { cordova: { postMessage: native } } };
window.cordova = {
  platformId: 'ios',
  callbackId: Math.floor(Math.random() * 2000000000),
  callbacks: {},
  callbackFromNative(id, isSuccess, status, args, keepCallback) {
    const cb = cordova.callbacks[id];
    if (!cb) return;
    if (!keepCallback) delete cordova.callbacks[id];
    const f = isSuccess ? cb.success : cb.fail;
    if (f) f.apply(null, args);
  },
  exec(success, fail, service, action, args) {
    let id = 'INVALID';
    if (success || fail) {
      id = service + cordova.callbackId++;
      cordova.callbacks[id] = { success, fail };
    }
    window.webkit.messageHandlers.cordova.postMessage([id, service, action, JSON.parse(JSON.stringify(args || []))]);
  },
};
