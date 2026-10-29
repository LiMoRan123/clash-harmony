import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { setTimeout as delay } from 'node:timers/promises';

const require = createRequire(import.meta.url);
const ts = require(process.env.ARKTS_TYPESCRIPT_PATH ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = process.cwd();
const events = [];
const phasePackets = [];
let controllerReady = { available: false, version: '' };
let sdkStop = async () => {};
let nativeStop;
let created;
let nativeStarts = 0;
let routeDestroy = async () => { events.push('destroy-route'); };
let command;
const coreState = { coreMode: 'stopped', nativeFd: -1, controllerReady: false, stopCount: 1, lastError: '' };
const core = {
  stopTun: () => { events.push('queue-native-stop'); return nativeStop(); },
  startTun: () => { nativeStarts++; return { ...coreState, running: true }; },
  markControllerReady: () => coreState,
  getState: () => coreState
};
const connection = {
  create: () => created(), destroy: () => routeDestroy(), protectProcessNet: async () => {}
};
const network = { vpnExtension: {
  stopVpnExtensionAbility: () => sdkStop(),
  createVpnConnection: () => connection
}, VpnExtensionAbility: class {} };
function evaluate(source, filename, extra = {}) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, fileName: filename
  }).outputText;
  vm.runInNewContext(code, {
    module, exports: module.exports, Error, console,
    setTimeout: (callback, ms) => setTimeout(callback, Math.min(ms, 80)), clearTimeout,
    require: name => {
      if (name === '@kit.AbilityKit') return {};
      if (name === '@kit.NetworkKit') return network;
      if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {}, error() {} } };
      if (name === 'libentry.so') return { default: { protectSocket() {} } };
      if (name.endsWith('CoreBridgeService')) return { CoreBridgeService: core };
      if (name.endsWith('MihomoControllerService')) return { MihomoControllerService: {
        waitForVersion: async () => controllerReady
      } };
      if (name.endsWith('VpnRuntimeEvents')) return { VpnRuntimeEvents: { publish(event) { phasePackets.push(event); } } };
      if (name.endsWith('VpnControlChannel')) return { VpnControlChannel: class {
        async subscribe(callback) { command = callback; } close() {}
      } };
      if (name.endsWith('RuntimeDiagnostics')) return { RuntimeDiagnostics: { append() {} } };
      if (name.endsWith('VpnBackgroundService')) return { VpnBackgroundService: { setEnabled: async () => {} } };
      throw new Error('Unexpected dependency ' + name);
    }, ...extra
  }, { filename });
  return module.exports;
}
const read = file => fs.readFileSync(path.join(root, 'entry/src/main/ets', file), 'utf8');
const { VpnService } = evaluate(read('services/VpnService.ets'), 'VpnService.ets');
sdkStop = () => new Promise(() => {});
assert.equal(await VpnService.stop(20), false, 'SDK stop timeout must resolve instead of keeping the UI pending');
sdkStop = async () => { throw new Error('IPC failure'); };
assert.equal(await VpnService.stop(20), false);
sdkStop = async () => {};
assert.equal(await VpnService.stop(20), true);

const Extension = evaluate(read('vpnextensionability/ClashVpnExtensionAbility.ets'), 'VpnExtension.ets').default;
const ext = new Extension();
ext.connection = connection;
ext.tunFd = 42;
let completeNative;
nativeStop = () => new Promise(resolve => { completeNative = resolve; });
const cleanup = ext.stopTunnel();
assert.equal(ext.stopTunnel(), cleanup, 'repeated destruction shares a single cleanup task');
assert.deepEqual(events, ['queue-native-stop', 'destroy-route'],
  'system VPN route destruction starts without waiting for Go shutdown');
assert.equal(ext.tunFd, -1);
let finished = false;
cleanup.then(() => { finished = true; });
await delay(10);
assert.equal(finished, false);
completeNative(coreState);
await cleanup;

events.length = 0;
const failing = new Extension();
failing.connection = connection;
routeDestroy = async () => { events.push('destroy-route'); throw new Error('route destroy failed'); };
nativeStop = async () => coreState;
await failing.stopTunnel();
assert.ok(events.includes('queue-native-stop'), 'native cleanup is still attempted when route destruction fails');

routeDestroy = async () => { events.push('destroy-route'); };
let completeCreate;
created = () => new Promise(resolve => { completeCreate = resolve; });
const racing = new Extension();
racing.connection = connection;
const startup = racing.startTunnel();
racing.onDestroy();
completeCreate(43);
await startup;
await racing.stopTunnel();
assert.equal(nativeStarts, 0, 'a TUN created after destruction must not start a new native core');
assert.equal(racing.tunFd, -1);

// Validate the actual extension's session/phase contract used by the UI waiter.
created = async () => 44;
controllerReady = { available: true, version: 'fixture-core' };
const successful = new Extension();
successful.connection = connection;
successful.captureWant({ parameters: { configPath: '/fixture.yaml', sessionId: 'run-success' } });
await successful.startTunnel();
assert.deepEqual(phasePackets.map(event => event.phase), ['creating', 'starting', 'verifying', 'connected']);
assert.equal(phasePackets.at(-1).version, 'fixture-core');
successful.onDestroy();
await successful.stopTunnel();
assert.deepEqual(phasePackets.map(event => event.phase),
  ['creating', 'starting', 'verifying', 'connected', 'stopping', 'disconnected']);
assert.ok(phasePackets.every((event, index) => event.sessionId === 'run-success' && event.sequence === index + 1));
assert.ok(phasePackets.every(event => !Object.hasOwn(event, 'configPath')));

// Exercise the actual extension entry point and its control callback. The
// route confirmation must precede native completion, and a late completion
// after framework destruction must not stop a newer extension instance.
phasePackets.length = 0;
let sdkStops = 0;
sdkStop = async () => { sdkStops++; };
nativeStop = () => new Promise(resolve => { completeNative = resolve; });
const controlled = new Extension();
controlled.onCreate({ parameters: { configPath: '/fixture.yaml', sessionId: 'controlled' } });
await delay(0);
assert.equal(phasePackets.at(-1).phase, 'connected');
command('stop', 'old-session');
assert.equal(controlled.stopping, false, 'a previous session cannot stop the active VPN');
command('stop', 'controlled');
command('stop', 'controlled');
await delay(0);
assert.equal(phasePackets.at(-1).phase, 'disconnected', 'system route release is acknowledged while native shutdown is pending');
assert.equal(sdkStops, 0);
controlled.onDestroy();
completeNative(coreState);
await controlled.stopTunnel();
await delay(0);
assert.equal(sdkStops, 0, 'late native completion of a destroyed extension cannot stop its replacement');
nativeStop = async () => coreState;
const clean = new Extension();
clean.onCreate({ parameters: { configPath: '/fixture.yaml', sessionId: 'clean' } });
await delay(0);
command('status', 'clean');
assert.equal(phasePackets.at(-1).version, 'fixture-core', 'status replay preserves the controller version');
command('stop', 'clean');
await delay(0);
assert.equal(sdkStops, 1, 'completed cleanup retires its own extension exactly once');

const indexSource = read('pages/Index.ets');
function method(name) {
  const match = indexSource.match(new RegExp('  private (?:async )?' + name + '\\([^]*?\\n  \\}'));
  assert.ok(match, 'production method exists: ' + name);
  return match[0];
}
const source = 'export class Ui {\n' + method('toggleVpn') + '\n' + method('connectionPhase') +
  '\n' + method('refreshConnections') + '\n}';
let stopResult = false;
let refreshRestarts = 0;
const uiCore = { ...core, markControllerReady: () => coreState };
const { Ui } = evaluate(source, 'Ui.ts', {
  LOG_DOMAIN: 1, LOG_TAG: 'Test', hilog: { info() {}, error() {} },
  CoreBridgeService: uiCore, VpnService: { stopAndConfirm: async () => stopResult },
  CoreService: { createSummary: () => ({ state: 'stopped' }) },
  TrafficPollerService: { stop() {} },
  MihomoControllerService: {}
});
function makeUi() {
  const ui = new Ui();
  Object.assign(ui, {
    summary: { state: 'running' }, vpnTunnelActive: true, connectedAt: 10,
    eventsReady: Promise.resolve(false), sessionId: '',
    connectionView: { busy: false, setPhase() {} },
    statusMessage: '', profileState: {}, controllerStatus: { available: true },
    isRuntimeConnected() { return this.vpnTunnelActive; },
    stopHomeRefreshLoop() { this.homeRefreshGeneration++; },
    startHomeRefreshLoop() { refreshRestarts++; },
    homeNetwork: {}, homeNetworkMonitor: { disconnect() {} }, refreshHomeNetwork() {},
    syncHomeRuntimeFields() {}, resetHomeTrafficBaseline() {}, clearProxyHealthState() {},
    clearControllerProxyGroups() {}, recordLog() {},
    homeRefreshGeneration: 0, runtimeConnections: []
  });
  return ui;
}
const failedUi = makeUi();
await failedUi.toggleVpn();
assert.equal(failedUi.toggling, false, 'failed stop releases the loading button');
assert.equal(failedUi.vpnTunnelActive, true, 'failed stop preserves last known connection instead of falsely reporting success');
assert.match(failedUi.statusMessage, /超时或失败/);
assert.equal(refreshRestarts, 1, 'polling resumes after failed stop');

stopResult = true;
const stoppedUi = makeUi();
await stoppedUi.toggleVpn();
assert.equal(stoppedUi.toggling, false);
assert.equal(stoppedUi.vpnTunnelActive, false);
assert.equal(stoppedUi.vpnActionText, '连接');
assert.equal(stoppedUi.statusMessage, 'VPN 已停止');

// Execute an actual pending production refresh and invalidate it by disconnecting.
const stale = makeUi();
let completeConnections;
const controller = { getConnections: () => new Promise(resolve => { completeConnections = resolve; }),
  getConfig: async () => ({ ok: true, raw: '{}' }) };
const { Ui: PollUi } = evaluate(source, 'PollUi.ts', {
  MihomoControllerService: controller, LOG_DOMAIN: 1, LOG_TAG: 'Test',
  hilog: { info() {}, error() {} }, TrafficPollerService: { stop() {} }, VpnService: { stop: async () => true },
  CoreBridgeService: uiCore, CoreService: { createSummary: () => ({ state: 'stopped' }) }
});
const poll = Object.assign(new PollUi(), stale);
const pendingRefresh = poll.refreshConnections();
poll.homeRefreshGeneration++;
poll.vpnTunnelActive = false;
completeConnections({ ok: true, raw: '{}' });
await pendingRefresh;
assert.equal(poll.vpnTunnelActive, false);
assert.equal(poll.runtimeConnections.length, 0, 'an old connections response cannot repopulate data after disconnecting');
console.log('vpn-disconnect: bounded stop, immediate route release, cleanup deduplication, startup/destruction race, UI failures and stale polls passed');
