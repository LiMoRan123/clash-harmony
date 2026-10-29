# 独立维护与分支约定

更新日期：2026-10-29。

当前维护仓库为 [LiMoRan123/clash-harmony](https://github.com/LiMoRan123/clash-harmony)，后续按本仓库的功能方向开发。项目源自 [andycaihello/clash-harmony](https://github.com/andycaihello/clash-harmony)，保留原始 Git 历史、项目来源、许可证及第三方声明。

## 本次整理记录

- 原始开发基线为 `c0994b2`，完整功能改造整理为 `421b1e9`（`feat: establish independently maintained HarmonyOS client`）。
- 用户通过 IDEA 推送 `dev`，本地将 `main` 快进合并到同一提交，再由用户推送 `main`。
- 2026-10-29 本地核对时，`dev`、`main`、`origin/dev` 和 `origin/main` 均指向 `421b1e9`；`origin/main` 的 reflog 记录推送时间为当天 11:12:24（+08:00）。后续提交以实际 Git 日志为准。
- 用户确认在推送后完成 GitHub 平台解绑。当前执行环境未能在线读取 GitHub 的 fork 属性，平台解绑结论依据用户的实际操作反馈；本地分支和推送记录已单独核对。

先推送再离开 fork 网络不会改变这些 Git 提交。解绑后仓库继续使用现有地址，后续按自己的分支流程维护即可。

## 日常分支流程

`dev` 用于日常开发，`main` 保存通过验证的版本。以一次功能改动为例：

```bash
git switch dev
# 修改代码并完成对应验证，按文件选择要提交的内容
git add path/to/changed-file
git commit -m "feat: describe the change"
git push origin dev

git switch main
git merge --ff-only dev
git push origin main
git switch dev
```

如果 `--ff-only` 提示分支分叉，先检查双方提交并解决差异；不要为省略处理而直接强推覆盖历史。

本机签名与开发机配置按文件审阅后排除，避免将签名密码、证书、密钥或个人订阅上传。本次整理未提交本机的 `build-profile.json5` 和 `.clangd` 改动。

## 远端与原项目

- `origin` 指向当前维护仓库 `LiMoRan123/clash-harmony`。
- 本地仍保留 `upstream` 指向原项目，仅作为来源和按需修复参考；它不会自动同步或合并代码。
- 不要求定期合并作者的 main。需要借鉴某个修复时，先审查提交和依赖，再按实际情况移植并验证。

`git remote remove upstream` 只删除本地远端别名，不影响 GitHub 的 fork 关系；反过来，GitHub 平台解绑也不会自动删除本地 remote。是否保留这个参考地址与独立维护没有冲突。

GitHub 的平台操作说明见 [Detaching a fork](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/detaching-a-fork)。解绑不改变代码来源，继续保留现有 [GPL-3.0-only 许可证](../LICENSE)、[第三方声明](../THIRD_PARTY_NOTICES.md) 及原作者署名。
