import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ts = require(process.env.ARKTS_TYPESCRIPT_PATH ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve('entry/src/main/ets');
const requests = [];
let active = 0;
let maximumActive = 0;
let responder = url => {
  if (url.includes('ipify')) return { responseCode: 200, result: '{"ip":"203.0.113.42"}' };
  if (url.includes('github')) return { responseCode: 403, result: '' };
  if (url.includes('youtube')) return { responseCode: 503, result: '' };
  if (url.includes('chatgpt')) throw new Error('fixture timeout');
  return { responseCode: 204, result: '' };
};
const http = {
  RequestMethod: { GET: 'GET', HEAD: 'HEAD' }, HttpDataType: { STRING: 'STRING' },
  createHttp() {
    const item = { destroyed: 0 };
    return {
      async request(url, options) {
        Object.assign(item, { url, options });
        requests.push(item);
        active++;
        maximumActive = Math.max(maximumActive, active);
        try { return await responder(url, options); } finally { active--; }
      },
      destroy() { item.destroyed++; }
    };
  }
};
const modules = new Map();
function evaluate(source, filename, globals = {}) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, fileName: filename
  }).outputText;
  vm.runInNewContext(code, { module, exports: module.exports, Observed: value => value, Date, console,
    require: name => name === '@kit.NetworkKit' ? { http } : load(path.resolve(path.dirname(filename), name + '.ets')),
    ...globals
  }, { filename });
  return module.exports;
}
function load(filename) {
  if (!modules.has(filename)) modules.set(filename, evaluate(fs.readFileSync(filename, 'utf8'), filename));
  return modules.get(filename);
}
const { HomeNetworkViewState: State } = load(path.join(root, 'models/HomeNetworkViewState.ets'));
const { HomeNetworkMonitorService: Monitor } = load(path.join(root, 'services/HomeNetworkMonitorService.ets'));
const { TrafficViewState: Traffic } = load(path.join(root, 'models/HomeViewState.ets'));
const flush = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};

const state = new State();
const monitor = new Monitor();
monitor.connect(state);
assert.equal(state.checkingExit, true, 'connection immediately starts the exit lookup');
assert.equal(requests.length, 3, 'exit lookup and two service workers start without waiting on each other');
await flush();
assert.equal(state.exitIp, '203.0.113.42');
assert.equal(state.checkingExit, false);
assert.equal(state.checkingServices, false);
assert.equal(state.services.find(item => item.key === 'google').status, 'available');
assert.equal(state.services.find(item => item.key === 'github').status, 'restricted', '403 is not reported as successful access');
assert.equal(state.services.find(item => item.key === 'youtube').status, 'restricted', 'HTTP failures are distinguished from connection failures');
assert.equal(state.services.find(item => item.key === 'chatgpt').status, 'unreachable');
assert.equal(state.summary(), '1 / 4 可达');
assert.equal(maximumActive, 3, 'only two service probes run concurrently alongside the exit lookup');
assert.equal(requests.length, 5);
for (const request of requests) {
  assert.equal(request.options.usingProxy.host, '127.0.0.1');
  assert.equal(request.options.usingProxy.port, 7890);
  assert.equal(request.options.usingCache, false);
  assert.equal(request.destroyed, 1, 'every completed HTTP handle is released exactly once');
  if (!request.url.includes('ipify')) assert.equal(request.options.method, 'HEAD');
}
monitor.connect(state);
await flush();
assert.equal(requests.length, 5, 'repeated connection sync does not create polling or duplicate batches');
await Promise.all([monitor.refresh(state), monitor.refresh(state)]);
assert.equal(requests.length, 10, 'manual refresh deduplicates overlapping requests');

monitor.disconnect(state);
assert.equal(state.exitIp, '');
assert.equal(state.checkedAt, 0);
assert.ok(state.services.every(item => item.status === 'idle'));

// Model an SDK completing callbacks after destroy(), across a fast reconnect.
const oldRequests = [];
responder = url => {
  const wait = deferred();
  oldRequests.push({ url, ...wait });
  return wait.promise;
};
monitor.connect(state);
const oldHandles = requests.slice(-3);
monitor.disconnect(state);
assert.ok(oldHandles.every(item => item.destroyed === 1), 'disconnect cancels all active handles');
const newExit = deferred();
responder = url => url.includes('ipify') ? newExit.promise : { responseCode: 204, result: '' };
monitor.connect(state);
for (const request of oldRequests) {
  request.resolve({ responseCode: 200, result: '{"ip":"203.0.113.99"}' });
}
await flush();
assert.equal(state.exitIp, '', 'old route results cannot leak into the new session');
assert.equal(state.checkingExit, true, 'old finally callbacks cannot clear the new loading state');
assert.equal(oldRequests.length, 3, 'canceled service workers do not start their next target');
newExit.resolve({ responseCode: 200, result: '{"ip":"203.0.113.77"}' });
await flush();
assert.equal(state.exitIp, '203.0.113.77');
assert.equal(state.summary(), '全部可达');

responder = url => ({ responseCode: 200, result: url.includes('ipify') ? '<html>login</html>' : '' });
await monitor.refresh(state);
assert.equal(state.exitIp, '', 'a failed new lookup does not present stale IP data as current');
assert.match(state.exitMessage, /检测失败/);
assert.equal(state.checkingExit, false);
assert.equal(state.checkingServices, false);
assert.equal(state.summary(), '全部可达', 'exit lookup failure does not erase independent service results');

const traffic = new Traffic();
traffic.recordTotals(1000, 2000, 800, 900);
traffic.recordTotals(2000, 4000, 200, 400);
assert.equal(traffic.downloadTotal, 2000);
assert.equal(traffic.uploadTotal, 4000);
assert.equal(traffic.downloadPeak, 800);
assert.equal(traffic.uploadPeak, 900);
traffic.recordTotals(10, 20, 0, 0);
assert.equal(traffic.downloadPeak, 0, 'core counter reset clears previous peaks');
traffic.downloadHistory = [1, 2, 3];
traffic.reset();
assert.equal(traffic.downloadTotal, 0);
assert.equal(traffic.uploadPeak, 0);
assert.ok(traffic.downloadHistory.every(value => value === 0));

const index = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
const method = name => {
  const match = index.match(new RegExp('  private (?:async )?' + name + '\\([^]*?\\n  \\}'));
  assert.ok(match, name);
  return match[0];
};
const { Ui } = evaluate('export class Ui {\n' + ['refreshAfterConnection', 'refreshHomeNetwork', 'isRuntimeConnected']
  .map(method).join('\n') + '\n}', 'Ui.ts');
const ui = new Ui();
const restoring = deferred();
let starts = 0;
let nodeVerificationStarted = false;
Object.assign(ui, {
  vpnTunnelActive: true, homeRefreshGeneration: 1, homeNetwork: {},
  homeNetworkMonitor: { connect() { starts++; }, disconnect() {} },
  refreshControllerProxies: async () => {}, restoreProxySelection: () => restoring.promise,
  verifySelectedProxyAfterConnection() { nodeVerificationStarted = true; return new Promise(() => {}); }, recordLog() {}
});
ui.refreshAfterConnection('Proxy', 'Node', 'fixture', 1);
await flush();
assert.equal(starts, 0, 'automatic probing waits until the saved node selection is restored');
restoring.resolve();
await flush();
assert.equal(starts, 1);
assert.equal(nodeVerificationStarted, true, 'exit lookup does not wait for the slow optional node check');
console.log('Home dashboard: automatic probes, bounded concurrency, cancellation, session races and traffic counters passed');
