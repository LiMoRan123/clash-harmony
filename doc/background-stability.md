# 后台断开与关闭延迟处理

日期：2026-10-29。分支：dev。

本文记录后台运行与停止路径。其后的 UI 细节调整及当前安装包见 [界面细化与更新反馈](ui-polish.md)。

## 现象与判断

用户反馈：切到后台打开 Google 时偶尔断开，系统 VPN 图标也消失；重新打开应用后，Google、YouTube 又可访问。另有关闭偏慢的问题。

源码确认原工程没有声明后台运行权限、后台任务类型，也没有调用长时任务 API。这是后台运行的一处明确缺口。现象符合挂起或后台进程结束的可能性，但目前没有取得对应时刻的设备 HiLog 或退出栈，不能认定每次断开都由同一个原因引起。当前可读取的 DevEco IDE 日志没有这次断开的直接证据；本执行环境无法连接 HDC 服务。

## 后台运行

- `EntryAbility` 声明 `dataTransfer`，模块新增普通权限 `ohos.permission.KEEP_BACKGROUND_RUNNING`。
- [VpnBackgroundService](../entry/src/main/ets/services/VpnBackgroundService.ets) 用 UIAbilityContext 申请数据传输长时任务。启动 VPN 时申请，确认断开后释放；重复连接事件不会重复申请。
- 任务通知绑定系统返回的 notificationId。复用现有 WebSocket 的真实累计流量，最多每 30 秒更新一次实况通知；无流量变化不伪造进度，无独立 HTTP 轮询。VPN 没有固定完成总量，通知采用不确定进度，文本显示实际传输量。
- 启动期间收到关闭请求，会在申请完成后释放任务；通知更新与任务释放顺序处理，避免旧通知在断开后继续发布。
- 记录长时任务取消原因码及操作错误码。系统取消后只在下一次回到前台时尝试恢复；用户取消任务或移除通知后，不循环重新申请。显式断开、重新连接可以申请新任务。

这不是无限后台运行保证。数据传输任务仍受真实流量、系统负载、通知和后台策略约束；空闲或低流量可能被取消，实际表现必须在真机持续测试。不会用随机进度、静音音频或虚假定位维持运行。

FlClash 鸿蒙分支使用的 `taskKeeping` 在手机上需要额外的 `KEEP_BACKGROUND_RUNNING_SYSTEM` ACL 授权，不能只复制一行配置就认为生效。本次保留现有签名，未声明该受限权限。

依据：[OpenHarmony 长时任务指南](https://raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/task-management/continuous-task.md)、[任务 API 与实况通知示例](https://raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/reference/apis-backgroundtasks-kit/js-apis-resourceschedule-backgroundTaskManager.md)、[FlClash NotificationManager](https://github.com/tljk/FlClash-ohos/blob/017c08b8f842fef37ffb3220605b2477380a6dc4/ohos/entry/src/main/ets/managers/NotificationManager.ets)。

## 关闭路径

旧流程先调用系统停止扩展，再等扩展销毁时发出的事件，可能叠加等待，也依赖框架销毁期间的异步回调能够完成。

新流程通过 [VpnControlChannel](../entry/src/main/ets/services/VpnControlChannel.ets) 向运行中的扩展发送带 sessionId 的停止请求：

1. 先注册确认等待，再发送命令。发布目标和订阅发布者都限制为本应用；旧会话命令不影响当前连接。
2. 扩展并行发起后台原生清理和系统隧道销毁。系统路由释放成功就发布 disconnected，界面结束加载；Go 清理继续进行，完成后停止扩展。
3. 800 ms 未收到确认则启用系统停止 API 兼容路径，总事件等待预算为 3.2 秒，不再叠加旧的 4 秒等待。
4. 事件丢失时，只有系统停止 API 成功且系统网络查询确认没有 VPN 网络，才将其作为补充成功依据。查询失败为“未知”；仍有其他 VPN 网络时不能据此宣布本应用已断开。
5. 重复停止共享清理任务。被销毁实例迟到的清理回调不会停止后来新建的实例。快速重连前先结束上一扩展，避免新请求被仍在清理的实例忽略。

原生 Go 清理和系统调用本身并未因此变成零耗时。3.2 秒是确认等待的预算，不是实测关闭耗时承诺；失败会释放加载态并提示重试，不伪装成断开成功。

## 状态恢复与诊断

动态公共事件在应用后台可能延迟送达，不能将缺少启动事件直接等同于启动失败。启动事件超时后，有限次数核对控制器、TUN 配置和系统 VPN 网络；显式启动错误仍按失败处理。依据：[动态公共事件订阅约束](https://raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/basic-services/common-event/common-event-subscription.md)。

回到前台时查询当前会话状态、核对实际网络并恢复数据推送。单次 WebSocket/HTTP 失败不再直接清除 VPN 连接标志；无法确认时提示状态待确认。控制器可访问但系统 VPN 已消失时，不把缓存的 TUN 配置当作仍在代理的证明。所有异步刷新保留会话与代次校验，断开后的旧响应不能重新点亮状态。

[RuntimeDiagnostics](../entry/src/main/ets/services/RuntimeDiagnostics.ets) 在应用私有目录分开记录 UI 和 VPN 生命周期，每个文件最多 40 条。内容限前后台切换、阶段及耗时、取消/错误/退出原因码、内存压力和销毁来源，不保存订阅、节点凭据或配置内容。日志读取/写入失败不阻断 VPN 操作。

打开“工具 → 日志”，点击“刷新后台记录”查看，导出日志会带上这些记录。退出原因码来自 UIAbility 的 LaunchParam，不能单独代替 VPN 扩展的原生崩溃栈。

## 本机验证

- `background-lifecycle.test.mjs`：执行实际后台服务、控制通道、SDK 包装、诊断存储及页面方法。覆盖任务去重、真实流量及通知节流、取消原因、尊重用户取消、启动/停止竞争、通知释放顺序、命令边界、迟到订阅清理、事件丢失与系统网络兜底、快速重连、前台恢复和过期刷新。
- `vpn-disconnect.test.mjs`：实际扩展入口、旧会话隔离、重复停止、路由确认早于原生完成、迟到清理不停止新实例、SDK 超时及 UI 加载态恢复。
- `runtime-push.test.mjs`：增加启动事件丢失时的就绪核对；明确失败不被兜底掩盖。
- 订阅兼容性、UI 工作流、异步桥接和原 app-flow 回归通过。
- HarmonyOS debug 编译及签名成功，12.966 秒；ARM64 包内容和预编译内核打包检查通过。Go 内核二进制保持不变。

安装包：`entry/build/default/outputs/default/entry-default-signed.hap`。

```text
SHA256: 54e2bc1c378c617c1a33892a1649731d04b330eb97937729884ff64948566cc1
```

打包检查证据：`artifacts/background-lifecycle-hap/`，该目录被 Git 忽略。

上述为本机代码与构建验证，尚未完成本轮真机安装和后台稳定性验收。

## 真机复测

1. 用 DevEco 的 Run 覆盖安装，保留订阅。连接后确认系统 VPN 图标及后台任务通知出现。
2. 切到 Google / YouTube 连续使用至少 15 分钟，再锁屏、恢复使用；记录是否需要重新打开应用才能恢复访问。
3. 回到应用，断开，核对按钮、系统 VPN 图标和正常网络恢复；接着快速连接、断开一次。
4. 如再断开，在“工具 → 日志”刷新并导出记录，结合断开时间核对后台任务取消原因、退出码和 VPN 最后阶段。长时间无流量的空闲测试应另做，不能与持续传输结果混用。
