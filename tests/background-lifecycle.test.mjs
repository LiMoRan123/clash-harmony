import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { setTimeout as delay } from 'node:timers/promises';
const require = createRequire(import.meta.url);
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const read = name => fs.readFileSync('entry/src/main/ets/' + name + '.ets', 'utf8');
function evaluate(source, kits, globals = {}, timers = setTimeout) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(code, { module, exports: module.exports, require: name => {
    assert.ok(kits[name], 'dependency: ' + name); return kits[name];
  }, setTimeout: timers, clearTimeout, console, ...globals });
  return module.exports;
}
const journals = [];
const notices = [];
const notifications = [];
let cancel;
let starts = 0;
let stops = 0;
let startTask = async () => ({ notificationId: 17, continuousTaskId: 42 });
let agentTask = async () => ({});
let now = 100000;
let publishTask = async () => {};
const kits = {
  '@kit.AbilityKit': { wantAgent: {
    getWantAgent: info => { assert.equal(info.wants[0].abilityName, 'EntryAbility'); return agentTask(); },
    OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 }
  } },
  '@kit.BackgroundTasksKit': { backgroundTaskManager: {
    on: (name, callback) => { assert.equal(name, 'continuousTaskCancel'); cancel = callback; },
    startBackgroundRunning: async (context, modes) => {
      assert.deepEqual(Array.from(modes), ['dataTransfer']); starts++; return startTask();
    },
    stopBackgroundRunning: async () => { stops++; }
  } },
  '@kit.NotificationKit': { notificationManager: {
    SlotType: { LIVE_VIEW: 1 }, ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 1 },
    publish: async request => { notifications.push(request); return publishTask(); }
  } },
  './RuntimeDiagnostics': { RuntimeDiagnostics: { append: (...args) => journals.push(args) } }
};
const globals = { AppStorage: { setOrCreate: (key, value) => notices.push([key, value]) },
  Date: { now: () => now } };
const { VpnBackgroundService: Background } = evaluate(read('services/VpnBackgroundService'), kits, globals);
Background.configure({ filesDir: '/fixture' });
await Background.setEnabled(true);
await Background.setEnabled(true);
assert.equal(starts, 1, 'repeated connected events must not create additional tasks');
Background.updateTraffic(1048576, 1048576);
await delay(0);
assert.equal(notifications.length, 1);
assert.equal(notifications[0].id, 17, 'update the task-owned notification rather than create another');
assert.equal(notifications[0].template.data.progressValue, 2048, 'progress uses actual KiB transferred');
assert.match(notifications[0].content.systemLiveView.text, /2.0 MB/);
Background.updateTraffic(2097152, 1048576);
assert.equal(notifications.length, 1, 'notifications are throttled rather than published on every frame');
now += 30001;
Background.updateTraffic(2097152, 1048576);
assert.equal(notifications.length, 2);
await delay(0);
now += 30001;
Background.updateTraffic(2097152, 1048576);
assert.equal(notifications.length, 2, 'idle traffic does not fabricate progress');
cancel({ id: 123, reason: 4 });
assert.equal(Background.active, true, 'an unrelated task cancellation cannot clear the VPN task');
cancel({ id: 42, reason: 4 });
await delay(10);
assert.equal(starts, 1, 'system cancellation does not start a background retry loop');
Background.onForeground();
await delay(0);
assert.equal(starts, 2, 'foreground entry can retry a system-cancelled task');
cancel({ id: 42, reason: 3 });
Background.onForeground();
await delay(0);
assert.equal(starts, 2, 'removing the task notification is respected');
await Background.setEnabled(false);
await Background.setEnabled(true);
assert.equal(starts, 3, 'explicit new VPN session can acquire a new task');
let completeNotice;
publishTask = () => new Promise(resolve => { completeNotice = resolve; });
now += 30001;
Background.updateTraffic(2097152, 1048576);
const pendingStop = Background.setEnabled(false);
await delay(0);
assert.equal(stops, 0, 'a queued notification completes before cancelling its owning task');
completeNotice();
await pendingStop;
publishTask = async () => {};
assert.equal(stops, 1);
Background.updateTraffic(3e6, 3e6);
assert.equal(notifications.length, 3, 'late traffic after disconnection cannot republish a notification');

// A stop during an in-flight SDK start must release the newly acquired task.
let completeStart;
startTask = () => new Promise(resolve => { completeStart = resolve; });
const starting = Background.setEnabled(true);
await delay(0);
const stopping = Background.setEnabled(false);
completeStart({ notificationId: 18, continuousTaskId: 43 });
await Promise.all([starting, stopping]);
assert.equal(Background.active, false);
assert.equal(stops, 2);
startTask = async () => { throw Object.assign(new Error('denied'), { code: 201 }); };
await Background.setEnabled(true);
assert.equal(Background.active, false);
assert.ok(journals.some(args => /错误码 201/.test(args[2])), 'permission errors remain visible in persistent diagnostics');
await Background.setEnabled(false);

// Exercise the real private control transport, including session validation.
let subscribeInfo;
let commandCallback;
let publication;
let unsubscribes = 0;
let makeSubscriber = async info => { subscribeInfo = info; return { id: 9 }; };
const manager = {
  createSubscriber: info => makeSubscriber(info),
  subscribe: (subscriber, callback) => { commandCallback = callback; },
  publish: (name, options, callback) => { publication = { name, options }; callback(); },
  unsubscribe: () => { unsubscribes++; }
};
const { VpnControlChannel: Control } = evaluate(read('services/VpnControlChannel'), {
  '@kit.BasicServicesKit': { commonEventManager: manager }
});
const control = new Control();
const commands = [];
await control.subscribe((...args) => commands.push(args));
assert.equal(subscribeInfo.publisherBundleName, 'io.github.clashharmony.app');
for (const command of [{ action: 'stop', sessionId: '' }, { action: 'bad', sessionId: 's' },
  { action: 'stop', sessionId: 1 }]) commandCallback(undefined, { data: JSON.stringify(command) });
assert.equal(commands.length, 0);
commandCallback(undefined, { data: JSON.stringify({ action: 'stop', sessionId: 's' }) });
assert.deepEqual(commands, [['stop', 's']]);
Control.send('status', 's');
assert.equal(publication.options.bundleName, 'io.github.clashharmony.app');
assert.equal(JSON.parse(publication.options.data).action, 'status');
control.close();
commandCallback(undefined, { data: JSON.stringify({ action: 'stop', sessionId: 's' }) });
assert.equal(commands.length, 1, 'destroyed extensions ignore late commands');
let completeSubscribe;
makeSubscriber = () => new Promise(resolve => { completeSubscribe = resolve; });
const late = new Control();
const subscribing = late.subscribe(() => {});
late.close();
completeSubscribe({ id: 10 });
await subscribing;
assert.equal(unsubscribes, 2, 'late subscriber creation after destruction is cleaned up');

// SDK acknowledgement alone is insufficient if events are enabled: confirm
// route release by event, or prove that the system has no remaining VPN.
let sdkCalls = 0;
let sends = 0;
let systemVpn = false;
let waitMode = 'ready';
const serviceKits = {
  '@kit.NetworkKit': { vpnExtension: {
    stopVpnExtensionAbility: async () => { sdkCalls++; }, startVpnExtensionAbility: async () => {}
  }, connection: {
    getAllNets: async () => [{ netId: 1 }], getNetCapabilities: async () => ({ bearerTypes: systemVpn ? [4] : [1] }),
    NetBearType: { BEARER_VPN: 4 }
  } },
  './VpnControlChannel': { VpnControlChannel: { send: () => { sends++; } } },
  './VpnRuntimeEvents': { VpnRuntimeEvents: { waitFor: async (session, phases, ms) => {
    if (waitMode === 'ready') return { phase: 'disconnected' };
    await delay(ms === 800 ? 5 : 40); return undefined;
  } } },
  './VpnBackgroundService': { VpnBackgroundService: { setEnabled: async () => {} } },
  'libentry.so': { default: {} }
};
const { VpnService } = evaluate(read('services/VpnService'), serviceKits);
assert.equal(await VpnService.stopAndConfirm('s', true), true);
assert.equal(sdkCalls, 0, 'the fast path does not destroy the extension before it finishes native cleanup');
assert.equal(await VpnService.start('/fixture.yaml', 'next'), true);
assert.equal(sdkCalls, 1, 'a rapid reconnect retires the old extension before starting a new session');
waitMode = 'lost';
assert.equal(await VpnService.stopAndConfirm('s', true), true, 'missing event recovers using a successful SDK stop and system route check');
systemVpn = true;
assert.equal(await VpnService.stopAndConfirm('s', true), false, 'another remaining VPN cannot be treated as proof that ours stopped');
serviceKits['@kit.NetworkKit'].connection.getAllNets = async () => { throw new Error('service unavailable'); };
assert.equal(await VpnService.hasSystemVpn(), undefined, 'status query failure must not be reported as no VPN');
assert.equal(await VpnService.stopAndConfirm('s', true), false);
assert.equal(sends, 4);

// Execute production foreground reconciliation and stream failure handling.
const index = read('pages/Index');
const method = name => {
  const match = index.match(new RegExp('  private (?:async )?' + name + '\\([^]*?\\n  \\}'));
  assert.ok(match, name); return match[0];
};
let controllerAvailable = false;
let visibleSystemVpn;
let finishMetadata;
const { Ui } = evaluate('export class Ui {\n' + ['resumeRuntimeIfControllerAvailable',
  'reconcileRuntimeAfterStreamFailure'].map(method).join('\n') + '\n}', {}, {
  VpnControlChannel: { send() {} },
  VpnBackgroundService: { setEnabled: async () => {} },
  VpnService: { hasSystemVpn: async () => visibleSystemVpn },
  CoreBridgeService: { markControllerReady: () => ({}) },
  CoreService: { createSummary: () => ({ state: 'stopped' }) },
  MihomoControllerService: {
    waitForVersion: async () => ({ available: controllerAvailable, version: 'test' }),
    checkVersion: async () => ({ available: false })
  }
});
function makeUi() {
  return Object.assign(new Ui(), { vpnTunnelActive: true, homeRefreshGeneration: 1, sessionId: 's',
    toggling: false, summary: {}, statusMessage: '', recordLog() {},
    isRuntimeConnected() { return this.vpnTunnelActive; },
    handleRuntimeUnavailable() { this.vpnTunnelActive = false; },
    waitForVpnTunReady: async () => ({ ready: true }),
    refreshControllerProxies: async () => {}, refreshConnections: async () => {},
    syncHomeRuntimeFields() {}, createLiveSummary: () => ({ state: 'running' }),
    resetHomeTrafficBaseline() {},
    refreshHomeNetwork() { this.networkProbeStarts = (this.networkProbeStarts ?? 0) + 1; },
    startRuntimePolling() { this.streamStarts = (this.streamStarts ?? 0) + 1; }
  });
}
const unknown = makeUi();
await unknown.reconcileRuntimeAfterStreamFailure();
assert.equal(unknown.vpnTunnelActive, true, 'one unavailable data channel cannot mark a real VPN disconnected');
await unknown.resumeRuntimeIfControllerAvailable();
assert.equal(unknown.vpnTunnelActive, true, 'an unknown system query cannot falsely clear a live session');
visibleSystemVpn = false;
await unknown.resumeRuntimeIfControllerAvailable();
assert.equal(unknown.vpnTunnelActive, false, 'absence of any system VPN confirms a disconnected runtime');
controllerAvailable = true;
const noRoute = makeUi();
await noRoute.resumeRuntimeIfControllerAvailable();
assert.equal(noRoute.vpnTunnelActive, false, 'a controller and its cached TUN configuration are insufficient when the system route is gone');
assert.equal(noRoute.networkProbeStarts, undefined, 'controller-only mode must not trigger automatic exit probes');
visibleSystemVpn = true;
const resumed = makeUi();
await resumed.resumeRuntimeIfControllerAvailable();
assert.equal(resumed.streamStarts, 1, 'foreground reconciliation recovers the live data channel');
assert.equal(resumed.networkProbeStarts, 1, 'recovered VPN sessions request automatic exit and service checks');
const staleUi = makeUi();
staleUi.refreshControllerProxies = () => new Promise(resolve => { finishMetadata = resolve; });
const metadataRefresh = staleUi.resumeRuntimeIfControllerAvailable();
await delay(0);
staleUi.homeRefreshGeneration++;
staleUi.vpnTunnelActive = false;
staleUi.summary = { state: 'stopped' };
finishMetadata();
await metadataRefresh;
assert.equal(staleUi.summary.state, 'stopped', 'a delayed foreground refresh cannot revive UI state after a new stop');
assert.equal(staleUi.streamStarts, undefined);

const files = new Map();
const handles = new Map();
let fd = 0;
const io = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
  readTextSync: path => { if (!files.has(path)) throw new Error('absent'); return files.get(path); },
  openSync: path => { handles.set(++fd, path); return { fd }; },
  writeSync: (descriptor, text) => files.set(handles.get(descriptor), text),
  closeSync: file => { handles.delete(file.fd); }
};
const { RuntimeDiagnostics: Journal } = evaluate(read('services/RuntimeDiagnostics'), {
  '@kit.CoreFileKit': { fileIo: io }
});
const context = { filesDir: '/fixture' };
for (let count = 0; count < 45; count++) Journal.append(context, 'ui', 'entry-' + count);
Journal.append(context, 'vpn', '阶段 connected');
assert.equal(files.get('/fixture/runtime-ui.log').trim().split('\n').length, 40);
assert.equal(Journal.read(context).length, 41, 'UI and extension journals are read together without sharing a writer');
assert.equal(handles.size, 0, 'journal writes always close their file handles');
io.openSync = () => { throw new Error('disk unavailable'); };
assert.doesNotThrow(() => Journal.append(context, 'vpn', '阶段 disconnected'), 'diagnostic storage failure cannot prevent disconnecting');
console.log('background-lifecycle: task ownership, real traffic updates, cancellation, startup/stop races, private control and confirmed route release passed');
