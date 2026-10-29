import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { setTimeout as delay } from 'node:timers/promises';

// Run the production ArkTS bridge with only its native library replaced.
const require = createRequire(import.meta.url);
const ts = require(process.env.ARKTS_TYPESCRIPT_PATH ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const filename = path.resolve('entry/src/main/ets/services/CoreBridgeService.ets');
const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, fileName: filename
}).outputText;
let live = { running: false, controllerOnly: false, coreMode: 'idle', lastError: '', configPath: '' };
let start;
let stop;
const native = {
  startCore: (...args) => start(...args), startTun: (...args) => start(...args),
  stopCore: () => stop(), stopTun: () => stop(), getState: () => live,
  setControllerReady: (ready, version) => ({ ...live, controllerReady: ready, controllerVersion: version })
};
const module = { exports: {} };
vm.runInNewContext(source, {
  module, exports: module.exports, require: (name) => {
    assert.equal(name, 'libentry.so');
    return { default: native };
  }, setTimeout, clearTimeout, Error
}, { filename });
const { CoreBridgeService: bridge } = module.exports;

let complete;
start = () => new Promise(resolve => { complete = resolve; });
const pending = bridge.startCore('fixture.yaml', 500);
let resolved = false;
pending.then(() => { resolved = true; });
await delay(10);
assert.equal(resolved, false, 'bridge must wait for native Promise before publishing startup state');
live = { ...live, running: true, controllerOnly: true, configPath: 'fixture.yaml', lastError: '', adapterVersion: 'test' };
complete(live);
assert.equal((await pending).running, true);
assert.equal(bridge.markControllerReady(true, 'test').controllerVersion, 'test');

start = async () => { throw new Error('native busy'); };
assert.equal((await bridge.startCore('fixture.yaml')).lastError, 'native busy');
start = () => { throw new Error('native setup failed'); };
assert.equal((await bridge.startCore('fixture.yaml')).lastError, 'native setup failed');

// A slow native task must release the UI action via timeout, without pretending
// that the native task was canceled. Its later settlement must remain handled.
start = () => new Promise(resolve => { complete = resolve; });
const timedOut = await bridge.startCore('slow.yaml', 20);
assert.equal(timedOut.running, false);
assert.match(timedOut.lastError, /启动超时.*后台任务仍在运行/);
complete(live);
await delay(5);
assert.equal(bridge.getState().running, true, 'state polling can recover after late native success');

let rejectLate;
start = () => new Promise((resolve, reject) => { rejectLate = reject; });
assert.match((await bridge.startCore('slow.yaml', 20)).lastError, /启动超时/);
rejectLate(new Error('late native failure'));
await delay(5); // Node fails the test on an unhandled rejection.

stop = async () => { await delay(10); return { ...live, running: false, lastError: '' }; };
assert.equal((await bridge.stopCore()).running, false);
stop = async () => { throw new Error('stop busy'); };
assert.equal((await bridge.stopCore()).lastError, 'stop busy');
stop = () => new Promise(() => {});
assert.match((await bridge.stopCore(20)).lastError, /停止超时.*后台任务仍在运行/);
assert.match((await bridge.stopTun(20)).lastError, /停止超时.*后台任务仍在运行/);
stop = async () => ({ ...live, running: false, tunFd: -1, lastError: '' });
assert.equal((await bridge.stopTun()).tunFd, -1);
start = async (configPath, tunFd) => ({ ...live, configPath, tunFd, running: true });
assert.equal((await bridge.startTun('tun.yaml', 17)).tunFd, 17);
start = () => new Promise(() => {});
assert.match((await bridge.startTun('tun.yaml', 17, 20)).lastError, /启动超时/);
console.log('core-bridge-async: awaited state, errors, startup/shutdown timeouts and late completion passed');
