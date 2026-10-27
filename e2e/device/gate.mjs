// Spec Q4 gate: drive the built example/ on a booted Android emulator or iOS simulator through the
// `happy` deep link, then assert the batches mock-ingest received. No Appium.
// Usage: node e2e/device/gate.mjs android|ios   (after scripts/example-build.sh <platform>)
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platform = process.argv[2];
const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const APP_ID = 'com.nathanclaire.rum.example';
const INGEST = 'http://localhost:4319';
const TIMEOUT_MS = 120_000;

const sh = (cmd, ...args) => execFileSync(cmd, args, { stdio: ['ignore', 'pipe', 'inherit'] }).toString();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const uninstall = (cmd, ...args) => {
  try {
    sh(cmd, ...args); // fresh device_id + session
  } catch {
    // not installed
  }
};

const drivers = {
  android: {
    install() {
      uninstall('adb', 'uninstall', APP_ID);
      sh('adb', 'install', join(root, 'example/platforms/android/app/build/outputs/apk/debug/app-debug.apk'));
    },
    // Cold launch with the deep link as an intent extra.
    async happy() {
      sh('adb', 'shell', 'am', 'start', '-W', '-n', `${APP_ID}/.MainActivity`, '--es', 'scenario', 'happy');
    },
    background: () => sh('adb', 'shell', 'input', 'keyevent', 'KEYCODE_HOME'),
  },
  ios: {
    install() {
      const build = join(root, 'example/platforms/ios/build/Debug-iphonesimulator');
      const app = readdirSync(build).find((f) => f.endsWith('.app'));
      uninstall('xcrun', 'simctl', 'uninstall', 'booted', APP_ID);
      sh('xcrun', 'simctl', 'install', 'booted', join(build, app));
    },
    // Cold launch with the deep link as a launch argument: `simctl openurl` stops at an "Open in…?" prompt.
    async happy() {
      sh('xcrun', 'simctl', 'launch', 'booted', APP_ID, '-scenario', 'happy');
    },
    background: () => sh('xcrun', 'simctl', 'launch', 'booted', 'com.apple.Preferences'),
  },
};

const driver = drivers[platform];
if (!driver) {
  console.error('usage: node e2e/device/gate.mjs android|ios');
  process.exit(2);
}

const ingest = spawn(process.execPath, [join(root, 'e2e/mock-ingest-server.mjs')], { stdio: 'inherit' });

async function requests() {
  return (await (await fetch(`${INGEST}/__requests`)).json()).requests;
}

const GATE = ['session.started', 'app.start', 'navigation', 'http.request', 'bridge.summary'];
const events = (reqs) => reqs.flatMap((r) => r.parsed?.events ?? []);
const named = (reqs, name) => events(reqs).filter((e) => e.eventName === name);

try {
  for (let i = 0; ; i++) {
    try {
      await fetch(`${INGEST}/__health`);
      break;
    } catch (e) {
      if (i > 50) throw e;
      await sleep(100);
    }
  }
  driver.install();
  await driver.happy();
  await sleep(8000); // happy runs, JS hands off (2 s)
  driver.background(); // seals the open segment (T3) and ends the app.start window

  const deadline = Date.now() + TIMEOUT_MS;
  let reqs = await requests();
  while (GATE.some((n) => named(reqs, n).length === 0) && Date.now() < deadline) {
    await sleep(2000);
    reqs = await requests();
  }
  console.log(`[gate] ${reqs.length} batches, events: ${[...new Set(events(reqs).map((e) => e.eventName))].join(', ')}`);

  for (const n of GATE) assert.ok(named(reqs, n).length > 0, `no ${n}`);

  // Envelope: R1/R2 header, gzip, contract 4 (spec T5, W1, W2).
  for (const r of reqs) {
    assert.equal(r.headers['content-encoding'], 'gzip');
    assert.equal(r.headers['x-api-key'], 'example-key');
    assert.equal(r.parseError, null);
    const b = r.parsed;
    assert.deepEqual(Object.keys(b).sort(), ['app', 'batch_size', 'contract_version', 'device_id', 'events', 'sdk', 'timestamp', 'type']);
    assert.equal(b.type, 'telemetry_batch');
    assert.equal(b.contract_version, '4.0.0');
    assert.match(b.timestamp, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$/);
    assert.equal(b.batch_size, b.events.length);
    assert.ok(b.device_id);
    assert.equal(b.sdk.name, 'cordova');
    assert.ok(b.sdk.version);
    assert.equal(b.app.package_name, APP_ID);
    assert.equal(b.app.platform, platform);
    assert.ok(b.app.version);
  }

  const start = named(reqs, 'app.start')[0].attributes;
  for (const k of ['app.start.duration_ms', 'app.start.webview_created_ms', 'app.start.load_ms', 'app.start.deviceready_ms']) {
    assert.equal(typeof start[k], 'number', `app.start without ${k}`);
  }
  assert.ok(named(reqs, 'navigation').some((e) => e.attributes['navigation.to_screen'] === '/happy'), 'no navigation to /happy');
  assert.ok(named(reqs, 'http.request').some((e) => e.attributes['http.url'].endsWith('/ping.json')), 'no http.request for ping.json');
  assert.ok(named(reqs, 'bridge.summary').some((e) => e.attributes['bridge.service'] === 'ExampleScenarios'), 'no bridge.summary for ExampleScenarios');
  console.log(`[gate] ${platform} OK`);
} catch (e) {
  console.error(`[gate] ${platform} FAILED`, e);
  console.error(JSON.stringify(events(await requests().catch(() => [])), null, 1));
  process.exitCode = 1;
} finally {
  ingest.kill();
}
