# 订阅流量与到期信息

日期：2026-10-29。分支：dev。

用户反馈 FlClash 中能看到流量与到期信息，而本项目配置页没有显示。原因是原订阅下载流程只保存正文，未读取响应头；旧 `traffic` 字段保存的是 YAML 文件大小，不能当作账号使用流量。

## 数据来源与显示

本轮读取服务商返回的 `Subscription-Userinfo` 响应头，格式为：

```text
upload=<上传字节>; download=<下载字节>; total=<总额度字节>; expire=<Unix秒时间戳>
```

这一做法与 [FlClash v0.9.2 的配置模型](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/models/profile.dart) 使用的字段一致。

- 已用流量为上传与下载之和，剩余流量为总额度减去已用，使用 1024 进位显示 B/KB/MB/GB/TB/PB。
- 已用达到或超过额度时显示“额度已用尽”，进度条上限为 100%，不显示负剩余额度。
- 到期时间按设备本地日期显示；已到期使用明确文案与错误色。时间戳单位为秒。
- 缺少字段保持未知，不把缺失上传计成零，也不把零额度或零到期时间解释成无限流量、永久有效。
- 尚未用新版本查询过的旧配置提示更新订阅；查询后没有有效信息则显示“服务商未提供有效的流量与到期信息”。
- 信息来自服务商的账号累计统计，可能包含其他客户端使用量；它不是本机 VPN 的实时流量。配置页说明数据随订阅更新，不增加流量查询轮询。

配置卡片增加已用/总量/剩余、额度进度条和到期信息。本地配置不显示远程账号额度。缺少信息不阻止更新与连接，到期或额度耗尽也仅作提示，实际可用性由服务商决定。

## 保存与兼容

- `ClashProfile` 增加可选的 `subscriptionInfo` 和 `subscriptionInfoCheckedAt`，旧配置无需手动迁移。
- 响应头名称及字段名称不区分大小写，支持头值数组、JSON 序列化头和合并头的分隔形式。
- 仅保存有效的数值字段；未知字段、非法值、负数、溢出和无效日期忽略，不存储完整响应头。
- HTTP 失败或配置内容校验失败时保留原有文件与缓存统计。成功更新但服务商不再返回统计时，清除旧统计，避免将过期信息当作新返回的数据。
- 配置持久化、编辑后的原配置对象以及完整备份/恢复继续携带统计。备份格式仍为版本 1，新增字段可选，旧备份可恢复；本地配置忽略账号统计。

## 实现

- [SubscriptionInfoService](../entry/src/main/ets/services/SubscriptionInfoService.ets)：响应头解析、数值归一化、额度和到期显示。
- [SubscriptionService](../entry/src/main/ets/services/SubscriptionService.ets)：接入订阅 HTTP 响应头。
- [ProfileStore](../entry/src/main/ets/services/ProfileStore.ets) 与 [AppBackupService](../entry/src/main/ets/services/AppBackupService.ets)：保存、载入与迁移。
- [SubscriptionDetails](../entry/src/main/ets/components/SubscriptionDetails.ets)：配置行中的统计组件；由实际 [ProfileCards](../entry/src/main/ets/components/ProfileCards.ets) 使用。

## 验证与使用

- `subscription-info.test.mjs`：实际服务代码的响应头变体、有效零值、部分字段、非法/缺失字段、账号累计流量、剩余额度、超额和 Unix 到期时间。
- `subscription-compat.test.mjs`：23 项通过，新增真实订阅服务与持久化的统计保存、失败保留及成功无统计时清理旧数据。
- `ui-workflows.test.mjs`：增加备份/恢复携带统计与旧备份兼容验证。
- 更新反馈、app-flow、运行推送、断开和后台生命周期回归通过。
- HarmonyOS debug 签名构建通过，ARM64 安装包内容与内核打包检查通过；没有更换 Go 内核或新增后台统计请求。

用 DevEco **Run** 覆盖安装后，在配置页更新一次订阅，才会取得服务器返回的信息。本轮未直接读取真机订阅或抓取用户响应头，真实服务商的返回情况需安装后确认。

安装包：[entry-default-signed.hap](../entry/build/default/outputs/default/entry-default-signed.hap)。

```text
SHA256: 22340a51f8f47231afae6550f7b4faca5c95240e2ce0f8b7b69a773d6561d544
```

构建耗时：13.334 秒。打包证据：`artifacts/subscription-info-hap/`，被 Git 忽略。
