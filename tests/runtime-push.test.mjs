import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { setTimeout as delay } from 'node:timers/promises';
const require = createRequire(import.meta.url);
const ts = require(process.env.ARKTS_TYPESCRIPT_PATH ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
let subscriptionInfo;
let eventHandler;
let published;
let unsubscribed = 0;
let createSubscriber = async info => { subscriptionInfo = info; return { id: 1 }; };
const eventManager = {
  createSubscriber: info => createSubscriber(info),
  subscribe: (subscriber, callback) => { eventHandler = callback; },
  unsubscribe: () => { unsubscribed++; },
  publish: (name, options, callback) => { published = { name, options }; callback(); }
};
const sockets = [];
let failConnect = false;
class Socket {
  handlers = {};
  closed = 0;
  on(type, callback) { this.handlers[type] = callback; }
  connect(url) { this.url = url; return failConnect ? Promise.reject(new Error('fixture closed')) : Promise.resolve(true); }
  close() { this.closed++; this.handlers.close?.(undefined, {}); return Promise.resolve(true); }
  emit(type, value) { this.handlers[type]?.(undefined, value); }
}
const kits = {
  '@kit.BasicServicesKit': { commonEventManager: eventManager },
  '@kit.NetworkKit': { webSocket: { createWebSocket: () => { const socket = new Socket(); sockets.push(socket); return socket; } } }
};
function evaluate(source, filename, globals = {}, shortTimers = false) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, fileName: filename
  }).outputText;
  vm.runInNewContext(code, { module, exports: module.exports, Error, Observed: value => value,
    require: name => { assert.ok(kits[name], name); return kits[name]; },
    setTimeout: (fn, ms) => setTimeout(fn, shortTimers ? Math.min(ms, 10) : ms), clearTimeout, ...globals
  }, { filename });
  return module.exports;
}
const source = name => fs.readFileSync(path.resolve('entry/src/main/ets/' + name + '.ets'), 'utf8');
const { VpnRuntimeEvents: Events } = evaluate(source('services/VpnRuntimeEvents'), 'VpnRuntimeEvents.ets');
const received = [];
assert.equal(await Events.subscribe(event => received.push(event)), true);
assert.equal(subscriptionInfo.publisherBundleName, 'io.github.clashharmony.app');
const packet = (phase, sequence = 1, sessionId = 'run-A') =>
  ({ sessionId, sequence, phase, elapsedMs: 123, version: phase === 'connected' ? 'test' : '' });
Events.publish(packet('starting'));
assert.equal(published.options.bundleName, 'io.github.clashharmony.app');
assert.equal(published.name, 'io.github.clashharmony.app.VPN_RUNTIME');
eventHandler(undefined, { data: JSON.stringify(packet('starting')) });
assert.equal(received.length, 1);
const ready = Events.waitFor('run-A', ['connected', 'error'], 100);
eventHandler(undefined, { data: JSON.stringify(packet('connected', 2)) });
assert.equal((await ready).phase, 'connected');
assert.equal((await Events.waitFor('run-A', ['connected'], 20)).version, 'test', 'fast ready events are cached');
eventHandler(undefined, { data: JSON.stringify(packet('starting', 1)) });
eventHandler(undefined, { data: '{"phase":"connected"}' });
eventHandler(undefined, { data: 'not json' });
assert.equal(received.length, 2, 'malformed and out-of-order packets are ignored');
assert.equal(await Events.waitFor('not-active', ['connected'], 10), undefined);
const pending = Events.waitFor('other', ['disconnected'], 1000);
const oldHandler = eventHandler;
Events.unsubscribe();
assert.equal(await pending, undefined);
oldHandler(undefined, { data: JSON.stringify(packet('error', 3)) });
assert.equal(received.length, 2, 'late callbacks after unsubscribe are ignored');

let finishSubscribe;
createSubscriber = info => new Promise(resolve => { finishSubscribe = resolve; });
const subscribing = Events.subscribe(() => {});
Events.unsubscribe();
finishSubscribe({ id: 2 });
assert.equal(await subscribing, false);
assert.ok(unsubscribed >= 2, 'a late subscription is released after page teardown');

const { ControllerStreamService: Stream } = evaluate(source('services/ControllerStreamService'), 'ControllerStreamService.ets', {}, true);
const stream = new Stream();
const frames = [];
let unavailable = 0;
stream.start(frame => frames.push(frame), () => { unavailable++; });
assert.equal(sockets[0].url, 'ws://127.0.0.1:9090/connections?interval=1000');
sockets[0].emit('message', '{"connections":[]}');
assert.equal(frames.length, 1);
sockets[0].emit('close', {});
await delay(20);
assert.equal(sockets.length, 2);
sockets[0].emit('message', 'stale');
assert.equal(frames.length, 1, 'frames from an old connection are ignored');
stream.stop();
sockets[1].emit('message', 'after stop');
await delay(20);
assert.equal(frames.length, 1);
assert.equal(sockets.length, 2, 'stop cancels reconnect scheduling');
failConnect = true;
const failing = new Stream();
failing.start(() => {}, () => { unavailable++; });
await delay(80);
assert.equal(unavailable, 1, 'consecutive failures are bounded rather than reconnecting forever');
failing.stop();

const { ConnectionViewState: Connection, TrafficViewState: Traffic } =
  evaluate(source('models/HomeViewState'), 'HomeViewState.ets');
const connection = new Connection();
const traffic = new Traffic();
connection.setPhase('starting', '正在启动内核');
traffic.downloadSpeed = '1 MB/s';
assert.equal(connection.busy, true);
assert.equal(connection.message, '正在启动内核');
connection.setPhase('connected', '已连接');
assert.equal(connection.busy, false);

const index = source('pages/Index');
function method(name) {
  const result = index.match(new RegExp('  private (?:async )?' + name + '\\([^]*?\\n  \\}'));
  assert.ok(result, name);
  return result[0];
}
let waitPhase = 'connected';
let fallbackChecks = 0;
const { Ui } = evaluate('export class Ui {\n' + ['toggleVpn', 'connectionPhase', 'recordStartupStage',
  'syncHomeRuntimeFields', 'isRuntimeConnected', 'onRuntimeEvent', 'applyConnectionsSnapshot',
  'formatSpeedValue'].map(method).join('\n') + '\n}', 'Ui.ts', {
  LOG_DOMAIN: 1, LOG_TAG: 'test', hilog: { info() {}, error() {} },
  getContext: () => ({}),
  TrafficPollerService: { stop() {} },
  CoreBridgeService: { getState: () => ({ running: false, coreMode: 'idle' }),
    markControllerReady: () => ({ running: true, coreMode: 'mihomo-adapter' }) },
  VpnService: { start: async () => true, stop: async () => true, stopAndConfirm: async () => true,
    hasSystemVpn: async () => true },
  MihomoControllerService: { waitForVersion: async () => {
    fallbackChecks++; return { available: true, version: 'fallback-core' };
  } },
  VpnBackgroundService: { setEnabled: async () => {}, updateTraffic() {} },
  VpnRuntimeEvents: { waitFor: async () => waitPhase ? packet(waitPhase, 2, 'fixture') : undefined },
  CoreService: { createSummary: () => ({ state: 'running', uptime: '00:00:01', downloadSpeed: '0 B/s', uploadSpeed: '0 B/s', connections: 0 }) }
});
// The production stop helper now owns the whole confirmation budget.
// UI tests mock that helper; its real timing and fallback are tested separately.
const ui = new Ui();
let postChecks = 0;
Object.assign(ui, {
  connectionView: new Connection(), trafficView: new Traffic(),
  profileState: { currentUid: 'p' }, summary: { state: 'stopped' },
  eventsReady: Promise.resolve(true), proxyMode: 'rule',
  selectedProxyGroup: '', pendingProxyGroup: '', pendingProxyName: '',
  vpnTunnelActive: false, homeRefreshGeneration: 0,
  recordLog() {}, getSelectedProxyNodeName() { return ''; },
  prepareRuntimeForConnection: async () => ({ ok: true, configPath: '/fixture.yaml', profileName: 'Test', size: '1 KB' }),
  currentProfileDisplayName() { return 'Test'; }, currentProxyLabel() { return 'Proxy'; },
  formatRuntimeUptime() { return '00:00:01'; },
  runtimeConfigDisplayState() { return '已准备'; }, startRuntimePolling() {},
  waitForVpnTunReady: async () => ({ ready: true }),
  stopHomeRefreshLoop() { this.homeRefreshGeneration++; },
  resetHomeTrafficBaseline() {}, clearProxyHealthState() {}, clearControllerProxyGroups() {},
  refreshAfterConnection() { postChecks++; return new Promise(() => {}); }
});
await ui.toggleVpn();
assert.equal(ui.vpnTunnelActive, true);
assert.equal(ui.toggling, false, 'VPN readiness releases the control without waiting for slow node checks');
assert.equal(ui.connectionView.phase, 'connected');
assert.equal(ui.connectionView.busy, false);
assert.equal(postChecks, 1);
const proxyList = [{ name: 'Test-node' }];
ui.proxyNodes = proxyList;
ui.currentTab = 'home';
ui.applyConnectionsSnapshot(JSON.stringify({ downloadTotal: 100, uploadTotal: 100, connections: [{}] }));
assert.equal(ui.trafficView.connections, 1);
ui.homeLastPollAt = Date.now() - 1000;
ui.applyConnectionsSnapshot(JSON.stringify({ downloadTotal: 1124, uploadTotal: 612, connections: [{}, {}] }));
assert.equal(ui.trafficView.connections, 2);
assert.ok(ui.trafficView.downloadHistory.at(-1) > 0);
assert.equal(ui.proxyNodes, proxyList, 'traffic frames do not replace the proxy list or refresh routing data');
assert.equal(ui.connectionView.phase, 'connected');
ui.applyConnectionsSnapshot('malformed');
assert.equal(ui.trafficView.connections, 2);
ui.toggling = true;
ui.connectionPhase('stopping', '正在断开 VPN');
assert.equal(ui.connectionView.phase, 'stopping', 'the card changes before an async stop completes');
assert.equal(ui.connectionView.busy, true);
const phaseBefore = ui.connectionView.phase;
ui.onRuntimeEvent(packet('connected', 99, 'previous-session'));
assert.equal(ui.connectionView.phase, phaseBefore, 'a previous session cannot change the active transition');
ui.toggling = false;
ui.vpnTunnelActive = false;
ui.connectionPhase('error', '启动请求未确认');
ui.onRuntimeEvent(packet('connected', 3, ui.sessionId));
assert.equal(ui.vpnTunnelActive, true, 'a late confirmed-ready event reconciles an earlier SDK timeout');
assert.equal(ui.connectionView.phase, 'connected');
ui.eventsReady = Promise.resolve(false);
await ui.toggleVpn();
assert.equal(ui.vpnTunnelActive, false);
assert.equal(ui.connectionView.phase, 'idle', 'successful compatibility stop ends in idle rather than an error/loading state');
assert.equal(ui.connectionView.busy, false);
ui.eventsReady = Promise.resolve(true);
await ui.toggleVpn();
waitPhase = 'disconnected';
await ui.toggleVpn();
assert.equal(ui.connectionView.phase, 'idle', 'pushed stop confirmation ends the transition');
assert.equal(ui.toggling, false);
waitPhase = undefined;
await ui.toggleVpn();
assert.equal(ui.vpnTunnelActive, true, 'a delayed background common event cannot tear down a controller- and system-confirmed VPN');
assert.equal(fallbackChecks, 1);
await ui.toggleVpn();
waitPhase = 'error';
await ui.toggleVpn();
assert.equal(ui.vpnTunnelActive, false);
assert.equal(fallbackChecks, 1, 'an explicit startup failure must not be ignored by the compatibility probe');
const startLoop = method('startHomeRefreshLoop');
assert.doesNotMatch(startLoop, /setInterval|requestText|getConnections|getConfig/);
assert.match(startLoop, /runtimeStream.start/);
assert.doesNotMatch(index, /liveRefreshToken|homeRefreshIntervalId|setInterval/);
console.log('runtime-push: private lifecycle events, readiness cache, stale callbacks, bounded streams, isolated state and nonblocking post-connect checks passed');
