# 订阅兼容性修复记录

日期：2026-10-28。开发分支：`dev`。

用户反馈同一订阅在 FlClash 默认设置下可以更新，本项目却提示内容不是 Clash/Mihomo YAML。本次修复了源码中能够复现的下载协商、格式识别和更新目标错误。用户重新安装后已反馈“能正常更新并显示节点”，随后反馈 VPN 连接后可以访问 YouTube。实际订阅没有提供给本机测试，上述结果依据用户真机反馈；测速与页面流畅度仍单独验证，见 [核心启动与卡顿排查](startup-and-performance.md)。

## 1 已确认的问题与修改

| 原有行为 | 修复后的行为 |
| --- | --- |
| 下载请求不设置订阅客户端 User-Agent | 发送自己的应用身份，并携带 `clash-verge` 格式兼容标记及 YAML Accept 头 |
| Base64 解码后只尝试 Shadowsocks URI，未重新识别 YAML | 支持普通及 URL-safe Base64 YAML、缺省 padding，以及换行、空格和制表符 |
| 任意文本包含 `proxies:` 就被当作配置 | 按顶层配置键识别，网页、登录页与 JSON 响应给出不同错误 |
| 节点展示要求 `proxies:` 严格拼写且列表必须缩进 | 支持带引号和空格的章节键，以及合法的不缩进 YAML 序列 |
| 混合 SS 与其他 URI 时可能只导入 SS，丢掉其余节点 | 检测到当前不能转换的 URI 时明确报告协议，不静默丢弃节点 |
| 剪贴板和运行配置各自执行不同的格式判断 | 剪贴板文本、文件/远程导入和运行配置共用订阅转换服务 |
| 已有当前配置时，新建订阅后下载 `currentUid` 对应的旧配置 | 下载本次新增配置的 uid，保留用户原有当前配置选择 |
| 运行配置可能遗漏带引号的受管理键，并误把 DNS URL 列表当成顶层章节 | 识别带引号的受管理键，移除完整 DNS/hosts 块后生成运行参数 |

下载失败和格式失败分别报告。HTTP 403 等错误仍保留 HTTP 状态码；HTTP 成功但格式不能导入时，提示以“订阅已下载，但无法导入”开头。格式识别失败不替换已有可用配置文件或元数据。

## 2 下载请求的依据

FlClash 0.9.2 的默认 UA 包含应用版本、`clash-verge` 和平台信息，来源为 [package.dart](https://github.com/chen08209/FlClash/blob/v0.9.2/lib/common/package.dart)。订阅下载的 HTTP 客户端通过 `globalState.ua` 使用该身份，见 [request.dart](https://github.com/chen08209/FlClash/blob/v0.9.2/lib/common/request.dart) 和 [state.dart](https://github.com/chen08209/FlClash/blob/v0.9.2/lib/state.dart)。

本项目当前发送：

```http
User-Agent: ClashHarmony/v0.1.0 clash-verge Platform/ohos
Accept: application/yaml, application/x-yaml, text/yaml, text/plain, */*
```

这使根据客户端身份选择输出格式的订阅服务有机会返回 Clash 配置。用户这次订阅是否采用这种格式协商，尚未通过真实响应确认。请求头调整不代表已经实现 FlClash 的全部订阅转换能力。

## 3 当前能力边界

完整 Clash/Mihomo YAML 可直接导入；Base64 包装的 YAML 会先解码。具体代理协议能否运行由打包的 mihomo 核心及配置决定。

通用 URI 转换目前仍仅实现 Shadowsocks。对于 VMess、VLESS、Trojan、Hysteria、TUIC 等 URI 文本，本次增加的是协议识别和明确提示，未新增这些协议的通用链接转换。若服务在兼容 UA 下仍只返回此类 URI，应在订阅后台选择 Clash/Mihomo 输出，或按实际响应继续补充转换实现。

当前仍使用轻量文本提取器展示节点，不是完整 YAML 语法分析器。网页和错误响应的分类也不能代替 mihomo 的最终配置校验。

## 4 修改位置

- [SubscriptionService.ets](../entry/src/main/ets/services/SubscriptionService.ets)：请求身份、Accept 和下载/格式错误区分。
- [GenericSubscriptionConverterService.ets](../entry/src/main/ets/services/GenericSubscriptionConverterService.ets)：Base64 YAML、格式分类及协议提示。
- [ClashConfigParserService.ets](../entry/src/main/ets/services/ClashConfigParserService.ets)：节点章节和缩进兼容。
- [ClipboardImportService.ets](../entry/src/main/ets/services/ClipboardImportService.ets)：复用统一转换结果。
- [RuntimeConfigService.ets](../entry/src/main/ets/services/RuntimeConfigService.ets)：统一格式入口与受管理字段处理。
- [Index.ets](../entry/src/main/ets/pages/Index.ets)：新增订阅按新增 uid 下载。

## 5 验证结果

[subscription-compat.test.mjs](../tests/subscription-compat.test.mjs) 使用 DevEco SDK 的 TypeScript 编译并执行实际 ArkTS 服务代码，只适配文件、Preferences、剪贴板和 HTTP 平台接口。网络回归通过模拟服务器按请求头返回不同格式，未访问用户真实订阅。配置结果另外用 SDK 自带 js-yaml 解析验证。

```bash
node tests/subscription-compat.test.mjs
node tests/app-flow.test.mjs
node tests/verify-hap-contents.mjs \
  entry/build/default/outputs/default/entry-default-signed.hap \
  --require-abi arm64-v8a --evidence-dir artifacts/subscription-compat-hap
node tests/verify-mihomo-prebuilt-packaging.mjs --require-abi arm64-v8a
```

- 订阅兼容性回归：21/21 通过；最初 17 个用例在修改前仅 3 个通过。
- 原有 app-flow 回归：通过。
- HarmonyOS debug 构建及签名：通过，耗时约 14.6 秒。
- HAP 内容、native 依赖与预编译库打包检查：通过。
- 构建仍有既有的 API 废弃、剪贴板权限及文件 API 提示；本次没有修改权限声明。
- 用户真实订阅的手机复测：用户确认可以更新并显示节点，随后确认 VPN 连接后可访问 YouTube；测速稳定性与页面流畅度仍待验证。

回归测试依赖 DevEco SDK 内的 TypeScript 和 js-yaml，未给应用增加第三方运行依赖。HAP 证据保存在被 Git 忽略的 `artifacts/subscription-compat-hap/`。

## 6 手机复测

在 DevEco 使用当前本地 `dev` 工程点击 Run，覆盖安装新包；进入配置页，对已添加的同一订阅执行更新。重点核对节点是否出现、已有配置选择是否保留，以及下载失败与格式失败是否给出对应提示。若仍失败，记录新的完整错误文案即可，无需公开订阅 URL、token 或节点密码。

订阅修复首次生成包为 `entry/build/default/outputs/default/entry-default-signed.hap`，当时的 SHA256：

```text
ca3da2b13f122a49acc499b967a0a92f34632bc8a0a20d302a0c6e3a03c26860
```

重新签名或重新构建后哈希可能变化，应以实际安装文件为准。

## 7 测速时原生调试器因 SIGURG 暂停

2026-10-28 16:12:41，DevEco 的 `dap_server_20261028161200_1.log` 记录原生调试器收到 `SIGURG`，随后发送以下暂停事件：

```json
{
  "allThreadsStopped": true,
  "description": "SIGURG",
  "reason": "exception"
}
```

同一时段用户反馈点击测速后整个界面无响应，停在准备或启动测速核心。上述事件确认当时调试器暂停了整个进程。

Go 运行时将 `SIGURG` 用于异步抢占调度，见 [Go runtime 源码](https://go.dev/src/runtime/signal_unix.go)。mihomo 使用 Go 实现，因此此暂停需要先调整调试器的信号处理，再继续判断核心运行情况。

普通功能验证可停止 DevEco Debug，从手机桌面重新打开应用后再测。如果需要保持原生调试，在当前会话的 Native LLDB 控制台执行：

```text
process handle -p true -s false -n false SIGURG
continue
```

该命令把 `SIGURG` 传给程序处理，同时让 LLDB 不因该信号暂停或通知；其他信号的处理策略保持原样。参数已通过本机 DevEco SDK 的 `help process handle` 核对。此设置针对当前调试会话，后续会话可按需要配置为调试启动命令。

用户随后反馈，停止 Debug 并从桌面打开后，测速等待一段时间仍会退出，因此调试器暂停不是全部问题。源码中另已确认同步 NAPI 启动会阻塞界面；对应修改、验证和新的安装包记录见 [核心启动与卡顿排查](startup-and-performance.md)。目前没有这次退出的系统故障栈，不能确认它由界面无响应还是原生崩溃引起。
