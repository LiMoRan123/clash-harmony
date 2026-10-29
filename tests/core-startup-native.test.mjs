import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { setTimeout as delay } from 'node:timers/promises';
import { performance } from 'node:perf_hooks';

const require = createRequire(import.meta.url);
const root = process.cwd();
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'clash-core-startup-'));
const nodeInclude = process.env.NODE_INCLUDE_DIR ?? path.resolve(path.dirname(process.execPath), '../include/node');
const cpp = path.join(root, 'entry/src/main/cpp');

try {
  assert.ok(fs.existsSync(path.join(nodeInclude, 'node_api.h')), 'Node-API headers are required; set NODE_INCLUDE_DIR');
  fs.mkdirSync(path.join(temp, 'napi'));
  fs.writeFileSync(path.join(temp, 'napi/native_api.h'), `
#include <node_api.h>
#ifndef EXTERN_C_START
#define EXTERN_C_START extern "C" {
#define EXTERN_C_END }
#endif
`);
  fs.writeFileSync(path.join(temp, 'fake_adapter.cpp'), `
#include "mihomo_adapter.h"
#include <atomic>
#include <cstring>
#include <stdexcept>
#include <string>
#include <unistd.h>

std::atomic<bool> active(false);
std::atomic<bool> starting(false);
std::atomic<bool> stopping(false);
std::string error;

int MihomoStart(const char*, int) { starting.store(true); usleep(300000); starting.store(false); active.store(true); return 0; }
int MihomoStartCore(const char* config) {
    starting.store(true);
    usleep(strcmp(config, "slow.yaml") == 0 ? 500000 : 20000);
    starting.store(false);
    if (strcmp(config, "fail.yaml") == 0) { error = "fixture startup failure"; return -1; }
    if (strcmp(config, "throw.yaml") == 0) throw std::runtime_error("fixture native exception");
    active.store(true);
    error.clear();
    return 0;
}
int MihomoAttachTun(int) { return 0; }
int MihomoDetachTun() { return 0; }
int MihomoStop() { stopping.store(true); usleep(250000); active.store(false); stopping.store(false); return 0; }
const char* MihomoVersion() { return active.load() ? "fixture-core" : ""; }
const char* MihomoLastError() { return error.c_str(); }
const char* MihomoAdapterMode() {
    // Models adapter getters contending with the core's startup lock.
    if (active.load() || starting.load() || stopping.load()) usleep(300000);
    return "real";
}
const char* MihomoAdapterKind() { return "mihomo"; }
const char* MihomoAdapterInfo() { return "{}"; }
const char* MihomoAdapterLoadError() { return ""; }
bool MihomoSupportsControllerOnly() { return true; }
bool MihomoSupportsTunAttach() { return true; }
`);
  const addon = path.join(temp, 'entry.node');
  execFileSync(process.env.CXX ?? 'clang++', [
    '-std=c++17', '-shared', '-fPIC', '-Wno-deprecated-declarations',
    '-I', temp, '-I', nodeInclude, '-I', cpp,
    path.join(cpp, 'napi_init.cpp'), path.join(cpp, 'tun_forwarder.cpp'),
    path.join(cpp, 'socket_protector.cpp'), path.join(temp, 'fake_adapter.cpp'),
    '-o', addon,
    ...(process.platform === 'darwin' ? ['-undefined', 'dynamic_lookup'] : ['-pthread'])
  ], { stdio: 'pipe' });
  const native = require(addon);

  await assert.rejects(async () => native.startCore(''), /configPath/);
  const began = performance.now();
  const startup = native.startCore('slow.yaml');
  assert.ok(startup && typeof startup.then === 'function', 'startCore must return a Promise');
  assert.ok(performance.now() - began < 120, 'native startup must return without blocking the JS thread');
  let ticks = 0;
  const heartbeat = setInterval(() => { ticks++; }, 10);
  try {
    await delay(40);
    const beforeState = performance.now();
    const state = native.getState();
    assert.ok(performance.now() - beforeState < 120, 'getState must not wait on adapter startup locks');
    assert.equal(state.coreMode, 'starting');
    await assert.rejects(native.startCore('other.yaml'), /progress/);
    await assert.rejects(native.stopCore(), /progress/);
    await assert.rejects(native.stopTun(), /progress/);
    await assert.rejects(native.startTun('other.yaml', 0), /progress/);
    const started = await startup;
    assert.equal(started.running, true);
    assert.equal(started.controllerOnly, true);
    assert.equal(started.adapterVersion, 'fixture-core');
    assert.equal(started.startCount, 1);
    assert.ok(ticks >= 5, 'UI heartbeat must keep running during native startup');
    const steadyStateBegan = performance.now();
    assert.equal(native.getState().running, true);
    assert.ok(performance.now() - steadyStateBegan < 120, 'normal state reads also avoid slow adapter/Go getters');
  } finally {
    clearInterval(heartbeat);
  }

  const beforeStop = performance.now();
  const stopping = native.stopCore();
  assert.ok(stopping && typeof stopping.then === 'function', 'stopCore must return a Promise');
  assert.ok(performance.now() - beforeStop < 120, 'native stop must not block the JS thread');
  await delay(30);
  const beforeStoppingState = performance.now();
  assert.equal(native.getState().coreMode, 'stopping');
  assert.ok(performance.now() - beforeStoppingState < 120, 'getState must remain responsive during shutdown');
  const stopped = await stopping;
  assert.equal(stopped.running, false);
  assert.equal(stopped.stopCount, 1);

  await native.startCore('ok.yaml');
  const tunStopBegan = performance.now();
  const tunStop = native.stopTun();
  assert.ok(tunStop && typeof tunStop.then === 'function', 'TUN stop must return a Promise');
  assert.ok(performance.now() - tunStopBegan < 120, 'TUN shutdown must not block the lifecycle/JS thread');
  await delay(30);
  const tunStateBegan = performance.now();
  assert.equal(native.getState().coreMode, 'stopping');
  assert.ok(performance.now() - tunStateBegan < 120, 'state remains responsive during TUN shutdown');
  const tunStopped = await tunStop;
  assert.equal(tunStopped.tunFd, -1);
  assert.equal(tunStopped.nativeFd, -1);
  assert.equal(tunStopped.running, false);
  assert.equal(tunStopped.stopCount, 2);

  const tunFile = path.join(temp, 'tun.fixture');
  fs.writeFileSync(tunFile, 'fixture');
  const callerFd = fs.openSync(tunFile, 'r');
  const tunStartBegan = performance.now();
  const tunStartup = native.startTun('tun.yaml', callerFd);
  assert.ok(tunStartup && typeof tunStartup.then === 'function', 'TUN startup returns a Promise');
  assert.ok(performance.now() - tunStartBegan < 120, 'TUN startup never blocks the lifecycle thread');
  fs.closeSync(callerFd); // Native work must already own a duplicate.
  await delay(30);
  assert.equal(native.getState().coreMode, 'starting');
  const tunStarted = await tunStartup;
  assert.equal(tunStarted.running, true);
  assert.equal(tunStarted.tunAttached, true);
  assert.equal(tunStarted.realConnectionReady, true);
  assert.ok(fs.fstatSync(tunStarted.nativeFd).isFile(), 'native FD survives closing the caller FD');
  await native.stopTun();
  assert.throws(() => fs.fstatSync(tunStarted.nativeFd), /EBADF/);
  await assert.rejects(native.startTun('tun.yaml', -1), /tunFd/);

  const failed = await native.startCore('fail.yaml');
  assert.equal(failed.running, false);
  assert.equal(failed.lastError, 'fixture startup failure');
  await assert.rejects(native.startCore('throw.yaml'), /fixture native exception/);
  // A native exception must release the operation gate so a later attempt can run.
  assert.equal((await native.startCore('ok.yaml')).running, true);
  await native.stopCore();
  console.log('core-startup-native: async startup, shutdown, UI heartbeat, cached state, busy and error recovery passed');
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
