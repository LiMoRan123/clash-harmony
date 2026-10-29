import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

// Execute the production ArkTS services; only HarmonyOS platform I/O is adapted.
const require = createRequire(import.meta.url);
const ts = require(process.env.ARKTS_TYPESCRIPT_PATH ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const yamlCodec = require(path.join(path.dirname(require.resolve(process.env.ARKTS_TYPESCRIPT_PATH ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript')), '../../js-yaml'));
const root = process.cwd();
const context = { filesDir: '/virtual/clash-harmony' };
const values = new Map();
const files = new Map();
const descriptors = new Map();
const requests = [];
let nextFd = 1;
let destroyed = 0;
let clipboard = '';
let respond;

const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
  mkdir: async () => {},
  access: async (file) => files.has(file),
  readText: async (file) => {
    if (!files.has(file)) throw new Error('Fixture file not found');
    return files.get(file);
  },
  openSync: (file) => {
    const fd = nextFd++;
    descriptors.set(fd, file);
    return { fd };
  },
  write: async (fd, text) => files.set(descriptors.get(fd), text),
  closeSync: () => {}
};

const kits = {
  '@kit.AbilityKit': {},
  '@kit.ArkTS': {
    util: {
      Type: { BASIC: 'base64', BASIC_URL_SAFE: 'base64url' },
      Base64Helper: class {
        decodeSync(text, type) {
          if (type === 'base64' && /[-_]/.test(text)) throw new Error('URL-safe input');
          if (!/^[A-Za-z0-9+/_=-]+$/.test(text)) throw new Error('Invalid base64');
          return Uint8Array.from(Buffer.from(text, type));
        }
      },
      TextDecoder: { create: () => new TextDecoder() }
    }
  },
  '@kit.CoreFileKit': { fileIo, picker: {} },
  '@kit.ArkData': {
    preferences: {
      getPreferences: async () => ({
        get: async (key, fallback) => values.get(key) ?? fallback,
        put: async (key, value) => values.set(key, value),
        flush: async () => {}
      })
    }
  },
  '@kit.BasicServicesKit': {
    pasteboard: {
      getSystemPasteboard: () => ({ getData: async () => ({ getPrimaryText: () => clipboard }) })
    }
  },
  '@kit.NetworkKit': {
    http: {
      RequestMethod: { GET: 'GET' },
      HttpDataType: { STRING: 'STRING' },
      createHttp: () => ({
        request: async (url, options) => {
          requests.push({ url, options });
          return respond(url, options);
        },
        destroy: () => { destroyed++; }
      })
    }
  }
};

const modules = new Map();
function evaluate(source, filename, globals = {}) {
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
    fileName: filename
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(compiled, {
    module, exports: module.exports,
    require: (name) => {
      if (Object.hasOwn(kits, name)) return kits[name];
      if (name.startsWith('.')) return load(path.resolve(path.dirname(filename), `${name}.ets`));
      throw new Error(`Unexpected production dependency: ${name}`);
    },
    console, setTimeout, clearTimeout, Observed: value => value, ...globals
  }, { filename });
  return module.exports;
}
function load(filename) {
  if (modules.has(filename)) return modules.get(filename);
  const loaded = evaluate(fs.readFileSync(filename, 'utf8'), filename);
  modules.set(filename, loaded);
  return loaded;
}
const service = (name) => load(path.join(root, `entry/src/main/ets/services/${name}.ets`))[name];
const Converter = service('GenericSubscriptionConverterService');
const Parser = service('ClashConfigParserService');
const Subscription = service('SubscriptionService');
const ProfileStore = service('ProfileStore');
const Runtime = service('RuntimeConfigService');
const Clipboard = service('ClipboardImportService');
const Profile = load(path.join(root, 'entry/src/main/ets/models/Profile.ets'));

const yaml = `proxies:
  - name: Test-node
    type: ss
    server: example.com
    port: 8388
    cipher: aes-128-gcm
    password: fixture-password
proxy-groups:
  - name: Proxy
    type: select
    proxies: [Test-node]
rules:
  - MATCH,Proxy
`;
const ss = 'ss://YWVzLTEyOC1nY206Zml4dHVyZQ==@example.com:8388#Demo';
const html = '<html><body>Login required. Example: proxies:</body></html>';
const remote = (uid, source) => ({
  uid, source, type: 'remote', name: uid, filePath: '', updatedAt: 0, nodeCount: 0, traffic: '未知'
});
function reset() {
  values.clear(); files.clear(); descriptors.clear(); requests.length = 0;
  clipboard = ''; destroyed = 0;
  respond = () => ({ responseCode: 200, result: yaml });
}
function profiles(state) { values.set('profile_state', JSON.stringify(state)); }
const tests = [];
function test(name, fn) { tests.push({ name, fn }); }

test('plain Clash YAML remains unchanged', () => {
  const result = Converter.normalizeToClashYaml(yaml);
  assert.equal(result.ok, true);
  assert.equal(result.text, yaml.trim());
  assert.equal(result.nodeCount, 1);
});
test('Base64-wrapped YAML is decoded before node conversion', () => {
  const result = Converter.normalizeToClashYaml(Buffer.from(yaml).toString('base64'));
  assert.equal(result.ok, true);
  assert.equal(result.text, yaml.trim());
  assert.equal(result.nodeCount, 1);
});
test('unpadded URL-safe Base64 YAML is accepted', () => {
  const text = `${yaml}# Unicode 🌐 节点\n`;
  const result = Converter.normalizeToClashYaml(Buffer.from(text).toString('base64url'));
  assert.equal(result.ok, true);
  assert.equal(result.text, text.trim());
});
test('wrapped Base64 tolerates spaces tabs and CRLF', () => {
  const encoded = Buffer.from(yaml).toString('base64').match(/.{1,30}/g).join(' \t\r\n');
  assert.equal(Converter.normalizeToClashYaml(encoded).ok, true);
});
test('quoted YAML section keys and spaces around the colon are accepted', () => {
  const text = yaml.replace('proxies:', '"proxies" : # nodes');
  const result = Converter.normalizeToClashYaml(text);
  assert.equal(result.ok, true);
  assert.equal(result.nodeCount, 1);
});
test('indentless YAML proxy sequences are shown in the node list', () => {
  const text = yaml.replace(/^  /gm, '');
  assert.equal(yamlCodec.load(text).proxies[0].name, 'Test-node');
  const nodes = Parser.parseProxyNodes(text);
  assert.equal(nodes.length, 1);
  assert.equal(nodes[0].name, 'Test-node');
  assert.equal(nodes[0].server, 'example.com');
});
test('HTML mentioning proxies is rejected as a web page', () => {
  const result = Converter.normalizeToClashYaml(html);
  assert.equal(result.ok, false);
  assert.match(result.message, /网页/);
});
test('Base64-wrapped HTML receives the same web-page diagnosis', () => {
  const result = Converter.normalizeToClashYaml(Buffer.from(html).toString('base64'));
  assert.equal(result.ok, false);
  assert.match(result.message, /网页/);
});
test('unsupported URI subscriptions identify the protocol without leaking credentials', () => {
  const uri = 'vmess://private-fixture-value';
  const result = Converter.normalizeToClashYaml(Buffer.from(uri).toString('base64'));
  assert.equal(result.ok, false);
  assert.match(result.message, /vmess/i);
  assert.ok(!result.message.includes('private-fixture-value'));
});
test('mixed unsupported protocols are never silently discarded', () => {
  const result = Converter.normalizeToClashYaml(`${ss}\nvless://fixture@example.com:443#Other`);
  assert.equal(result.ok, false);
  assert.match(result.message, /vless/i);
});
test('Shadowsocks conversion remains available', () => {
  const result = Converter.normalizeToClashYaml(ss);
  assert.equal(result.ok, true);
  assert.match(result.text, /type: ss/);
  assert.match(result.text, /MATCH,Proxy/);
  assert.equal(yamlCodec.load(result.text).proxies[0].server, 'example.com');
});
test('Shadowsocks plugin parameters survive full-URI Base64 conversion', () => {
  const uri = 'ss://YWVzLTEyOC1nY206cGFzc0BleGFtcGxlLmNvbTo4NDQz?plugin=simple-obfs%3Bobfs%3Dhttp%3Bobfs-host%3Dedge.example.com#Demo';
  const result = Converter.normalizeToClashYaml(Buffer.from(uri).toString('base64url'));
  assert.equal(result.ok, true);
  const node = yamlCodec.load(result.text).proxies[0];
  assert.equal(node.server, 'example.com');
  assert.equal(node.port, 8443);
  assert.equal(node.plugin, 'obfs');
  assert.equal(node['plugin-opts'].host, 'edge.example.com');
});
test('an error JSON mentioning proxies is rejected without echoing its body', () => {
  const result = Converter.normalizeToClashYaml('{"error":"proxies: private-fixture-value"}');
  assert.equal(result.ok, false);
  assert.match(result.message, /JSON/);
  assert.ok(!result.message.includes('private-fixture-value'));
});
test('subscription request negotiates Clash output with User-Agent and Accept', async () => {
  profiles({ currentUid: 'one', items: [remote('one', 'https://example.com/sub')] });
  respond = (_url, options) => ({
    responseCode: 200,
    result: /clash-verge/i.test(options.header?.['User-Agent'] ?? '') ? yaml : 'vmess://fixture'
  });
  const result = await Subscription.updateProfile(context, 'one');
  assert.equal(result.ok, true);
  assert.match(requests[0].options.header['Accept'], /yaml/);
  assert.match(requests[0].options.header['User-Agent'], /ClashHarmony/);
  assert.equal(destroyed, 1);
});

test('server account usage and expiry survive profile persistence independently of YAML size', async () => {
  profiles({ currentUid: 'one', items: [remote('one', 'https://example.com/sub')] });
  const GB = 1024 ** 3;
  respond = () => ({ responseCode: 200, result: yaml, header: {
    'Subscription-Userinfo': `upload=${GB}; download=${2 * GB}; total=${10 * GB}; expire=1894665600`
  } });
  const result = await Subscription.updateProfile(context, 'one');
  assert.equal(result.ok, true);
  const saved = await ProfileStore.load(context);
  assert.equal(saved.items[0].subscriptionInfo.upload, GB);
  assert.equal(saved.items[0].subscriptionInfo.download, 2 * GB);
  assert.equal(saved.items[0].subscriptionInfo.total, 10 * GB);
  assert.equal(saved.items[0].subscriptionInfo.expire, 1894665600);
  assert.ok(saved.items[0].subscriptionInfoCheckedAt > 0);
  assert.notEqual(saved.items[0].traffic, '3.0 GB', 'the legacy file-size field cannot masquerade as account traffic');
});

test('failed downloads preserve cached quota, successful responses without quota clear stale information', async () => {
  const profile = { ...remote('one', 'https://example.com/sub'), filePath: '/old.yaml',
    subscriptionInfo: { upload: 1, download: 2, total: 10, expire: 1894665600 }, subscriptionInfoCheckedAt: 1000 };
  profiles({ currentUid: 'one', items: [profile] });
  files.set('/old.yaml', yaml);
  respond = () => ({ responseCode: 503, result: 'unavailable' });
  assert.equal((await Subscription.updateProfile(context, 'one')).ok, false);
  assert.equal((await ProfileStore.load(context)).items[0].subscriptionInfo.total, 10);
  assert.equal((await ProfileStore.load(context)).items[0].subscriptionInfoCheckedAt, 1000);
  respond = () => ({ responseCode: 200, result: html, header: { 'subscription-userinfo': 'total=1234' } });
  assert.equal((await Subscription.updateProfile(context, 'one')).ok, false);
  assert.equal((await ProfileStore.load(context)).items[0].subscriptionInfo.total, 10);
  respond = () => ({ responseCode: 200, result: yaml });
  assert.equal((await Subscription.updateProfile(context, 'one')).ok, true);
  const saved = await ProfileStore.load(context);
  assert.equal(saved.items[0].subscriptionInfo, undefined);
  assert.ok(saved.items[0].subscriptionInfoCheckedAt > 1000);
});
test('HTTP errors preserve the last downloaded profile and close the request', async () => {
  const old = { ...remote('one', 'https://example.com/sub'), filePath: '/cached.yaml' };
  profiles({ currentUid: 'one', items: [old] }); files.set('/cached.yaml', yaml);
  respond = () => ({ responseCode: 403, result: '<html>Denied</html>' });
  const result = await Subscription.updateProfile(context, 'one');
  assert.equal(result.ok, false);
  assert.match(result.message, /403/);
  assert.equal(files.get('/cached.yaml'), yaml);
  assert.equal((await ProfileStore.load(context)).items[0].filePath, '/cached.yaml');
  assert.equal(destroyed, 1);
});
test('a successful HTTP response containing a web page does not replace cached YAML', async () => {
  const old = { ...remote('one', 'https://example.com/sub'), filePath: '/cached.yaml' };
  profiles({ currentUid: 'one', items: [old] }); files.set('/cached.yaml', yaml);
  respond = () => ({ responseCode: 200, result: html });
  const result = await Subscription.updateProfile(context, 'one');
  assert.equal(result.ok, false);
  assert.match(result.message, /网页/);
  assert.equal((await ProfileStore.load(context)).items[0].filePath, '/cached.yaml');
  assert.equal(files.get('/cached.yaml'), yaml);
});
test('clipboard Base64 YAML uses the shared subscription conversion', async () => {
  clipboard = Buffer.from(yaml).toString('base64');
  const result = await Clipboard.importProfile(context);
  assert.equal(result.ok, true);
  assert.equal(result.state.items[0].nodeCount, 1);
  assert.equal(files.get(result.state.items[0].filePath), yaml.trim());
});
test('runtime preparation cannot bypass the shared HTML rejection', async () => {
  const profile = { ...remote('one', 'https://example.com/sub'), filePath: '/cached.yaml' };
  files.set('/cached.yaml', html);
  const result = await Runtime.prepareCurrentProfile(context, { currentUid: 'one', items: [profile] });
  assert.equal(result.ok, false);
  assert.match(result.message, /网页/);
  assert.equal(files.has(Runtime.getRuntimeConfigPath(context)), false);
});
test('runtime output from Base64 YAML is valid and keeps the nodes', async () => {
  const profile = { ...remote('one', 'https://example.com/sub'), filePath: '/cached.yaml' };
  files.set('/cached.yaml', Buffer.from(yaml).toString('base64url'));
  const result = await Runtime.prepareCurrentProfile(context, { currentUid: 'one', items: [profile] });
  assert.equal(result.ok, true);
  const config = yamlCodec.load(files.get(result.configPath));
  assert.equal(config.proxies[0].name, 'Test-node');
  assert.equal(config['external-controller'], '127.0.0.1:9090');
});
test('quoted managed DNS and hosts blocks are replaced with valid runtime settings', async () => {
  const profile = { ...remote('one', 'https://example.com/sub'), filePath: '/cached.yaml' };
  files.set('/cached.yaml', `${yaml}\n"dns":\n  enable: false\n  nameserver:\n  - https://old.example/dns-query\n"hosts":\n  old.example: 192.0.2.1\n"mixed-port": 9999\n`);
  const result = await Runtime.prepareCurrentProfile(context, { currentUid: 'one', items: [profile] });
  assert.equal(result.ok, true);
  const config = yamlCodec.load(files.get(result.configPath));
  assert.equal(config.dns.enable, true);
  assert.equal(config['mixed-port'], 7890);
  assert.equal(config.hosts, undefined);
  assert.ok(!files.get(result.configPath).includes('old.example'));
});
test('adding a second subscription downloads the new item while keeping the current selection', async () => {
  const current = { ...remote('old', 'https://example.com/old'), filePath: '/old.yaml' };
  files.set('/old.yaml', yaml);
  profiles({ currentUid: 'old', items: [current] });
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
  const methods = ['addRemoteProfile', 'runProfileUpdates'].map(name => {
    const method = source.match(new RegExp('  private async ' + name + '\\([^]*?\\n  \\}'))?.[0];
    assert.ok(method, 'Production method must be available: ' + name); return method;
  }).join('\n');
  const { ProfileUpdateViewState } = load(path.join(root, 'entry/src/main/ets/models/ProfileUpdateViewState.ets'));
  const { Harness } = evaluate(`class Harness { ${methods} }\nmodule.exports = { Harness };`,
    path.join(root, 'entry/src/main/ets/pages/Index-test.ts'), {
      getContext: () => context, ProfileStore, createRemoteProfile: Profile.createRemoteProfile,
      SubscriptionService: Subscription, RuntimeConfigService: Runtime
    });
  const app = new Harness();
  Object.assign(app, {
    importUrl: 'https://example.com/new', importName: 'New',
    profileUpdate: new ProfileUpdateViewState(), profileMutationBusy: false, isRuntimeConnected: () => false,
    applyProfileState: (state) => { app.profileState = state; },
    refreshProxyNodes: async () => {}, recordLog: () => {}, syncHomeRuntimeFields: () => {}
  });
  await app.addRemoteProfile();
  assert.equal(requests[0].url, 'https://example.com/new');
  const saved = await ProfileStore.load(context);
  assert.equal(saved.currentUid, 'old');
  assert.ok(saved.items.find((item) => item.source === 'https://example.com/new').filePath);
});

let passed = 0;
for (const { name, fn } of tests) {
  reset();
  try { await fn(); passed++; console.log(`PASS ${name}`); }
  catch (error) { console.error(`FAIL ${name}\n${error.message}`); }
}
console.log(`${passed}/${tests.length} subscription compatibility tests passed`);
if (passed !== tests.length) process.exitCode = 1;
