# 首页状态与信息增强

日期：2026-10-29。开发分支：`dev`。

用户反馈启停按钮在连接前后样式相同、出口 IP 需要手动查询、首页信息偏少，并提供 FlClash 电脑端截图作为信息布局参考。本轮按手机宽度整理为状态、流量、模式、当前配置、代理策略和服务状态，继续使用 ArkUI 原生组件及现有明暗主题。

## 状态与按钮

| 状态 | 按钮与反馈 |
| --- | --- |
| 未连接 | 浅底描边圆形按钮、三角播放图标、“点击连接”文字，状态标签显示未连接 |
| 连接中 | 原生加载动画、启动阶段文字，按钮暂不可重复操作 |
| 已连接 | 主题实色圆形按钮、暂停图标、“点击断开”文字，状态标签显示运行中 |
| 断开中 | 原生加载动画与正在断开提示，完成后恢复播放按钮 |

主按钮为 72vp，保留原生按压反馈和可访问性文字。图标、文字与颜色共同表达状态。手机端继续使用一个系统 VPN 启停入口。

## 自动检测出口与服务

正常启动在恢复保存的节点选择后自动发起检测，不等待额外的节点延迟验证完成，也不把检测作为 VPN 就绪的前置条件。已有 VPN 会话被界面重新接管时也会请求自动检测；同一界面的重复状态同步不重复发起网络请求。

- 出口 IP 使用现有 ipify 接口，并显式经过本机 mihomo HTTP 代理。首页突出显示查询结果，失败时保留 VPN 连接并提示重试。
- 服务状态检查 Google、GitHub、YouTube 和 ChatGPT，使用 HEAD 请求，最多同时检查两个服务；出口检测与它们独立执行，最多同时有三个请求。
- HTTP 2xx/3xx 显示可达及本次请求耗时；其他 HTTP 响应显示响应受限及状态码，网络异常显示连接超时或失败。403 不会显示为可达。
- 请求禁用缓存，出口请求连接/读取超时各为 5 秒，服务检查各为 4 秒，并限制响应体大小。
- 切换节点、切换运行模式后重新检查；刷新按钮用于显式重试。这里没有新增周期任务或持续 HTTP 轮询。
- 断开、重新连接和界面销毁时取消未完成的 HTTP 请求；每批检测带代次校验，旧请求回调不会覆盖新会话或解除新会话的加载态。

服务状态按当前分流规则检查，耗时是完整 HTTP 请求耗时，不是节点带宽或 ICMP ping。可达也不代表账号登录、内容播放和地区解锁均可用。出口 IP 同样反映当前配置对检测地址的实际路由。

## 更多真实信息

- 上传/下载分别显示速度、累计流量、观察期间峰值和趋势线。累计来自 WebSocket 的 `uploadTotal` / `downloadTotal`，属于当前内核会话；它与订阅账号额度不同。
- 峰值由当前界面观察期间的速度样本计算，重新打开应用不能恢复此前未记录的峰值。断开及新建连接清理统计，内核累计计数回退时清理旧峰值。
- 当前配置卡显示名称、节点数、更新时间，并复用配置页的流量额度、使用进度和到期组件。服务商未提供账号统计时显示提示，不增加独立流量查询请求。
- 代理策略卡显示当前链路、策略组数量和配置节点数量，可进入代理页切换。

## 实现入口

- [HomeRuntimeCards](../entry/src/main/ets/components/HomeRuntimeCards.ets)：启停按钮、出口展示、累计与峰值。
- [HomeOverviewCards](../entry/src/main/ets/components/HomeOverviewCards.ets)：配置概览和服务状态卡。
- [HomeNetworkViewState](../entry/src/main/ets/models/HomeNetworkViewState.ets)、[HomeNetworkMonitorService](../entry/src/main/ets/services/HomeNetworkMonitorService.ets)：检测状态、单次任务、取消及代次检查。
- [NetworkProbeService](../entry/src/main/ets/services/NetworkProbeService.ets)：经过本机代理的 HTTP 请求及句柄释放。
- [HomeViewState](../entry/src/main/ets/models/HomeViewState.ets)、[Index](../entry/src/main/ets/pages/Index.ets)：流量采样与连接、恢复、模式和节点切换接入。
- [InterfacePreview](../entry/src/main/ets/preview/InterfacePreview.ets)：360vp 运行/未连接预览，使用演示数据，不访问网络。

## 验证与真机检查

新增 [home-dashboard.test.mjs](../tests/home-dashboard.test.mjs)，执行实际服务、状态模型和连接后处理代码，覆盖自动触发、有限并发、代理设置、HTTP 受限响应、手动重试去重、句柄释放、取消后的延迟回调、快速重连、失败退出加载、累计与峰值清理，以及恢复节点后才开始检测。既有后台恢复测试补充了只有真实 VPN 会话才触发检测的检查。

12 组 `*.test.mjs` 回归通过；HarmonyOS debug 签名构建、ARM64 HAP 内容和内核打包检查通过。浅色/深色各检查 6 组主要文字和状态颜色，均达到 4.5:1。Go 内核预编译产物未更换。

当前 HDC 返回 `Connect server failed`，未在本轮直接安装或取得实际页面截图。360vp 预览样例和颜色计算不代替手机上的布局、最大字号及横竖屏验收。

使用 DevEco **Run** 覆盖安装后，从手机桌面打开应用，检查：

1. 未连接时为三角播放，连接后为暂停，启停中有加载态。
2. 连接后自动出现出口 IP 和服务结果；断开再快速连接不会显示上次线路的结果。
3. 切换节点或运行模式后自动重查；检测失败仍可断开，刷新按钮可重试。
4. 首页累计流量、配置额度及到期与对应数据一致，深色与大字号下文字可读。

最终签名构建耗时：21.839 秒。安装包为 [entry-default-signed.hap](../entry/build/default/outputs/default/entry-default-signed.hap)，校验值：

```text
SHA256: 7c63ef13d52aded4643bb48cf2caa08253752c49fc3cddd3f9bc348667787774
```

测试日志、构建日志和 HAP 检查证据位于 `artifacts/home-dashboard/`，被 Git 忽略。本机签名与开发机配置未纳入提交。
