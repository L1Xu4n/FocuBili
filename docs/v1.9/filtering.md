# v1.9：黑名单与搜索筛选（#60 / #61）

执行分支：`codex/v19-filtering`，起点 `5a49fc60288e11265eda38b1da9c7b77171a9710`（1.8beta4）。本分支只实现本地黑名单与搜索规则，由整合分支基于 1.8 final 合入；不发布、不创建 PR。

## 逐项状态

状态只使用「未做 / 实现 / 自动化通过 / 真机通过 / 阻塞」。自动化通过不代表真机通过。

| 项目 | 状态 | 证据 | 真机验收 |
| --- | --- | --- | --- |
| 搜索视频菜单屏蔽单视频，持久化 BV，立即隐藏、支持撤销 | 自动化通过 | `content_blocklist_test.dart` 的 search video menu 用例 | 未做 |
| 搜索视频菜单屏蔽 UP；解析并使用 UID，缺失时补查；同名不同 UID 不误屏蔽 | 自动化通过 | parser、concurrent service、creator menu 用例 | 未做 |
| 播放器更多菜单屏蔽视频 / UP，管理入口、重复操作不会撤销旧规则 | 自动化通过 | `player_blocklist_test.dart` | 未做 |
| 管理页列出 UP、UID、视频、BV 并逐项取消，播放器菜单能进入 | 自动化通过 | 管理页取消与播放器端到端 widget 用例 | 未做 |
| 我的与搜索筛选中提供管理入口 | 实现 | 对应 profile tile 与 search-manage-blocklist 按钮；静态检查通过 | 未做 |
| 黑名单应用于视频关键词搜索、BV 直达、用户搜索；取消后恢复已有原始结果 | 自动化通过 | persisted BV、blocked UID、菜单撤销用例 | 未做 |
| 标题 / UP 名关键词分别排除、英文大小写不敏感、字面包含匹配、分隔和去重 | 自动化通过 | title and owner terms、keyword drafts 用例 | 未做 |
| 筛选草稿应用 / 取消 / 重置，重启后保留规则 | 自动化通过 | keyword drafts、old settings、原有精确播放量保存用例 | 未做 |
| 新用户默认不限制内容；实验娱乐过滤可选，学习标题优先、未知元数据保留、不凭分区推断 | 自动化通过 | new defaults、learning rules 用例 | 未做 |
| 分区默认全部，主动选择后传入请求，重置清除分区 | 自动化通过 | category is unrestricted 用例 | 未做 |
| 过滤后连续补页、空页继续、失败停止并可重试、去重和已有分 P 补查 | 自动化通过 | `search_content_filter_test.dart`、`search_multi_part_fallback_test.dart` | 未做 |
| 小屏 / 键盘 / 关闭按钮 / 鼠标横向筛选与既有搜索学习菜单 | 自动化通过 | 搜索布局、筛选面板、用户搜索回归 | 未做 |
| 旧 v2 规则保留，并发黑名单操作无丢失，损坏黑名单拒绝覆盖 | 自动化通过 | old settings、concurrent service、unreadable storage 用例 | 未做 |
| Android / Windows / iOS 原生运行与真实接口验收 | 未做 | 本工作分支未生成真机证据；由整合分支验收 | 未做 |

## 行为与数据

- 黑名单只改变本机搜索发现结果；不会删除收藏、学习清单、观看历史、笔记或离线缓存，不会修改 B 站账号。已打开的视频继续播放；从这些用户主动保存的资料仍可打开播放器。
- BV 直达保留显式编号查询行为，遵守黑名单；标题、UP 关键词、播放量与实验规则应用于普通视频搜索，不对 BV 直达追加这些规则。
- UP 黑名单只按正整数 UID 匹配，不用显示名兜底。同名 UP 不受影响。若服务端缺 UID，屏蔽操作补查详情；补查失败显示错误，不保存错误身份。
- 实验过滤默认关闭；之前保存的 `learningOnly: true` 保留。启用后按明显娱乐词判断，学习 / 教程词优先保留，单凭音乐、游戏等分区不会屏蔽。
- 标题和 UP 排除词各自匹配对应字段；每行一个，亦接受中英文逗号 / 分号。忽略首尾空格、空词和大小写重复项；不是正则表达式。
- 隐藏计数显示总数及学习 / 黑名单命中，规则可能重叠，计数不会用相减方式产生负数。原始结果保留，取消黑名单即可恢复。

继续使用 `search.content_filter_v2`，JSON：

```json
{
  "learningOnly": false,
  "minimumPlayCount": 0,
  "titleKeywords": ["剧透"],
  "ownerKeywords": ["某工作室"]
}
```

旧数据只有前两个字段时，新增数组默认为空。未迁移或删除旧 key，也未重用已移除的全局播放量偏好。

新增 `content.blocklist_v1`，JSON：

```json
{
  "version": 1,
  "videos": {"BV1GJ411x7h7": "示例视频标题"},
  "creators": {"42": "示例 UP 名"}
}
```

BV 保留大小写；creator key 是正整数 UID 的十进制字符串，value 仅用于管理页展示。多个 service 实例串行读改写；不可解析的整份存储会报错并保留原文。保存成功才发出 `ContentBlocklistService.changes` 通知。统一导出 / 恢复应包含两个 key；恢复后若保留现有页面实例，需要递增该 notifier 或重建主框架。

## 自动化证据

平台：Windows，仓库已有 Flutter SDK：`C:\Users\L1XU4N\flutter\bin\flutter.bat`。测试全部使用 mock 偏好与服务，不读取、打印或导出真实凭据。

依赖准备：`flutter pub get --offline`，退出码 0，`Got dependencies!`。没有升级依赖。SDK 批处理在普通 sandbox 中无输出未完成，已终止，使用已授权的 `require_escalated` 运行现有 SDK，未修改 ACL。

最终回归命令：

```powershell
& 'C:\Users\L1XU4N\flutter\bin\flutter.bat' test --no-pub `
  test/content_blocklist_test.dart `
  test/player_blocklist_test.dart `
  test/search_content_filter_test.dart `
  test/search_multi_part_fallback_test.dart `
  test/search_page_layout_test.dart `
  test/user_search_test.dart `
  test/settings_search_section_test.dart `
  test/review_pr24_regression_test.dart
```

结果：35 项通过，退出码 0，`All tests passed!`。覆盖播放器真实 widget 菜单，但使用离线播放替身，不属于真机测试。

额外播放器菜单与相关行为回归：`flutter test --no-pub test/widget_test.dart --name '[字幕循环次数定时画幅]'`，54 项通过，退出码 0，`All tests passed!`。包含字幕选择 / 失败重试 / 分 P 隔离、弹幕设置、循环、次数、定时、平板画幅和大字布局。两组共 89 项通过。

静态检查：对修改的 models / services、search 目录、黑名单页、player page（含 part 文件）、profile page 和新增测试执行 `dart analyze`，退出码 0，`No issues found!`。`git diff --check` 通过。

测试驱动修正了两项真实问题：静态保存队列完成后清空，避免跨 widget 测试的异步 zone 悬挂；表单重置在回调结束后确定空草稿，并在构建完成后同步控制器，避免旧关键词回写和构建期 Form 通知。

## 人工步骤与预期

1. 在 Windows 与 Android 全新安装 / 清空测试偏好后搜索音乐、游戏、学习类视频。预期实验规则关闭、分区为全部，播放量为 0；不会自动隐藏这些分区。选择科技分区再应用，只请求该分区；重置回全部。
2. 标题排除词输入 `Spoiler，剧透`，UP 排除词输入 `STUDIO`。预期标题 `spoILER` 与 UP 名 `My Studio` 分别命中；标题中的 `studio` 不因 UP 排除词命中，输入 `C++` 按字面处理。关闭弹窗不保存，应用后重启仍保留；重置清空。
3. 视频结果更多菜单屏蔽视频。预期立即从结果消失、其他视频不变，撤销立即恢复。屏蔽 UP 后该 UID 的结果隐藏，同名不同 UID 保留；重启后仍生效。
4. 打开播放器更多菜单，分别屏蔽视频与 UP。预期本视频继续播放，回搜索后规则生效；重复屏蔽只提示已存在，不出现会删除旧规则的撤销按钮。
5. 从我的 / 搜索筛选 / 播放器进入黑名单。预期看到视频标题及 BV、UP 名及 UID；逐项取消后搜索恢复。输入已屏蔽 BV，显示屏蔽说明和管理入口；取消后原直达结果恢复。
6. 在 320–360 宽屏、横屏、键盘弹出、大字模式下检查筛选面板和黑名单页。预期关闭、应用与取消屏蔽可达，无溢出；鼠标可拖动横向筛选条。
7. 使用测试账号 / 固定 fixture 构造连续过滤页、空页、网络错误。预期仍能继续补页到符合结果或末页；错误后停止自动重试，点击重试继续。

## 风险与剩余事项

- 真机与打包安装验证未做，不能标为通过；本机 widget 测试不证明 Android 原生播放、Windows 全屏菜单或系统键盘实机行为。
- 实验规则是透明、可关闭的启发式，仍有误判风险；通过关键词或手动黑名单能更精确控制。规则不强制改写用户已保存的资料。
- 未知 UID 不按姓名推断。API 在缺 UID 时返回的视频，只有补查到 UID 后才能准确归属于 UP 黑名单；补查失败保留未知项，避免误伤同名作者。
- 未实现跨设备同步；本地数据在整合分支统一备份后可迁移。损坏黑名单显示重试，不自动清空用户数据。
