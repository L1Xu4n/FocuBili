# Apple 播放会话修复与验证

本次实现修复已由静态分析和合成测试证明的会话边界缺口。用户的真实 macOS 请求尚未在云端复现；不能承诺此修复会消除其 412，也不能将旧版同样失败认定为 1.8 新回归。最初调查和 PiliPlus 固定源码对照见 [调查报告](macos-playurl-412-2026-10-18.md)。

## 实现范围

* Apple 原生会话按固定官方 API 路径、域、有效期筛选 Cookie。身份字段以完整 scope 为组，冲突或部分身份明确拒绝；读、替换、清除串行，避免读取半次导入。
* Dart 捕获登录代次并等待账号写操作；原生同时观察 WK 身份变化。nav、playurl、源发布及媒体 open/play/备用线路均校验会话，过时结果不能激活或覆盖新播放。校验异常停止旧媒体，新打开操作等待该停流完成。
* 成功官方 HTTPS 响应中允许的服务器设备 Cookie 进入同代次内存 jar，后续 API 请求可使用；不写回共享 WK 容器，避免旧响应与网页换账号产生竞态。同 scope 网页更新优先，删除和到期不会复活旧值。进程结束后此响应 jar 不保留；WK 登录持久化仍由原容器负责。
* HTTP 状态、业务 code、实际 WBI 状态、端点、会话来源及设备 Cookie 存在性以白名单记录。错误正文及任意请求值均不记录。HTTP 412 立即停止，无自动重试、匿名回退或端点切换。
* Android 原生 1.7.1 会话/高清实现不改。普通视频参数、UA、Referer、Origin、WBI 算法及账号只读策略不改。此 master 回补未包含 dev 的课程或其他 1.9 功能；此次新会话协议覆盖普通 UGC。

## 证据与测试边界

* `test/desktop_playback_412_regression_test.dart`：20 项无 socket HTTP/通道测试，覆盖 HTTP 412、200/-412、nav 拒绝、实际签名事实、无敏感正文、Apple nav 响应 Cookie 同代次传递、换账号丢弃及 fail-closed。
* `test/windows_playback_session_boundary_test.dart`：9 项媒体替身测试，覆盖暂停/open 中换会话、恢复播放校验、post-play 超时/平台异常停流、迟到 stop 与新 open 顺序、旧 fallback 校验异常不覆盖新播放、校验中暂停及迟到 play 保持暂停。
* `tool/bilibili_session_probe.swift`：真实 Swift/WK API 编译；合成 store 验证域/路径/冲突/半事务/删除/到期/外部刷新/merge 中换账号。单独固定 bundle 身份的 App 两进程验证 WK 登录 Cookie 写入后恢复，探针只允许干净 CI 环境，不使用用户容器。
* macOS 原生 CI [39125019443](https://github.com/L1Xu4n/FocuBili/actions/runs/39125019443) 在 `c0b387f5cbc1eff48c4da94c39711fd89179a54b` 通过全部原生策略及跨进程持久化探针。更早无 bundle 身份的 CLI 持久化探针失败，已保留失败记录；它不构成产品容器持久化失败的证据。发布前还需最终 SHA 的完整 CI。
* Linux Flutter 完整套件在上一修订通过 1623 项（2 skipped）；新增全部 29 项专项回归及 analyze 通过。最终提交的完整套件由 CI 重新执行。
* 独立只读审查已核对原生异常停流、迟到回调、Cookie overlay、工作流权限；最终真实 Apple 构建结果仍为发布门槛。

不曾对 B 站发送真实 API 请求；所有会话和媒体 URL 均为合成测试数据。尚待真实 Mac 使用脱敏诊断确认：412 位于哪个端点、HTTP 或业务层，PiliPlus 是否使用同设备/网络/播放账号，以及实际登录会话是否稳定。仅需这些事实，不需要 Cookie、令牌、账号 ID、IP 或 HAR。

## 发布约束

修复先通过 dev PR；仅该修复及必要的 1.8 版本/构建验证再回补 master。不得把整个 dev 的 1.9 功能并入 1.8；不得移动 `v1.8.0` 标签。若制作替换 Mac 包，版本必须提升构建号、写入真实构建时间/源码，核对签名、架构和包内元数据，并保留旧 Mac 资产及校验值。其他平台资产和 `v1.9.0-beta.1` 草稿保持原状。


## 1.8 回补构建说明

本分支版本为 `1.8.0+27`，由 dev 修复逐提交回补，并适配 1.8 的普通视频播放器；不整体合并 dev。新增会话校验的 await 会扩大播放意图竞态，因此回补同时保留“校验期间暂停”和“迟到 play 后暂停”的必要边界，两个合成回归在修复前均失败、修复后通过。

受控 `macos-hotfix.yml` 仅接受 master 中的精确源码 SHA 和不变的原始 v1.8.0 标签，只有读取仓库和构建 Artifact 的权限，不直接操作 Release。`macos_build_identity.py` 将与 Dart 相同的源码/UTC 构建时间写入签名前 plist；DMG 验证要求 `1.8.0+27`、双架构主程序、正常 App 与 DMG 完全相同、有效 ad-hoc 签名及沙箱网络权限。此包沿用项目现有 ad-hoc 签名，不是 Developer ID 公证包。

原 Mac build26 包备份 SHA-256：`11fa18ee8beb04a45fd1aa2931d67b4be8d67f9120a91759ef11e5cbc8d7afc7`，原资产 ID `652740760`。替换应先上传并下载验证新候选，再将旧资产改为保留的 build26 备份名，最后让新候选使用原下载文件名；失败时恢复旧名称。其他平台资产、v1.8.0 标签及 1.9 Beta 草稿均不得改变。
