# FlClash 0.9.2 风格的 ArkUI 界面改造

日期：2026-10-28。分支：dev。

本文记录第一轮整体改造。2026-10-29 的紧凑布局、配置更新动画、逐项结果和最新安装包见 [界面细化与更新反馈](ui-polish.md)。

本轮按用户要求直接改造整套实际应用界面，性能专项优化后置。参考版本为 [FlClash v0.9.2](https://github.com/chen08209/FlClash/tree/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7)，参考了该版本的官方预览图与 dashboard、proxies、profiles、tools、theme 页面结构。应用保留 Clash Harmony 名称与标识，使用 ArkTS/ArkUI 实现，不引入 Flutter。

## 1 已改造的页面与交互

| 页面 | 实际接入的内容 |
| --- | --- |
| 仪表盘 | 运行状态卡片、VPN 启停、运行时间、活跃连接、实时上传/下载和近期样本图、出站模式、当前配置与代理策略入口 |
| 出口检测 | 用户主动点击后通过本机 7890 代理请求出口 IP，显示实际返回值；未检测时不展示虚构地址或归属地 |
| 代理 | 规则/全局/直连模式、横向策略组、搜索、同步、测速进度、单列/双列节点、原始/名称/延迟排序与选中状态 |
| 配置 | 添加链接、系统粘贴按钮、选择文件、配置卡片、启用/更新、编辑本地 YAML 和名称、复制订阅链接、导出 YAML、删除确认 |
| 工具 | 实时连接、应用运行记录、分流规则、DNS，以及外观、网络、测速、备份、关于等入口 |
| 外观 | 跟随系统、浅色、深色；节点布局与排序。设置保存在本机并在下次打开时恢复 |
| 网络 | IPv6、允许局域网、DNS redir-host/fake-ip、日志等级；真实写入下次生成的运行配置 |
| 测速设置 | 首选测试地址和 3/4.5/8/10 秒超时，实际用于节点检测，失败时尝试备用地址 |
| 备份与恢复 | 使用系统文件选择器导出完整配置内容与偏好；恢复时验证全部配置、重建本机文件路径并恢复当前配置选择 |
| 关于 | 版本、实际内核版本、许可与源码链接 |

底部导航调整为“仪表盘 / 代理 / 配置 / 工具”，使用统一矢量图标与圆角选中状态。原先设置中写死的备份时间与示意开关已从实际页面移除。原生桥接、FD 等信息收进高级诊断。

REJECT / REJECT-DROP 显示为拒绝连接策略，跳过节点延迟测试，不再把这类内置策略按普通服务器统计为超时。

## 2 样式与实现位置

- [Index.ets](../entry/src/main/ets/pages/Index.ets)：实际应用入口及各页面、弹层、菜单和交互。
- [AppTheme.ets](../entry/src/main/ets/theme/AppTheme.ets)：语义化颜色引用。
- [浅色颜色](../entry/src/main/resources/base/element/color.json) 与 [深色颜色](../entry/src/main/resources/dark/element/color.json)：Material 色调、紫色主色、圆角卡片和明暗层级。
- base/media/ui_*.svg：本轮新增的统一单色矢量图标，不使用字母或 emoji 充当导航图标。
- [AppPreferencesService.ets](../entry/src/main/ets/services/AppPreferencesService.ets)：偏好读取、校验与持久化。
- [DocumentExportService.ets](../entry/src/main/ets/services/DocumentExportService.ets)：系统文件选择器导出。
- [AppBackupService.ets](../entry/src/main/ets/services/AppBackupService.ets)：包含配置文件内容的可迁移备份，不仅保存旧沙箱路径。
- [NetworkProbeService.ets](../entry/src/main/ets/services/NetworkProbeService.ets)：通过显式本机代理检测出口。
- [RuntimeConfigService.ets](../entry/src/main/ets/services/RuntimeConfigService.ets)：让网络设置实际生效；默认仍为 IPv6 关闭、局域网关闭、redir-host 与 info。

剪贴板入口使用鸿蒙 PasteButton，并在系统返回本次授权成功后调用导入逻辑。此方案不额外声明持续读取剪贴板的权限，依据 [OpenHarmony 安全粘贴按钮说明](https://github.com/openharmony/docs/blob/master/en/application-dev/security/AccessToken/pastebutton.md)。SDK 对跨服务的 getData 调用仍可能给出静态权限提示。

出口检查仅在用户点击时访问 [ipify JSON 接口](https://www.ipify.org/)，明确指定 127.0.0.1:7890，避免把应用自身直连出口误当作代理出口；实际可达性与分流规则仍需真机确认。

## 3 功能覆盖边界

本轮完成现有鸿蒙客户端整套界面与上述交互的替换，不等于已经移植 FlClash 的全部平台能力。以下能力没有以可用开关或虚假数据的形式展示：

- WebDAV 云备份、二维码/相机扫描、按应用代理。
- 出口国家、运营商、IP 质量评分与外部服务可用性面板。
- FlClash 的脚本运行、可视化覆写、资源提供者管理与 DNS 查询/请求历史流。
- 桌面系统代理、托盘、快捷键和 Android 专属系统入口。

本地 YAML 编辑可以修改配置内容，但没有包装成上述尚未实现的可视化管理器。工具中的应用运行记录仍是本应用记录的操作日志，不等同于 Mihomo 全量实时日志。

本轮没有进行刷新频率、线程采样、列表复用或渲染性能专项优化。既有异步核心启停修复继续保留；订阅和 VPN 主链路也保留。

用户随后授权性能优化，已另实施首页状态拆分、事件与 WebSocket 推送、异步 TUN 启动，见 [运行状态推送与性能记录](runtime-push-and-performance.md)。

## 4 验证与真机复测

本轮使用 [ui-workflows.test.mjs](../tests/ui-workflows.test.mjs) 执行实际 ArkTS 服务和提取的实际页面方法，覆盖：

- 偏好保存、恢复与非法值回退。
- 网络选项实际写入运行 YAML，控制器继续限制为本机地址。
- 完整文件内容备份、恢复后的新沙箱路径、远程来源与当前选择。
- 非法备份和配置文件写入失败时保留原有配置元数据。
- 文件导出取消、失败时句柄释放。
- 节点排序不修改控制器原顺序，搜索和测试地址/超时选项实际生效。
- 拒绝策略不参与测速；出口检测使用本机代理并处理错误和资源释放。

同时执行订阅 21 项、app-flow 和异步桥接回归。颜色资源中正文、次要文字、按钮和状态配色在明暗主题下的抽样对比度均超过 4.5:1；该检查不替代真机视觉验收。

最终构建与打包结果见文末。本轮没有直接读取或操作真机页面：当前执行环境无法访问 HDC server，也没有可用浏览器或原生 UI 预览表面。因此不将编译通过表述为已完成真机逐页截图、横竖屏或最大字体适配验收。

使用 DevEco Run 覆盖安装即可保留已有订阅。复测顺序建议为：仪表盘连接与断开、代理选择与测速、配置菜单及导入弹层、工具和设置、明暗主题。备份恢复会替换配置列表，应用会在恢复前显示确认。

## 5 最终构建记录

以下为 UI 改造首次完成时的记录。后续断开加载问题的修复和更新安装包见 [VPN 断开修复记录](vpn-disconnect.md)。

- HarmonyOS debug 编译与签名成功，最终一次构建约 15.6 秒。
- 新增 UI 工作流回归、原有 app-flow、订阅 21 项、异步桥接回归均通过。
- ARM64 HAP 内容与 mihomo 预编译库打包检查通过。x86_64 仍按原项目配置使用 fake adapter，不代表模拟器具有真实核心。
- git diff --check 通过。用户的 build-profile.json5 签名与 .clangd 修改保留。
- 证据位于被 Git 忽略的 artifacts/ui-redesign-hap/。

安装包：[entry-default-signed.hap](../entry/build/default/outputs/default/entry-default-signed.hap)。

SHA256：

```text
2318a4e95fa58eceebf202470ad6336e6bd08aef95885fb0cf6548d2bf0fbae2
```

重新构建或签名后，哈希可能变化。
