# VPN 断开按钮持续加载修复

日期：2026-10-28。分支：dev。

本文为首轮修复记录。2026-10-29 已进一步改为运行中扩展主动释放路由、事件与系统网络共同确认，详见 [后台稳定性与关闭延迟](background-stability.md)，以其安装包记录为准。

用户在新 UI 上反馈，点击断开后按钮一直处于加载状态。本轮根据源码修复了停止路径中的同步调用和结果处理问题；没有取得这次真机停止时的 HiLog/线程栈，因此最终手机表现仍需复测。

## 1 源码中确认的问题

- VPN Extension 的 onDestroy 调用 stopTunnel，而原 stopTunnel 在第一次 await 之前同步执行 CoreBridgeService.stopTun。原生 StopTun 持有状态锁等待转发器与 Go 内核停止，期间会阻塞调用线程，并可能阻塞状态读取。
- 原来只有 stopCore 使用后台任务，VPN 的 stopTun 没有走同一异步路径。
- 界面没有处理 VpnService.stop 返回的 false，提前清除了连接状态。停止失败或超时也可能被显示为成功。
- 已发出的状态轮询不会因断开而自动取消，旧响应可能在清理后再次写回连接信息。

VpnExtensionAbility 的 SDK 声明是 onDestroy(): void，不能依赖框架等待一个异步生命周期返回值。本轮保留该签名，在回调内立即发起后台原生清理和系统路由销毁。

## 2 修改

1. 原生 stopTun 改为返回 Promise，复用现有异步停止任务和生命周期互斥。Go 停止不再占用 ArkTS 回调线程，停止中的 getState 使用缓存状态。
2. CoreBridgeService.stopTun 等待原生结果，并使用 10 秒超时。超时不强行取消 Go 任务。
3. VPN Extension 先排入原生停止任务，随即调用 connection.destroy，释放系统 VPN 路由，不等待 Go 关闭完成才释放网络。路由销毁等待也有边界，异常会记录。
4. 同一次销毁复用一个清理任务；异步创建 TUN 如果在销毁后才完成，会再次销毁连接，不启动新的内核。
5. 界面在请求期间显示“正在断开 VPN”；只有系统停止请求成功返回后才清理连接显示。请求超时或失败会退出加载态、显示重试提示并恢复状态检查。
6. 停止轮询时使旧轮询失效，旧响应不能再把界面改回已连接。

系统停止 API 的返回值表示请求结果，不是独立的流量观测证明。Go 清理日志、系统路由释放和最终界面需要结合真机确认。

## 3 验证

- vpn-disconnect.test.mjs：执行实际 VpnService、VPN Extension 和提取的实际页面方法，覆盖停止超时/失败、路由先发起销毁、重复清理、创建与销毁竞争、按钮恢复和旧响应失效。
- core-startup-native.test.mjs：编译实际 NAPI 代码，增加 TUN 停止的 Promise、非阻塞返回、状态读取、互斥与 FD 状态回归。
- core-bridge-async.test.mjs：增加 stopTun 超时与完成结果回归。
- 原有 app-flow 回归通过。
- HarmonyOS debug 编译和签名成功，约 20.9 秒；ARM64 HAP 内容和内核打包检查通过。

原生测试用慢速 adapter 替身，不能代替真实鸿蒙 Go 库的关闭验证。签名配置和用户已有修改保留。

安装包：entry/build/default/outputs/default/entry-default-signed.hap。

SHA256：

```text
32c4dc322eb93e60c43fbd3b57c9eee37f24d361480d4adb79c9c69c5b821e8e
```

打包证据位于被 Git 忽略的 artifacts/vpn-disconnect-hap/。

## 4 手机复测

使用 DevEco Run 覆盖安装，保持原订阅。连接成功后断开，核对按钮恢复、系统 VPN 状态与手机普通网络；再连接、断开一次。若仍异常，记录停留时的完整状态文案，以及其他页面能否点击。

本轮只修复功能性停止问题，未开展此前已后置的 UI 性能专项优化。

后续性能改造已将 TUN 启动异步化，并以生命周期事件确认启停结果，见 [运行状态推送与性能记录](runtime-push-and-performance.md)。最新安装包与该文档构建记录对应。
