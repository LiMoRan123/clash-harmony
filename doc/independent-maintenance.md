# 独立维护仓库建议

日期：2026-10-29。

目前功能方向、界面和通信实现已形成自己的版本，适合以自己的路线维护。GitHub 的 fork 关联不要求我们持续合并作者的 main；独立维护可以先实施，解除平台关联是另一个决定。

## 当前本地状态

- `origin` 指向 `LiMoRan123/clash-harmony`。
- `upstream` 指向 `andycaihello/clash-harmony`。
- 原始开发基线为 `c0994b2`；本轮代码、测试和文档在 `dev` 整理提交，具体提交以 Git 日志为准。
- 用户已授权转为独立仓库，并按“解绑 → 推送 dev → 合并 main → 推送 main”的顺序处理。
- 当前执行环境访问 GitHub 失败：API 代理连接被拒绝，HTTPS 显式使用 7890 也无法连接，SSH 无法解析域名，且没有可用浏览器会话。因此平台解绑、远端推送及后续 main 合并仍需在 GitHub 网络访问恢复后继续。保留现有本地 remote，以免将删除别名误报为平台解绑。

## 建议顺序

1. 先把当前代码、测试和文档整理成可回滚的提交。审阅时排除本机签名与开发机配置，保留它们在本机；不要给尚未包含改造的旧提交打“当前稳定版”标签。
2. 后续使用自己的 `dev` 开发、`main` 保存通过验证的版本，并在需要时标记版本。
3. 上游作为按需参考来源；必要的修复可单独评估和移植，不必反复整仓合并。
4. 需要去掉 GitHub 的 fork 标记时，再办理平台解绑；保留原有 Git 提交历史及项目来源说明。

## 平台关联与本地 remote

`git remote remove upstream` 只删除本地远端别名，不会解除 GitHub 的 fork 关系。保留该 remote 也不会自动合并上游代码。

GitHub 提供 Settings → General → Danger Zone → Leave fork network；自助入口要求公开仓库、小于 1GB 且没有子 fork。其官方说明指出：Git 提交元数据保留，Issues、PR 等平台元数据不保留，离开后无法重新加入原 fork 网络。因此正式操作前应核对仓库条件和需要保存的数据。[GitHub 官方说明](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/detaching-a-fork)

另一个选择是新建独立仓库并迁入完整 Git 历史，将原 fork 留作档案。具体仓库名、是否保留当前仓库地址及站点数据，应在正式迁移前确定。

独立仓库继续保留现有 [GPL-3.0 许可证](../LICENSE)、[第三方声明](../THIRD_PARTY_NOTICES.md) 和原项目来源；平台是否标为 fork 不改变这些代码的来源。
