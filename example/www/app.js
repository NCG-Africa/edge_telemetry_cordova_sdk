// Edge RUM example (spec Q5): hash router, one button + deep link per scenario.
// Deep links: Android `adb shell am start -n com.nathanclaire.rum.example/.MainActivity --es scenario <name>`,
// iOS `xcrun simctl launch booted com.nathanclaire.rum.example -scenario <name>` or `edgerumexample://<name>`.
/* global cordova, EdgeRum */

const native = (action, args = []) => new Promise((ok, fail) => cordova.exec(ok, fail, 'ExampleScenarios', action, args));
const status = (text) => (document.getElementById('status').textContent = text);

const scenarios = {
  // Q4 gate: navigation (this route), http.request, a timed plugin call; going home closes the
  // screen's window, which emits bridge.summary.
  happy: async () => {
    await fetch('ping.json');
    await native('slow', [0]);
    location.hash = '#/';
  },
  'js-error': () => setTimeout(() => {
    throw new Error('Example unhandled error');
  }),
  'native-crash': () => native('crash'),
  'renderer-kill': () => native('killRenderer'),
  // ≥ 5 s main-thread block: app.anr on Android, app.hang on both.
  hang: () => native('hang', [6000]),
  'slow-bridge': () => native('slow', [1500]),
  // Turn on airplane mode first: these queue in the outbox and replay once back online.
  offline: () => {
    for (let i = 0; i < 30; i++) EdgeRum.track('offline.burst', { n: i, online: navigator.onLine });
  },
  // Three taps < 1 s on a button that does nothing: ui.rage + ui.dead.
  'rage-tap': () => {
    const dead = document.getElementById('dead');
    for (let i = 0; i < 3; i++) dead.click();
  },
  'mark-ready': () => EdgeRum.markReady(),
  task: () => {
    EdgeRum.startTask('checkout');
    setTimeout(() => EdgeRum.completeTask('checkout'), 500);
  },
  // 600 > the 500 custom-event cap: 100 drops reported as sdk.health cap.custom.
  caps: () => {
    for (let i = 0; i < 600; i++) EdgeRum.track('caps.burst', { n: i });
  },
};

function render() {
  const name = location.hash.replace(/^#\/?/, '');
  const view = document.getElementById('view');
  view.innerHTML = '';
  if (!scenarios[name]) {
    for (const s of Object.keys(scenarios)) {
      const b = document.createElement('button');
      b.textContent = s;
      b.onclick = () => run(s);
      view.appendChild(b);
    }
    return;
  }
  if (name === 'rage-tap') view.innerHTML = '<button id="dead">Does nothing</button>';
  view.insertAdjacentHTML('beforeend', '<a class="button" href="#/">Back</a>');
}

async function run(name) {
  location.hash = '#/' + name;
  render(); // now, not on hashchange: the scenario may need its route's DOM
  status('running ' + name);
  try {
    await scenarios[name]();
    status('ran ' + name);
  } catch (e) {
    status(name + ' failed: ' + e);
  }
}

// Deep links: native calls runScenario; `listen` hands over one that arrived before deviceready.
window.runScenario = (name) => scenarios[name] && run(name);
window.addEventListener('hashchange', render);
render();
document.addEventListener('deviceready', () => native('listen').then(window.runScenario), false);
