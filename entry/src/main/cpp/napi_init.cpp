#include "napi/native_api.h"
#include "mihomo_adapter.h"
#include "tun_forwarder.h"
#include "socket_protector.h"
#include "health_monitor.h"

#include <cerrno>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <exception>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <unistd.h>

namespace {

struct RuntimeState {
    bool running = false;
    int32_t tunFd = -1;
    int32_t nativeFd = -1;
    int32_t startCount = 0;
    int32_t stopCount = 0;
    bool controllerReady = false;
    bool controllerOnly = false;
    bool tunAttached = false;
    bool supportsControllerOnly = false;
    bool supportsTunAttach = false;
    bool realConnectionReady = false;
    std::string configPath;
    std::string coreMode = "idle";
    std::string adapterMode = "unloaded";
    std::string adapterKind = "unknown";
    std::string adapterInfo;
    std::string adapterLoadError;
    std::string adapterVersion;
    std::string controllerVersion;
    std::string version;
    std::string lastError;
};

std::mutex g_stateMutex;
RuntimeState g_state;
TunForwarder g_forwarder;
std::atomic<bool> g_coreOperationActive {false};

bool ClaimCoreOperation()
{
    bool expected = false;
    return g_coreOperationActive.compare_exchange_strong(expected, true);
}

napi_value CreateString(napi_env env, const std::string& value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.length(), &result);
    return result;
}

void SetBoolean(napi_env env, napi_value object, const char* name, bool value)
{
    napi_value napiValue = nullptr;
    napi_get_boolean(env, value, &napiValue);
    napi_set_named_property(env, object, name, napiValue);
}

void SetInt32(napi_env env, napi_value object, const char* name, int32_t value)
{
    napi_value napiValue = nullptr;
    napi_create_int32(env, value, &napiValue);
    napi_set_named_property(env, object, name, napiValue);
}

void SetInt64(napi_env env, napi_value object, const char* name, uint64_t value)
{
    napi_value napiValue = nullptr;
    napi_create_int64(env, static_cast<int64_t>(value), &napiValue);
    napi_set_named_property(env, object, name, napiValue);
}

void SetString(napi_env env, napi_value object, const char* name, const std::string& value)
{
    napi_set_named_property(env, object, name, CreateString(env, value));
}

void CloseNativeFdLocked()
{
    if (g_state.nativeFd >= 0) {
        close(g_state.nativeFd);
        g_state.nativeFd = -1;
    }
}

struct AdapterSnapshot {
    std::string mode;
    std::string kind;
    std::string info;
    std::string loadError;
    bool supportsControllerOnly = false;
    bool supportsTunAttach = false;
};

AdapterSnapshot ReadAdapterSnapshot()
{
    AdapterSnapshot snapshot;
    snapshot.mode = MihomoAdapterMode();
    snapshot.kind = MihomoAdapterKind();
    snapshot.info = MihomoAdapterInfo();
    snapshot.loadError = MihomoAdapterLoadError();
    snapshot.supportsControllerOnly = MihomoSupportsControllerOnly();
    snapshot.supportsTunAttach = MihomoSupportsTunAttach();
    return snapshot;
}

void ApplyAdapterSnapshotLocked(const AdapterSnapshot& snapshot)
{
    g_state.adapterMode = snapshot.mode;
    g_state.adapterKind = snapshot.kind;
    g_state.adapterInfo = snapshot.info;
    g_state.adapterLoadError = snapshot.loadError;
    g_state.supportsControllerOnly = snapshot.supportsControllerOnly;
    g_state.supportsTunAttach = snapshot.supportsTunAttach;
}

napi_value CreateStateObject(napi_env env)
{
    RuntimeState snapshot;
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        snapshot = g_state;
    }

    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetBoolean(env, result, "running", snapshot.running);
    SetInt32(env, result, "tunFd", snapshot.tunFd);
    SetInt32(env, result, "nativeFd", snapshot.nativeFd);
    SetInt32(env, result, "startCount", snapshot.startCount);
    SetInt32(env, result, "stopCount", snapshot.stopCount);
    SetBoolean(env, result, "controllerReady", snapshot.controllerReady);
    SetBoolean(env, result, "controllerOnly", snapshot.controllerOnly);
    SetBoolean(env, result, "tunAttached", snapshot.tunAttached);
    SetBoolean(env, result, "supportsControllerOnly", snapshot.supportsControllerOnly);
    SetBoolean(env, result, "supportsTunAttach", snapshot.supportsTunAttach);
    SetBoolean(env, result, "realConnectionReady", snapshot.realConnectionReady);
    SetString(env, result, "configPath", snapshot.configPath);
    SetString(env, result, "coreMode", snapshot.coreMode);
    SetString(env, result, "adapterMode", snapshot.adapterMode);
    SetString(env, result, "adapterKind", snapshot.adapterKind);
    SetString(env, result, "adapterInfo", snapshot.adapterInfo);
    SetString(env, result, "adapterLoadError", snapshot.adapterLoadError);
    SetString(env, result, "adapterVersion", snapshot.adapterVersion);
    SetString(env, result, "controllerVersion", snapshot.controllerVersion);
    SetString(env, result, "version", snapshot.version);
    SetString(env, result, "lastError", snapshot.lastError);

    ForwarderStatsSnapshot fwdStats = g_forwarder.GetStats();
    SetInt64(env, result, "packetsRead", fwdStats.packetsRead);
    SetInt64(env, result, "packetsWritten", fwdStats.packetsWritten);
    SetInt64(env, result, "bytesRead", fwdStats.bytesRead);
    SetInt64(env, result, "bytesWritten", fwdStats.bytesWritten);
    SetInt64(env, result, "readErrors", fwdStats.readErrors);
    SetInt64(env, result, "writeErrors", fwdStats.writeErrors);
    SetBoolean(env, result, "forwarderActive", g_forwarder.IsActive());

    return result;
}

bool ReadStringArg(napi_env env, napi_value value, std::string& output)
{
    size_t length = 0;
    napi_status status = napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    if (status != napi_ok) {
        return false;
    }

    std::vector<char> buffer(length + 1);
    size_t copied = 0;
    status = napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied);
    if (status != napi_ok) {
        return false;
    }
    output.assign(buffer.data(), copied);
    return true;
}

void RunStartTun(const std::string& configPath, int32_t tunFd, int32_t& duplicateFd)
{
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        CloseNativeFdLocked();
        g_state.startCount += 1;
        g_state.configPath = configPath;
        g_state.tunFd = tunFd;
        g_state.nativeFd = duplicateFd;
        duplicateFd = -1;
        g_state.running = false;
        g_state.controllerReady = false;
        g_state.controllerOnly = false;
        g_state.tunAttached = false;
        g_state.realConnectionReady = false;
        g_state.adapterVersion.clear();
        g_state.controllerVersion.clear();
        g_state.version.clear();
        g_state.coreMode = "starting";
        g_state.lastError.clear();
    }
    int32_t nativeFd;
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        nativeFd = g_state.nativeFd;
    }
    const int result = MihomoStart(configPath.c_str(), nativeFd);
    const AdapterSnapshot adapter = ReadAdapterSnapshot();
    const std::string version = result == 0 ? MihomoVersion() : "";
    const std::string error = result == 0 ? "" : MihomoLastError();
    const bool real = result == 0 && adapter.mode == "real" && adapter.kind == "mihomo";
    if (result == 0 && !real) {
        g_forwarder.Start(nativeFd, nullptr, SocketProtector::Protect);
    }
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        ApplyAdapterSnapshotLocked(adapter);
        g_state.running = result == 0;
        g_state.tunAttached = result == 0;
        g_state.realConnectionReady = real;
        g_state.adapterVersion = version;
        g_state.version = version;
        g_state.coreMode = result != 0 ? "error" : real ? "mihomo-adapter" : "adapter-stub";
        g_state.lastError = error;
        if (result != 0) {
            CloseNativeFdLocked();
        }
    }
}

void RunStartCore(const std::string& configPath)
{
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        g_state.startCount += 1;
        g_state.configPath = configPath;
        g_state.tunFd = -1;
        g_state.controllerReady = false;
        g_state.controllerOnly = false;
        g_state.tunAttached = false;
        g_state.realConnectionReady = false;
        g_state.adapterVersion.clear();
        g_state.controllerVersion.clear();
        g_state.version.clear();
        CloseNativeFdLocked();
        g_state.running = false;
        g_state.coreMode = "starting";
        g_state.lastError.clear();
    }

    // Core loading, Go initialization and adapter getters can block. None of them
    // may hold the UI-visible state mutex or execute on the ArkTS event loop.
    int startResult = MihomoStartCore(configPath.c_str());
    const std::string error = startResult == 0 ? "" : MihomoLastError();
    const std::string version = startResult == 0 ? MihomoVersion() : "";
    const AdapterSnapshot adapter = ReadAdapterSnapshot();
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        ApplyAdapterSnapshotLocked(adapter);
        g_state.running = startResult == 0;
        g_state.controllerOnly = startResult == 0;
        g_state.adapterVersion = version;
        g_state.version = g_state.controllerReady ? g_state.controllerVersion : version;
        g_state.coreMode = startResult == 0 ? "mihomo-controller" : "error";
        g_state.lastError = error;
    }
}

void RunStopCore()
{
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        g_state.coreMode = "stopping";
    }
    g_forwarder.Stop();
    int stopResult = MihomoStop();
    const std::string error = stopResult == 0 ? "" : MihomoLastError();
    const AdapterSnapshot adapter = ReadAdapterSnapshot();
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        CloseNativeFdLocked();
        g_state.running = false;
        g_state.tunFd = -1;
        g_state.controllerReady = false;
        g_state.controllerOnly = false;
        g_state.tunAttached = false;
        g_state.realConnectionReady = false;
        g_state.adapterVersion.clear();
        g_state.controllerVersion.clear();
        g_state.version.clear();
        ApplyAdapterSnapshotLocked(adapter);
        g_state.coreMode = stopResult == 0 ? "stopped" : "error";
        g_state.lastError = error;
        g_state.stopCount += 1;
    }
}

struct CoreAsyncWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string configPath;
    std::string error;
    bool start = false;
    bool tun = false;
    int32_t tunFd = -1;
    int32_t duplicateFd = -1;
};

void RejectCorePromise(napi_env env, napi_deferred deferred, const char* code, const std::string& message)
{
    napi_value error = nullptr;
    napi_create_error(env, CreateString(env, code), CreateString(env, message), &error);
    napi_reject_deferred(env, deferred, error);
}

void ExecuteCoreWork(napi_env env, void* data)
{
    (void)env;
    auto* operation = static_cast<CoreAsyncWork*>(data);
    try {
        if (operation->start && operation->tun) {
            RunStartTun(operation->configPath, operation->tunFd, operation->duplicateFd);
        } else if (operation->start) {
            RunStartCore(operation->configPath);
        } else {
            RunStopCore();
        }
    } catch (const std::exception& error) {
        operation->error = error.what();
    } catch (...) {
        operation->error = "Unknown native core exception";
    }
    if (!operation->error.empty()) {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        g_state.running = false;
        g_state.controllerOnly = false;
        g_state.coreMode = "error";
        g_state.lastError = operation->error;
    }
}

void CompleteCoreWork(napi_env env, napi_status status, void* data)
{
    auto* operation = static_cast<CoreAsyncWork*>(data);
    g_coreOperationActive.store(false);
    if (operation->duplicateFd >= 0) {
        close(operation->duplicateFd);
    }
    if (status != napi_ok || !operation->error.empty()) {
        RejectCorePromise(env, operation->deferred, "CORE_OPERATION_FAILED",
                          operation->error.empty() ? "Native core task was canceled" : operation->error);
    } else {
        napi_resolve_deferred(env, operation->deferred, CreateStateObject(env));
    }
    napi_delete_async_work(env, operation->work);
    delete operation;
}

napi_value QueueCoreWork(napi_env env, napi_callback_info info, bool start, bool tun = false)
{
    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_throw_error(env, "CORE_ASYNC_INIT", "Unable to create native core Promise");
        return nullptr;
    }

    std::string configPath;
    int32_t tunFd = -1;
    if (start) {
        size_t argc = tun ? 2 : 1;
        napi_value args[2] = {nullptr, nullptr};
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (argc < 1 || !ReadStringArg(env, args[0], configPath) || configPath.empty()) {
            RejectCorePromise(env, deferred, "CORE_INVALID_CONFIG", "Invalid configPath");
            return promise;
        }
        if (tun && (argc < 2 || napi_get_value_int32(env, args[1], &tunFd) != napi_ok || tunFd < 0)) {
            RejectCorePromise(env, deferred, "CORE_INVALID_TUN", "Invalid tunFd");
            return promise;
        }
    }
    if (!ClaimCoreOperation()) {
        RejectCorePromise(env, deferred, "CORE_BUSY", "Native core operation is in progress; please wait");
        return promise;
    }

    auto* operation = new (std::nothrow) CoreAsyncWork();
    if (operation == nullptr) {
        g_coreOperationActive.store(false);
        RejectCorePromise(env, deferred, "CORE_ASYNC_INIT", "Unable to allocate native core task");
        return promise;
    }
    operation->deferred = deferred;
    operation->configPath = configPath;
    operation->start = start;
    operation->tun = tun;
    operation->tunFd = tunFd;
    if (tun) {
        operation->duplicateFd = dup(tunFd);
        if (operation->duplicateFd < 0) {
            const std::string error = std::string("dup tunFd failed: ") + strerror(errno);
            delete operation;
            g_coreOperationActive.store(false);
            RejectCorePromise(env, deferred, "CORE_INVALID_TUN", error);
            return promise;
        }
    }
    napi_value name = CreateString(env, start ? "ClashCoreStart" : "ClashCoreStop");
    napi_status status = napi_create_async_work(env, nullptr, name, ExecuteCoreWork, CompleteCoreWork,
                                               operation, &operation->work);
    if (status == napi_ok) {
        status = napi_queue_async_work(env, operation->work);
    }
    if (status != napi_ok) {
        if (operation->work != nullptr) {
            napi_delete_async_work(env, operation->work);
        }
        g_coreOperationActive.store(false);
        if (operation->duplicateFd >= 0) {
            close(operation->duplicateFd);
        }
        delete operation;
        RejectCorePromise(env, deferred, "CORE_ASYNC_INIT", "Unable to queue native core task");
    }
    return promise;
}

napi_value StartTun(napi_env env, napi_callback_info info)
{
    return QueueCoreWork(env, info, true, true);
}

napi_value StartCore(napi_env env, napi_callback_info info)
{
    return QueueCoreWork(env, info, true);
}

napi_value StopCore(napi_env env, napi_callback_info info)
{
    return QueueCoreWork(env, info, false);
}

napi_value StopTun(napi_env env, napi_callback_info info)
{
    // TUN shutdown can wait on Go workers and must not block the ArkTS lifecycle
    // callback. Both controller and TUN shutdown use the same serialized cleanup.
    return QueueCoreWork(env, info, false);
}

napi_value SetControllerReady(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    bool ready = false;
    std::string version;
    bool ok = argc >= 2 &&
              napi_get_value_bool(env, args[0], &ready) == napi_ok &&
              ReadStringArg(env, args[1], version);

    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        if (!ok) {
            g_state.controllerReady = false;
            g_state.controllerVersion.clear();
            g_state.version.clear();
            g_state.lastError = "invalid controllerReady or version";
        } else if (!ready) {
            g_state.controllerReady = false;
            g_state.controllerVersion.clear();
            g_state.version.clear();
        } else {
            g_state.controllerReady = true;
            g_state.controllerVersion = version;
            g_state.version = version;
            if (!g_state.running) {
                g_state.coreMode = "external-controller";
            }
            g_state.lastError.clear();
        }
    }

    return CreateStateObject(env);
}

napi_value GetState(napi_env env, napi_callback_info info)
{
    (void)info;
    // Lifecycle workers refresh the adapter snapshot. Reading state must never
    // call into Go or contend on the adapter's initialization/shutdown lock.
    return CreateStateObject(env);
}

napi_value ProtectSocket(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t fd = -1;
    if (argc >= 1 && napi_get_value_int32(env, args[0], &fd) == napi_ok) {
        SocketProtector::Protect(fd);
    }

    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

napi_value SetProtectCallback(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    // Placeholder: stores the callback reference for future use
    // In a real implementation this would use napi_create_threadsafe_function
    // to allow the native layer to call back into the JS thread safely.
    // For now, the protect function is registered directly through the
    // TunForwarder::ProtectFunc type set at StartTun().
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

napi_value GetForwarderStats(napi_env env, napi_callback_info info)
{
    (void)info;
    ForwarderStatsSnapshot stats = g_forwarder.GetStats();

    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetInt64(env, result, "packetsRead", stats.packetsRead);
    SetInt64(env, result, "packetsWritten", stats.packetsWritten);
    SetInt64(env, result, "bytesRead", stats.bytesRead);
    SetInt64(env, result, "bytesWritten", stats.bytesWritten);
    SetInt64(env, result, "readErrors", stats.readErrors);
    SetInt64(env, result, "writeErrors", stats.writeErrors);
    SetBoolean(env, result, "active", g_forwarder.IsActive());
    return result;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "startTun", nullptr, StartTun, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopTun", nullptr, StopTun, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startCore", nullptr, StartCore, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopCore", nullptr, StopCore, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setControllerReady", nullptr, SetControllerReady, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getState", nullptr, GetState, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "protectSocket", nullptr, ProtectSocket, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setProtectCallback", nullptr, SetProtectCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getForwarderStats", nullptr, GetForwarderStats, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module clashCoreModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&clashCoreModule);
}
