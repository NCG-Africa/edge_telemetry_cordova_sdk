// Spec Q2: fake native for the browser harness. Logs every exec (the specs pin the A2 table
// against it) and posts each `enqueue` to mock-ingest as a contract-4 batch, as the sender would.
window.__exec = [];
window.cordova = {
  platformId: 'android',
  exec(ok, fail, service, action, args) {
    window.__exec.push({ service, action, args: JSON.parse(JSON.stringify(args)) });
    if (action === 'subscribe') return;
    if (action === 'getState') {
      const state = { enabled: true, sessionId: 'harness-session', sampled: true, configured: true, sdkVersion: '0.0.0', deviceStartedAt: Date.now() };
      setTimeout(() => ok(state));
      return;
    }
    if (action !== 'enqueue') {
      setTimeout(ok);
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
      app: { name: 'harness', version: '1.0.0', build_number: '1', platform: 'android' },
      events,
    };
    fetch('http://localhost:4319/collector/telemetry', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-API-Key': 'edge_test_key' },
      body: JSON.stringify(batch),
    }).then((r) => (r.ok ? ok() : fail(r.status)), fail);
  },
};
