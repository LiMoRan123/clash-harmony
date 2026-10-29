import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { setTimeout as delay } from 'node:timers/promises';
const require = createRequire(import.meta.url);
const ts = require(process.env.ARKTS_TYPESCRIPT_PATH ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const read = name => fs.readFileSync('entry/src/main/ets/' + name + '.ets', 'utf8');
function evaluate(source, globals = {}) {
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText, { module, exports: module.exports, console, Observed: value => value,
    require: name => { throw new Error('Unexpected dependency: ' + name); }, ...globals });
  return module.exports;
}
const { ProfileUpdateViewState: Update } = evaluate(read('models/ProfileUpdateViewState'));
const { CoreService } = evaluate(read('services/CoreService'));
const index = read('pages/Index');
const method = name => {
  const match = index.match(new RegExp('  private (?:async )?' + name + '\\([^]*?\\n  \\}'));
  assert.ok(match, name); return match[0];
};
let updateRequest;
let contextRequest = () => ({});
let prepare = async () => ({ ok: true, configPath: '/runtime.yaml', profileName: 'Current', size: '1 KB' });
let runtimeCalls = 0;
let storeMutations = 0;
let mutationRequest = async () => undefined;
let pendingProxySync;
const toasts = [];
const calls = [];
const { Ui } = evaluate('export class Ui {\n' + ['runProfileUpdates', 'updateProfile', 'updateAllProfiles',
  'applyProfileState', 'activateProfile', 'removeProfile', 'syncProxyView', 'requestToggleVpn'].map(method).join('\n') + '\n}', {
  getContext: () => contextRequest(), CoreService,
  SubscriptionService: { updateProfile: (context, uid) => { calls.push(uid); return updateRequest(uid); } },
  RuntimeConfigService: { prepareCurrentProfile: async () => { runtimeCalls++; return prepare(); } },
  ProfileStore: { activate: async () => { storeMutations++; return mutationRequest(); },
    remove: async () => { storeMutations++; return mutationRequest(); } },
  promptAction: { showToast: options => toasts.push(options.message) }
});
const profile = (uid, type = 'remote') => ({ uid, type, name: uid, filePath: '/' + uid + '.yaml',
  source: 'https://example.org/' + uid, updatedAt: 1, nodeCount: 1, traffic: '1 KB' });
const state = { currentUid: 'current', items: [profile('current'), profile('other'), profile('local', 'local')] };
function makeUi(connected = false) {
  return Object.assign(new Ui(), {
    profileUpdate: new Update(), profileMutationBusy: false, profileState: structuredClone(state),
    connected, statusMessage: '', logs: [], previews: 0,
    connectionView: { busy: false }, lastToggleAt: 0,
    toggleVpn() { this.toggleRequests = (this.toggleRequests ?? 0) + 1; },
    summary: { state: connected ? 'running' : 'stopped', mode: 'rule', proxyName: 'Selected node',
      uptime: '1m', downloadSpeed: '1 MB/s', uploadSpeed: '1 KB/s', connections: 2 },
    proxyNodes: [{ name: 'Selected node', selected: true }],
    isRuntimeConnected() { return this.connected; },
    recordLog(level, message) { this.logs.push([level, message]); }, syncHomeRuntimeFields() {},
    refreshProxyNodes: async function() { this.previews++; },
    refreshControllerProxies: () => pendingProxySync,
    notify(message) { this.statusMessage = message; }
  });
}
const result = (uid, ok = true) => ({ ok, message: ok ? '订阅已更新，保存 2 个节点' : '订阅服务器返回 HTTP 503',
  state: { ...state, items: state.items.map(item => item.uid === uid && ok ? { ...item, updatedAt: 2, nodeCount: 2 } : item) } });
let finish;
updateRequest = () => new Promise(resolve => { finish = resolve; });
const ui = makeUi(true);
const nodes = ui.proxyNodes;
const pending = ui.updateProfile('current');
assert.equal(ui.profileUpdate.running, true, 'loading is entered before waiting for the network');
assert.equal(ui.profileUpdate.phaseFor('current'), 'updating');
assert.match(ui.profileUpdate.message, /current/);
ui.requestToggleVpn();
assert.equal(ui.toggleRequests, 1, 'disconnect remains available during a subscription update');
ui.connected = false;
ui.requestToggleVpn();
assert.equal(ui.toggleRequests, 1, 'a new core cannot start while its configuration files are being updated');
assert.match(ui.statusMessage, /配置正在处理/);
ui.connected = true;
await ui.updateProfile('current');
await ui.updateAllProfiles();
await ui.activateProfile('other');
await ui.removeProfile('current');
assert.equal(calls.length, 1, 'repeated taps and batch update cannot start overlapping downloads');
assert.equal(storeMutations, 0, 'activation and deletion cannot race a pending metadata update');
finish(result('current'));
await pending;
assert.equal(ui.profileUpdate.running, false);
assert.equal(ui.profileUpdate.phaseFor('current'), 'success');
assert.equal(ui.profileState.items[0].nodeCount, 2);
assert.equal(ui.proxyNodes, nodes);
assert.equal(ui.summary.proxyName, 'Selected node', 'updating files preserves the running core selection');
assert.equal(ui.previews, 0, 'live proxy groups are not replaced by a local YAML preview');
assert.equal(runtimeCalls, 1);
assert.match(ui.statusMessage, /重新连接后生效/);
assert.equal(toasts.length, 1);

// A batch runs serially and reports real completed counts. A failed item does
// not prevent the next subscription from updating, and local files are skipped.
calls.length = 0;
const batch = makeUi();
const resolvers = new Map();
updateRequest = uid => new Promise(resolve => resolvers.set(uid, resolve));
const batchPending = batch.updateAllProfiles();
assert.deepEqual(calls, ['current']);
assert.equal(batch.profileUpdate.phaseFor('other'), 'queued');
assert.equal(batch.profileUpdate.targetUids.length, 2);
resolvers.get('current')(result('current', false));
await delay(0);
assert.equal(batch.profileUpdate.completed, 1);
assert.equal(batch.profileUpdate.succeeded, 0);
assert.equal(batch.profileUpdate.phaseFor('current'), 'error');
assert.equal(batch.profileUpdate.phaseFor('other'), 'updating');
resolvers.get('other')(result('other'));
await batchPending;
assert.equal(batch.profileUpdate.completed, 2);
assert.equal(batch.profileUpdate.succeeded, 1);
assert.equal(batch.profileUpdate.failed, true);
assert.equal(batch.profileUpdate.running, false);
assert.match(batch.statusMessage, /1\/2/);
assert.equal(batch.previews, 1);
assert.deepEqual(calls, ['current', 'other']);

// Both a thrown download exception and a runtime write failure release the
// spinner, preserve useful results and let the next explicit retry succeed.
updateRequest = async () => { throw new Error('sensitive URL token=fixture'); };
await batch.updateProfile('current');
assert.equal(batch.profileUpdate.running, false);
assert.equal(batch.profileUpdate.phaseFor('current'), 'error');
assert.doesNotMatch(batch.profileUpdate.messageFor('current'), /token=fixture/);
updateRequest = async uid => result(uid);
prepare = async () => { throw new Error('disk unavailable'); };
await batch.updateProfile('current');
assert.equal(batch.profileUpdate.running, false);
assert.equal(batch.profileUpdate.failed, true);
assert.match(batch.statusMessage, /订阅已保存/);
prepare = async () => ({ ok: true, configPath: '/runtime.yaml', profileName: 'Current', size: '1 KB' });
await batch.updateProfile('current');
assert.equal(batch.profileUpdate.failed, false);
assert.equal(batch.profileUpdate.phaseFor('current'), 'success');
assert.match(batch.statusMessage, /订阅已更新/);
contextRequest = () => { throw new Error('context released'); };
await batch.updateProfile('current');
assert.equal(batch.profileUpdate.running, false, 'even context teardown cannot leave the UI loading indefinitely');
contextRequest = () => ({});
const empty = makeUi();
empty.profileState = { currentUid: 'local', items: [profile('local', 'local')] };
await empty.updateAllProfiles();
assert.equal(empty.profileUpdate.running, false);
assert.match(empty.statusMessage, /没有可更新/);
const startingUi = makeUi();
startingUi.toggling = true;
const callsBeforeStart = calls.length;
await startingUi.updateProfile('current');
await startingUi.updateAllProfiles();
assert.equal(calls.length, callsBeforeStart, 'a VPN startup cannot race a newly requested configuration download');
assert.equal(startingUi.profileUpdate.running, false);

let finishMutation;
mutationRequest = () => new Promise(resolve => { finishMutation = resolve; });
const writer = makeUi();
const activating = writer.activateProfile('other');
assert.equal(writer.profileMutationBusy, true);
const beforeMutationCalls = calls.length;
await writer.updateProfile('current');
assert.equal(calls.length, beforeMutationCalls, 'updating cannot overlap a pending profile activation');
finishMutation({ ...state, currentUid: 'other' });
await activating;
assert.equal(writer.profileMutationBusy, false);
assert.equal(writer.profileState.currentUid, 'other');
mutationRequest = async () => { throw new Error('storage unavailable'); };
await writer.removeProfile('current');
assert.equal(writer.profileMutationBusy, false, 'failed metadata writes also release the mutation guard');
assert.match(writer.statusMessage, /删除配置失败/);

// The adjacent manual proxy refresh follows the same tap-feedback contract.
const proxyUi = makeUi();
let resolveProxy;
pendingProxySync = new Promise(resolve => { resolveProxy = resolve; });
const sync = proxyUi.syncProxyView();
assert.equal(proxyUi.syncingProxies, true);
await proxyUi.syncProxyView();
resolveProxy();
await sync;
assert.equal(proxyUi.syncingProxies, false);
pendingProxySync = Promise.reject(new Error('controller unavailable'));
await proxyUi.syncProxyView();
assert.equal(proxyUi.syncingProxies, false);
assert.match(proxyUi.statusMessage, /同步失败/);
console.log('profile-update-feedback: immediate loading, duplicate suppression, real batch progress, failures/retry, live selection and proxy refresh passed');
