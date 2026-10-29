import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ts = require(process.env.ARKTS_TYPESCRIPT_PATH ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const files = new Map();
const stores = new Map();
const handles = new Map();
let nextFd = 0;
let closed = 0;
let savedUris = ['/chosen/export.yaml'];
let failWrite = false;
const context = { filesDir: '/device/app' };
const io = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_WRITE: 8 },
  mkdir: async () => {}, access: async file => files.has(file),
  readText: async file => {
    if (!files.has(file)) throw new Error('missing file');
    return files.get(file);
  },
  openSync: file => { const fd = ++nextFd; handles.set(fd, file); return { fd }; },
  write: async (fd, content) => {
    if (failWrite) throw new Error('disk full');
    files.set(handles.get(fd), content);
  },
  closeSync: () => { closed++; }
};
const kits = {
  '@kit.AbilityKit': {},
  '@kit.ArkData': { preferences: { getPreferences: async (ctx, options) => {
    const name = typeof options === 'string' ? options : options.name;
    if (!stores.has(name)) stores.set(name, new Map());
    const values = stores.get(name);
    return { get: async (key, fallback) => values.get(key) ?? fallback,
      put: async (key, value) => values.set(key, value), flush: async () => {} };
  } } },
  '@kit.CoreFileKit': { fileIo: io, picker: { DocumentViewPicker: class {
    async save() { return savedUris; }
  } } },
  '@kit.ArkTS': { util: {} }
};
const modules = new Map();
function evaluate(source, filename, globals = {}) {
  const module = { exports: {} };
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, fileName: filename
  }).outputText;
  vm.runInNewContext(compiled, { module, exports: module.exports,
    require: name => kits[name] ?? load(path.resolve(path.dirname(filename), name + '.ets')),
    console, Date, Error, ...globals
  }, { filename });
  return module.exports;
}
function load(filename) {
  if (!modules.has(filename)) modules.set(filename, evaluate(fs.readFileSync(filename, 'utf8'), filename));
  return modules.get(filename);
}
const service = name => load(path.resolve('entry/src/main/ets/services/' + name + '.ets'))[name];
const Preferences = service('AppPreferencesService');
const Backup = service('AppBackupService');
const Store = service('ProfileStore');
const Runtime = service('RuntimeConfigService');
const Export = service('DocumentExportService');
const defaults = await Preferences.load(context);
assert.equal(defaults.appearance, 'system');
assert.equal(defaults.ipv6, false);
assert.equal(defaults.dnsMode, 'redir-host');

await Preferences.save(context, { ...defaults, appearance: 'dark', ipv6: true, allowLan: true,
  dnsMode: 'fake-ip', logLevel: 'debug', proxySort: 'delay', proxyColumns: 2, testTimeout: 8000 });
const settings = await Preferences.load(context);
assert.equal(settings.appearance, 'dark');
assert.equal(settings.testTimeout, 8000);
assert.equal(settings.proxyColumns, 2);
const cleaned = Preferences.normalize({ ...settings, appearance: 'bad', testTimeout: -4,
  testUrl: 'javascript:bad', logLevel: 'bad', proxyColumns: 99 });
assert.equal(cleaned.appearance, 'system');
assert.equal(cleaned.testTimeout, 4500);
assert.equal(cleaned.proxyColumns, 1);
assert.equal(cleaned.logLevel, 'info');
assert.ok(cleaned.testUrl.startsWith('https://'));

const yaml = 'proxies:\n  - name: Test\n    type: ss\n    server: example.org\n    port: 443\n    cipher: aes-128-gcm\n    password: fixture\nproxy-groups:\n  - name: Proxy\n    type: select\n    proxies: [Test]\nrules:\n  - MATCH,Proxy\n';
const profile = { uid: 'original', type: 'remote', name: '我的配置', source: 'https://example.org/sub?token=fixture',
  filePath: '/device/app/profiles/original.yaml', updatedAt: 1, nodeCount: 1, traffic: '1 MB',
  subscriptionInfo: { upload: 1024, download: 2048, total: 10240, expire: 1894665600 }, subscriptionInfoCheckedAt: 12345 };
files.set(profile.filePath, yaml);
await Store.save(context, { currentUid: profile.uid, items: [profile] });
const runtime = await Runtime.prepareCurrentProfile(context);
assert.equal(runtime.ok, true);
const runtimeText = files.get(runtime.configPath);
assert.ok(runtimeText.includes('allow-lan: true'));
assert.ok(runtimeText.includes('ipv6: true'));
assert.ok(runtimeText.includes('enhanced-mode: fake-ip'));
assert.ok(runtimeText.includes('log-level: debug'));
assert.ok(runtimeText.includes('external-controller: 127.0.0.1:9090'));
const globalRuntime = await Runtime.prepareCurrentProfile(context, undefined, 'global');
assert.ok(files.get(globalRuntime.configPath).includes('mode: global'), 'desired mode is generated before native startup');

const backup = await Backup.create(context);
const portable = JSON.parse(backup);
assert.equal(portable.profiles[0].text, yaml, 'backup includes file contents rather than sandbox paths alone');
assert.equal(portable.profiles[0].source, profile.source);
assert.equal(portable.preferences.appearance, 'dark');
assert.equal(portable.profiles[0].subscriptionInfo.total, 10240);
const restored = await Backup.restore(context, backup);
assert.notEqual(restored.currentUid, profile.uid);
assert.equal(files.get(restored.items[0].filePath), yaml);
assert.equal(restored.items[0].source, profile.source);
assert.equal((await Preferences.load(context)).proxyColumns, 2);
assert.equal(restored.items[0].subscriptionInfo.download, 2048);
assert.equal(restored.items[0].subscriptionInfoCheckedAt, 12345);
const legacyBackup = JSON.parse(backup);
delete legacyBackup.profiles[0].subscriptionInfo;
delete legacyBackup.profiles[0].subscriptionInfoCheckedAt;
const legacyRestored = await Backup.restore(context, JSON.stringify(legacyBackup));
assert.equal(legacyRestored.items[0].subscriptionInfo, undefined, 'backups predating subscription metadata remain restorable');
const before = JSON.stringify(await Store.load(context));
await assert.rejects(Backup.restore(context, '{"version":1,"profiles":[]}'), /受支持/);
await assert.rejects(Backup.restore(context, 'null'), /受支持/);
const malformed = { ...portable, profiles: [{ ...portable.profiles[0], text: '<html>Login</html>' }] };
await assert.rejects(Backup.restore(context, JSON.stringify(malformed)), /无法识别/);
assert.equal(JSON.stringify(await Store.load(context)), before, 'invalid backups preserve the existing configuration');
failWrite = true;
await assert.rejects(Backup.restore(context, backup), /disk full/);
assert.equal(JSON.stringify(await Store.load(context)), before, 'file write failure does not replace profile metadata');
failWrite = false;
const exported = await Export.save(context, '配置.yaml', yaml);
assert.equal(exported, true);
assert.equal(files.get('/chosen/export.yaml'), yaml);
savedUris = [];
assert.equal(await Export.save(context, '配置.yaml', yaml), false);
savedUris = ['/chosen/export.yaml'];
const previousClosed = closed;
failWrite = true;
await assert.rejects(Export.save(context, '配置.yaml', yaml), /disk full/);
assert.equal(closed, previousClosed + 1, 'export releases the file handle when writing fails');
failWrite = false;


let response = { responseCode: 200, result: '{"ip":"203.0.113.42"}' };
let destroyed = 0;
let requestOptions;
kits['@kit.NetworkKit'] = { http: {
  RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'STRING' },
  createHttp: () => ({ request: async (url, options) => { requestOptions = options; return response; },
    destroy: () => { destroyed++; } })
} };
const Probe = service('NetworkProbeService');
assert.equal(await Probe.exitIp(), '203.0.113.42');
assert.equal(requestOptions.usingProxy.host, '127.0.0.1');
assert.equal(requestOptions.usingProxy.port, 7890, 'exit check goes through the app proxy rather than relying on the system route');
response = { responseCode: 200, result: '{"ip":"<html>login</html>"}' };
await assert.rejects(Probe.exitIp(), /无法识别/);
response = { responseCode: 503, result: 'unavailable' };
await assert.rejects(Probe.exitIp(), /检测失败/);
assert.equal(destroyed, 3);

const index = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const methods = ['getVisibleProxyNodes', 'parseDelayText', 'isRejectPolicy', 'getAllProxyNodeIndexes',
  'measureProxyNodeDelay', 'parseControllerDelay'].map(name => {
  const match = index.match(new RegExp('  private (?:async )?' + name + '\\([^]*?\\n  \\}'));
  assert.ok(match, 'production UI method exists: ' + name);
  return match[0];
}).join('\n');
const calls = [];
const { UiModel } = evaluate('export class UiModel {\n' + methods + '\n}', 'UiModel.ts', {
  DELAY_TEST_URLS: ['https://fallback1', 'https://fallback2', 'http://fallback3'],
  MihomoControllerService: { testDelay: async (...args) => {
    calls.push(args);
    return { ok: true, raw: '{"delay":42}' };
  } }
});
const ui = new UiModel();
ui.appPreferences = { ...settings, testUrl: 'https://chosen-test', testTimeout: 8000 };
ui.proxyNodes = [{ name: 'B', meta: 'Japan', delay: '120 ms' }, { name: 'A', meta: 'Hong Kong', delay: '30 ms' },
  { name: 'REJECT', meta: 'Reject', delay: '待测' }];
ui.proxySearchText = '';
assert.equal(ui.getVisibleProxyNodes()[0].name, 'A');
assert.equal(ui.proxyNodes[0].name, 'B', 'sorting never mutates the controller ordering');
ui.proxySearchText = 'japan';
assert.equal(ui.getVisibleProxyNodes().length, 1);
assert.equal(ui.getVisibleProxyNodes()[0].name, 'B');
assert.equal(JSON.stringify(ui.getAllProxyNodeIndexes()), '[0,1]', 'reject policies are not included in speed tests');
ui.controllerStatus = { available: true };
ui.coreBridgeState = { controllerReady: true };
assert.equal(await ui.measureProxyNodeDelay(ui.proxyNodes[0]), 42);
assert.deepEqual(calls[0], ['B', 8000, 'https://chosen-test']);
const beforeReject = calls.length;
assert.equal(await ui.measureProxyNodeDelay(ui.proxyNodes[2]), -1);
assert.equal(calls.length, beforeReject, 'reject policy never makes a delay HTTP request');
console.log('ui-workflows: preferences, runtime overrides, portable backup/restore, export, sorting and delay options passed');
