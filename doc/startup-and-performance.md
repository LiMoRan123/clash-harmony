# 核心启动与卡顿排查

日期：2026-10-28。分支：`dev`。

用户已确认订阅能够更新并展示节点，但点击测速后出现界面无响应；停止 DevEco Debug、从手机桌面打开后，测速等待一段时间仍退出。本次修复已确认的界面线程同步等待问题。退出原因尚缺少系统故障栈，不能据此认定真机崩溃已经解决。

用户随后反馈“连接上了，测试上 YouTube 是可以的”。据此记录当前手机的 VPN 实际访问成功；尚未确认当时安装包是否为本次异步修复包，也未确认测速与普通页面流畅度。

## 1 为什么鸿蒙可以运行 Go 内核

本项目的界面使用 ArkTS/ArkUI，通过 Node-API 调用 C++ 桥接层，再由 adapter 动态加载仓库提供的 ARM64 `libmihomo_ohos.so`。Mihomo 内核使用 Go 实现；Go 可以编译为机器码，也支持通过 `-buildmode=c-shared` 生成供 C/C++ 调用的共享库，手机上不需要单独安装 Go 开发环境。见 [Go 构建模式说明](https://pkg.go.dev/cmd/go#hdr-Build_modes)。

这是本机原生库调用，不是运行 Android APK。CPU 架构相同也不意味着普通 Linux/Android 库可以直接替换：鸿蒙的系统接口、链接依赖、线程与信号行为、VPN 接口都需要适配。仓库没有附带真实 Go 核心完整源码和可复现构建脚本，因此目前可以检查预编译库 ABI 与打包情况，无法完整审计其 Go 侧适配。

Go 内核的存在本身不能解释界面是否流畅；界面线程是否被占用、节点列表如何创建、刷新如何触发，也会影响响应速度。

## 2 已确认的阻塞路径

原调用链：

```text
Index.ensureControllerReadyForProxyActions
  → CoreBridgeService.startCore（同步）
  → NAPI StartCore（持有 g_stateMutex）
  → MihomoStartCore（持有 g_adapterMutex）
  → pthread_create + pthread_join，等待 Go 核心启动完成
```

虽然 adapter 创建了线程，但 `pthread_join` 仍让调用方同步等待。调用方是界面线程时，期间无法处理点击和界面更新。原生状态读取也会尝试获取 adapter 锁，不能只把最外层函数改名为 `async`。

另一个问题发生在从测速切换到 VPN 时：界面会同步停止本地测速核心，停止耗时同样会影响响应。

## 3 本次修改

- [napi_init.cpp](../entry/src/main/cpp/napi_init.cpp)：`startCore/stopCore` 改为 Promise，通过 `napi_create_async_work` 在工作线程启动、停止核心，完成回调回到 ArkTS 线程返回结果。工作线程不操作 JS 值。
- 状态锁只用于短暂更新；启动/停止中的 `getState` 返回缓存状态，避免等待 adapter 启动锁。生命周期操作增加互斥保护，重复启动、停止或 TUN 操作会报告忙碌。
- [Index.d.ts](../entry/src/main/cpp/types/libentry/Index.d.ts)：同步更新原生接口类型为 `Promise<NativeCoreState>`。
- [CoreBridgeService.ets](../entry/src/main/ets/services/CoreBridgeService.ets)：等待原生结果，默认启动超时 15 秒、停止超时 10 秒，并处理同步异常、Promise 拒绝和超时。超时不强行终止正在运行的 Go 任务，提示后台仍在执行。
- [Index.ets](../entry/src/main/ets/pages/Index.ets)：测速等待异步启动结果；启动 VPN 前等待本地核心停止，停止失败或超时则中止此次 VPN 启动。

`startTun/stopTun` 仍在 VPN Extension 的进程中执行，本次没有把全部 native API 都改为异步。Node-API 的线程与回调使用依据见 [OpenHarmony 异步任务文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/napi/use-napi-asynchronous-task.md)。

后续用户反馈断开按钮持续加载，已另将 stopTun 改为异步，并调整路由释放和状态处理，见 [VPN 断开修复记录](vpn-disconnect.md)。上段描述的是本次启动修复当时的范围。

## 4 验证结果

```bash
node tests/core-startup-native.test.mjs
node tests/core-bridge-async.test.mjs
node tests/mihomo-adapter-native.test.mjs
node tests/subscription-compat.test.mjs
node tests/app-flow.test.mjs
node tests/verify-hap-contents.mjs \
  entry/build/default/outputs/default/entry-default-signed.hap \
  --require-abi arm64-v8a --evidence-dir artifacts/core-startup-async-hap
node tests/verify-mihomo-prebuilt-packaging.mjs --require-abi arm64-v8a
```

本机回归均通过：

- 原生异步回归将真实 `napi_init.cpp` 编译为 Node-API 模块，仅使用慢速 adapter 替身。模拟 500ms 启动和 250ms 停止时，调用立即返回 Promise，事件循环心跳仍运行，状态读取不等待启动锁；并发操作拒绝、错误返回及异常后恢复均通过。
- ArkTS 桥接回归执行实际服务代码，覆盖结果等待、原生异常、启停超时、超时后的结果恢复和迟到的 Promise 拒绝。
- 原有 native adapter、app-flow 和订阅 21 项回归通过。
- HarmonyOS debug 编译和签名成功，耗时约 14.6 秒；HAP 内容与 ARM64 核心打包检查通过。x86_64 仍缺少真实核心库，按原配置使用 stub。

Node 上的 native 测试不加载真实鸿蒙 Go 库，不能替代手机上的线程、信号和 VPN 验证。

异步启停修复首次生成包：`entry/build/default/outputs/default/entry-default-signed.hap`。后续 UI 改造包见 [UI 改造记录](ui-redesign.md)。当时的 SHA256：

```text
2ffb965bd43745937de30ac280e2ae16bd1e3a181ecd16627795644c0ddbad59
```

HAP 检查证据位于被 Git 忽略的 `artifacts/core-startup-async-hap/`。签名与 `.clangd` 的用户修改保留。

## 5 真机反馈与待验证项

2026-10-28 用户反馈，VPN 连接后可以访问 YouTube。这说明当时设备与所选配置的核心、VPN 接管和网络转发链路已经能够实际工作；单次访问结果不代表所有节点、协议或长期运行均已验证。此项依据用户反馈，本机未直接读取流量或日志。

使用 DevEco Run 覆盖安装，从手机桌面打开后对同一订阅测速。需要核对启动过程中页面仍能响应，最终出现延迟结果或明确错误，而不是停在准备阶段；再核对测速后启动 VPN。

如仍退出，需要按发生时间查看 DevEco 的 FaultLog/HiLog，区分 `APP_FREEZE`、ArkTS 异常、native 信号或 Go fatal/panic。现有 SIGURG 调试暂停记录不能充当新退出的崩溃证据。

当前工具执行环境访问 HDC server 受限，未直接安装此包或读取真机故障栈；本机构建成功与手机通过验收分开记录。

## 6 普通页面卡顿的后续检查点

以下是源码中发现的候选点，尚未经过真机性能采样确认：

- 代理页使用 `Scroll + Column + ForEach` 创建所有节点行，没有按可见区域懒加载。节点数多时可能增加首次布局与更新成本。
- 首页每秒获取连接与配置，运行时每三轮刷新代理信息。节点行 key 包含延迟、状态和选中值，变化时可能销毁并重建对应行。
- 运行配置会扫描和重写订阅文本。对于大型订阅，需要测量文本处理耗时；`async` 函数中的同步计算仍占用调用线程。

后续应在正常运行条件下用 DevEco Profiler 分别采集页面切换、节点滚动、测速和连接时的 CPU/帧时间，再确定列表懒加载、刷新粒度和文本处理的优化范围。
