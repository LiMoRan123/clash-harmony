import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const ts = require(process.env.ARKTS_TYPESCRIPT_PATH ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const module = { exports: {} };
const source = fs.readFileSync('entry/src/main/ets/services/SubscriptionInfoService.ets', 'utf8');
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText, { module, exports: module.exports });
const { SubscriptionInfoService: Info } = module.exports;
const plain = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
const GB = 1024 ** 3;
const expiry = Date.UTC(2030, 0, 15) / 1000;
const header = `upload=${GB}; download=${2 * GB}; total=${10 * GB}; expire=${expiry}`;
const expected = { upload: GB, download: 2 * GB, total: 10 * GB, expire: expiry };
assert.deepEqual(plain(Info.fromHeaders({ 'Subscription-Userinfo': header })), expected);
assert.deepEqual(plain(Info.fromHeaders({ 'SUBSCRIPTION-USERINFO': [header] })), expected);
assert.deepEqual(plain(Info.fromHeaders(JSON.stringify({ 'subscription-userinfo': header }))), expected);
assert.deepEqual(plain(Info.parse(' Upload = 1e3 ; DOWNLOAD = 20.9 ; ToTal = 5000; unknown=private-fixture ')),
  { upload: 1000, download: 20, total: 5000 });
assert.deepEqual(plain(Info.fromHeaders({ 'subscription-userinfo': ['upload=1', 'download=2', 'total=10'] })),
  { upload: 1, download: 2, total: 10 });
for (const headers of [undefined, null, {}, [], 'bad json', { other: header }, { 'subscription-userinfo': 1 }]) {
  assert.equal(Info.fromHeaders(headers), undefined);
}
for (const text of ['unknown=1', 'upload=-1;download=NaN;total=Infinity;expire=no-date',
  'total=0x10', 'upload=9007199254740992', 'expire=8640000000001', 'upload=', 'x'.repeat(8193)]) {
  assert.equal(Info.parse(text), undefined, text.slice(0, 60));
}
const info = Info.parse(header);
assert.equal(Info.usedBytes(info), 3 * GB);
assert.equal(Info.usagePercent(info), 30);
assert.equal(Info.usageText(info), '已用 3.0 GB / 10.0 GB · 剩余 7.0 GB');
assert.equal(Info.exhausted(info), false);
assert.match(Info.expiryText(info, Date.UTC(2029, 0, 1)), /2030-01-15 到期/);
assert.equal(Info.expired(info, Date.UTC(2031, 0, 1)), true);
assert.match(Info.expiryText(info, Date.UTC(2031, 0, 1)), /已到期/);
assert.equal(Info.usagePercent({ upload: 8, download: 5, total: 10 }), 100);
assert.equal(Info.exhausted({ upload: 8, download: 5, total: 10 }), true);
assert.match(Info.usageText({ upload: 8, download: 5, total: 10 }), /额度已用尽/);
assert.equal(Info.usagePercent({ upload: 0, download: 0, total: 10 }), 0);
assert.match(Info.usageText({ upload: 0, download: 0, total: 0 }), /已用 0 B · 总额度未提供/);
assert.equal(Info.usagePercent({ upload: 0, download: 0, total: 0 }), undefined);
assert.equal(Info.usagePercent({ download: 5, total: 10 }), undefined, 'missing upload is not silently counted as zero');
assert.match(Info.usageText({ download: 5, total: 10 }), /下载 5 B/);
assert.equal(Info.expiryText({ expire: 0 }), '到期时间未提供', 'zero must not promise a permanent subscription');
assert.equal(Info.expiryText({}), '到期时间未提供');
assert.equal(Info.usedBytes({ upload: Number.MAX_SAFE_INTEGER, download: 1 }), undefined);
assert.equal(Info.usageText({ expire: expiry }), '流量信息未提供');
assert.equal(Info.checkedAt(0), undefined);
assert.equal(Info.checkedAt(-1), undefined);
assert.equal(Info.checkedAt(8640000000000001), undefined);
assert.equal(Info.checkedAt(1234), 1234);
assert.equal(Info.normalize(null), undefined);
assert.equal(Info.normalize([]), undefined);
assert.deepEqual(plain(Info.normalize({ upload: 1, download: 'bad', total: Infinity, expire: -1 })), { upload: 1 });
console.log('subscription-info: header variants, byte accounting, epoch expiry, partial/unknown/invalid values and exhausted quotas passed');
