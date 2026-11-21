# 1.9 Beta 3：承诺、修复与验收边界

这是 **发布候选的验收记录，不是公开发版凭据**。起点为 [dev 175f4b7](https://github.com/L1Xu4n/FocuBili/commit/175f4b76d1c56ff891ef5b90ec497f533c309d5e)。本轮首页/笔记/自选卡片分别见 [#100](https://github.com/L1Xu4n/FocuBili/pull/100)、[#99](https://github.com/L1Xu4n/FocuBili/pull/99)、[#101](https://github.com/L1Xu4n/FocuBili/pull/101)；沿用 [#91](https://github.com/L1Xu4n/FocuBili/pull/91) 的本机收藏重命名修复。下文“控件实测”指向生产 Flutter 控件注入触控、滚轮、测试数据或会话状态；这不是在实体手机或真实 B 站账号下操作。各专项用例存在交集，不叠加为总数。

## 本轮实际发现

| 场景 | 原来 | 修改后怎么验证 |
| --- | --- | --- |
| 首页快甩、持续拖动、反向下拉 | 同样上甩，Beta 2 被截在半开；上拖时欢迎区反而下沉。初版重写在列表浅处下拉越过首卡后仍弹回。 | 同一 430×900 窗口、120px/2500px/s 上甩：正式 v1.8.1 停在 898px（已进入列表）、Beta 2 停在 386px、候选停在首卡 772px。上拖 280px 时搜索区由反向下移 89.6px 变为同向上移 280px。双平台物理下均验证有意越过首卡 150px 可以收起；另有深列表惯性回滑不误关回归；慢放中点可半开。[Beta 2 与候选画面](evidence/drawer-motion/drawer-before-after.png) · [三版五阶段的实测数值](evidence/drawer-motion/measurements.json) |
| 窄屏笔记预览与另存截图 | 放大文字时七列表格的末列不可读；已损坏的图片仍能写出并报成功。 | 320×640、180% 字号下实际横拖到末列、再改写/保存正文。坏图不打开保存面板；有效截图用真实临时文件逐字节比较，保存的是原图。[修复前](evidence/notes-preview/markdown-table-before-320.png) · [修复后](evidence/notes-preview/markdown-table-scrolled-320.png)。系统选择器未实点。 |
| 收藏、关注卡片 | 本机收藏或关注分组改名后首页用旧名；远端列表超时阻塞本机配置；冷启动身份核验失败曾被当成游客，可能显示或改写游客配置。 | 按稳定 ID 和账号显示新名；已核验身份的列表请求失败仍可编辑本机入口；未知身份不可读写任何配置分区，保存前身份失效也拒写，确实未登录的访客仍能用。验证取消、重进、切号与异步返回。[同一远端故障，修复前](evidence/collection-editor/favorites-remote-failure-before.png) · [修复后](evidence/collection-editor/favorites-remote-failure-after.png)。未用真实账号。 |

## 历史 issue 对照

| 来源 | 已实现或明确承诺的范围 | 证据与剩余条件 |
| --- | --- | --- |
| [#30](https://github.com/L1Xu4n/FocuBili/issues/30)、[#56](https://github.com/L1Xu4n/FocuBili/issues/56) | 多 P/整合集加入与独立专注会话；跨视频/分 P、暂停视频和完播不重复记时。 | `focus_session_continuity_test.dart` 等回归；#30 报告者自己确认了整合集的菜单入口。未做长时间真机后台续测。 |
| [#31](https://github.com/L1Xu4n/FocuBili/issues/31)、[#53](https://github.com/L1Xu4n/FocuBili/issues/53) | v1.8.0 起已有 UP/合集订阅与可选通知、长按 1–5 倍速。 | 历史发布及订阅、播放偏好自动回归。Android/iOS 后台时机由系统决定，桌面需应用运行。不能保证准点推送。 |
| [#50](https://github.com/L1Xu4n/FocuBili/issues/50)、[#89](https://github.com/L1Xu4n/FocuBili/issues/89) | 保留半开、可关闭抽屉、卡片全隐藏后搜索不被挡；按照最新体验方向取消强制逐档。收藏/关注卡片、本机分组、字幕位置均有入口。 | 空布局→恢复单卡→搜索/点击、鼠标滚轮、辅助功能滚动、转向与大字短屏均有控件实测。分组按账号隔离，可预览导入；**真实登录账号导入、实体手机触感和帧率未复测**。 |
| [#58](https://github.com/L1Xu4n/FocuBili/issues/58) | 有权限的已购课堂链接、列表、续播、笔记。 | 本候选有合成课程与权限测试。另有[报告者使用官方 Beta 1、三星 Tab S9 / Android 16 的真机记录](https://github.com/L1Xu4n/FocuBili/issues/58#issuecomment-6251138527)：实测付费章节、进度恢复、笔记、未购拒绝。此为历史真机证据，不标成 Beta 3 当前实测，桌面亦未用已购账号复验。 |
| [#60](https://github.com/L1Xu4n/FocuBili/issues/60)、[#61](https://github.com/L1Xu4n/FocuBili/issues/61) | 分区/关键词与黑名单；清单一级文件夹；已有字幕列表、搜索、跳转与导出；多帧笔记可导出 Markdown/JSON。 | 有 `search_content_filter_test.dart`、`player_blocklist_test.dart`、字幕/笔记导出回归。本地规则不是 AI 语义搜索；[原报告者后来确认可以导出](https://github.com/L1Xu4n/FocuBili/issues/61#issuecomment-6537803935)，原故障的设备环境和根因仍未确认，不宣称已定位一个 Mac 故障。 |
| [#62](https://github.com/L1Xu4n/FocuBili/issues/62)、[#74](https://github.com/L1Xu4n/FocuBili/issues/74) | A–B 循环与可收起的紧凑面板，保留 A 点草稿。 | `ab_repeat_capture_lifecycle_test.dart`、`player_ab_repeat_test.dart` 等；真机无缝精度、耳机/锁屏不由这些测试证明。 |
| [#75](https://github.com/L1Xu4n/FocuBili/issues/75) | 界面文字可设为 80–200%，叠加系统字号。 | v1.8.1 发布记录、`app_text_scale_test.dart`，本次另有放大字体的抽屉和笔记测试；不等于所有页面所有字号均人工验收。 |
| [#80](https://github.com/L1Xu4n/FocuBili/issues/80)、[#81](https://github.com/L1Xu4n/FocuBili/issues/81) | macOS 播放器软件音量/静音；分 P、合集、收藏或清单播放队列及循环。 | 播放偏好与 `player_playlist_test.dart` 等；报告者的 Mac mini 外接音响、Android 真实合集连续播放尚未在候选复测。 |
| [#82](https://github.com/L1Xu4n/FocuBili/issues/82) | Linux DEB 按所含 ELF 实际依赖生成，不硬编码无关版本库。 | [Linux 兼容说明](../LINUX_PLATFORMS.md) 与 [Beta 2 发布记录](../RELEASE_NOTES_v1.9.0-beta.2.md)：有 24.04 安装运行、26.04.1 依赖解析；后者不是 26.04 原生图形安装。不要外推至 22.04。 |
| [#87](https://github.com/L1Xu4n/FocuBili/issues/87)、[#88](https://github.com/L1Xu4n/FocuBili/issues/88) | Android 夜间自适应/单色图标资源；可选线路与优先顺序。 | `python3 tool/check_platform_icons.py` 校验资源；`playback_route_policy_test.dart` 等验证回退策略。**ColorOS 15 桌面深色图标和报告者的校园网回放均未复验**。 |
| [#97](https://github.com/L1Xu4n/FocuBili/issues/97)、[#98](https://github.com/L1Xu4n/FocuBili/issues/98) | 笔记 Markdown、长按保存截图；位置/字号/透明度；默认自动字幕及 CC 中文/AI 中文/站点顺序三种优先级。 | 笔记专项 37 项，字幕相关套件 77+26 项，含回退、手动覆盖、换 P/来源。**自动字幕面向有现成轨道的普通在线视频，不涵盖独立课堂来源、本地视频，不生成字幕**。原生选择器和真实视频/网络端到端仍待测。 |

**不计入完成：** [#59](https://github.com/L1Xu4n/FocuBili/issues/59) 的主动生成字幕、评论区并未承诺在本版实现；[#78](https://github.com/L1Xu4n/FocuBili/issues/78)、[#79](https://github.com/L1Xu4n/FocuBili/issues/79) 在 Beta 2 发布范围中明确排除，本轮也未整包实现。新反馈 [#93](https://github.com/L1Xu4n/FocuBili/issues/93)–[#96](https://github.com/L1Xu4n/FocuBili/issues/96) 与上述已承诺项目分开跟踪；例如日间图标不是 #87 的 ColorOS 夜间问题，Android 插拔鼠标退回首页也不是滚轮测试能证实已修复的现象。

## 本轮验收方式

Linux Flutter 3.47.5 的控件/物理测试使用合成视频、配置和身份；未向 B 站改写数据。独立审核复跑了旧实现的关键失败用例，再用最终代码复测；笔记、抽屉、收藏卡片在上述范围内无剩余高优问题。本地验收所用的 Flutter 会自行调整五个传递依赖，这些本地改动**没有提交**。托管 CI 按仓库锁定 SDK 单独运行。是否已发版请只以 GitHub 正式的预发布条目、对应 SHA 与签名产物为准。
