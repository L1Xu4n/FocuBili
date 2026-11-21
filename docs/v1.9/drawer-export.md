# 首页抽屉与统一导出

状态：实现与定向自动化通过；尚未真机验收。最终 1.8 基线整合后需重跑回归。

## 首页抽屉（#50）

- 使用关闭、半开、全开三个吸附位置。快速手势最多从起点跨一档，不会从关闭直接滑到底。
- 卡片区的内部滚动通知不参与首页吸附。从较深的卡片列表快速下滑，先停在全开边界，需要下一次手势才收起。
- 仅对可动画的竖向首页启用；大字体导致首屏超高时保持自然滚动。布局编辑、程序定位不触发吸附。
- 证据：`home_drawer_scroll_physics_test.dart` 6 项；`home_drawer_gesture_test.dart` 1 项真实 Flutter 手势；原 `home_customization_test.dart` 和 `focus_dashboard_test.dart` 回归通过。

人工测试：手机首页连续快速上滑，应先半开、再全开；反向依次收回。滚动卡片深处后快速下滑应先停在卡片区顶端。拖动排序、卡片内列表、大字体和横竖屏切换时，确认不会抢走手势或跳回顶部。

## 统一导出

入口：设置 → 账号与隐私 → 统一导出，也可搜索“统一导出”。

- 所选本机资料生成 ZIP：设置与筛选、时间点笔记/截图（JSON 与 Markdown）、学习清单/专注、本地收藏、观看/搜索/可读取进度、焦点订阅与已载入历史、有效已载入字幕（JSON/SRT/TXT）、离线视频目录信息、脱敏问题诊断。
- 精确存储键白名单；不读取登录服务、CookieStore 或 secure storage，不发网络请求。未知键默认排除。订阅来源生命周期 token、后台租约和原始字幕地址不会导出。
- 字幕只覆盖本次运行仍在有效缓存中的条目，空缓存明确提示。视频媒体不打包，继续通过原离线视频入口导出。资料包用于阅读和存档，不声称可一键恢复全部状态。
- 用户取消保存返回“已取消保存”；文件保存失败展示脱敏的平台/阶段/错误码，不误报成功。共用 `LocalExportService`，桌面由插件保存后验证文件存在和长度，移动平台不把 content URI 当文件路径处理。
- 自动化只使用合成 SharedPreferences、合成笔记/截图、合成订阅与字幕，没有导出用户真实资料或凭据。

验证命令（本机 Windows / Flutter）：

```powershell
flutter test --no-pub test/unified_export_service_test.dart
# 12 passed：白名单、旧/新学习数据原样保留、所选范围、笔记截图、字幕过期清理、SRT/TXT、订阅运行信息排除、损坏笔记与读取失败阻断、缺图告知、真实课堂存储键、重复ID拒绝。

flutter test --no-pub test/unified_export_page_test.dart
# 2 passed：空选择禁用、取消无成功提示、失败脱敏。

flutter test --no-pub test/home_drawer_gesture_test.dart test/home_drawer_scroll_physics_test.dart test/cached_player_overlay_service_test.dart
# 已在组合20项定向套件中通过；最终集成报告单列最终命令与结果。

flutter test --no-pub --dart-define=V19_CAPTURE_DIR=docs/v1.9/screenshots test/v19_export_visual_test.dart
# 3 passed：430px、1280px深色、320px/160%字号；截图已经目视检查。
```

截图为真实 Flutter 夹具渲染，不是设计稿，也不是设备截图。

人工测试：在 Android/Windows 各选择一个新文件位置导出并解压，核对所选资料与截图；取消保存应不显示成功。导出已载入字幕，确认 SRT 与 TXT 时间轴及中文正常；清理字幕缓存后应提示暂无已载入字幕。iOS/macOS/Linux 系统保存对话框仍需对应设备验收。不要将包含个人资料的资料包上传到公开 issue。

Android 原生播放器独立存储的逐 P 进度现已通过窄只读接口补齐，勾选历史时附带 `native_playback_progress.json`，不通过通用 SharedPreferences 扫描。它保留已提交快照中的各 CID、最后分 P、旧格式及合法 BV 前缀写法；坏记录或读取失败阻断整包，不改写原存储。没有包含尚未落盘的位置，各服务也不是全局同一时刻快照。详细证据见 [原生进度导出](native-playback-progress-export.md)。字幕缓存失效/重启后需先重新打开字幕列表；离线媒体单独导出。


独立审查后补强：起于首屏/半开的长拖动即便越过全开边界也不能绕过吸附；iOS 弹性顶部越界从全开退到半开，不直接关闭。新增 810px 真实 Flutter 手势及 clamping/bouncing simulation 回归。统一导出严格解析笔记快照，坏 JSON、单条不兼容或重复 ID 阻断生成，避免容错浏览接口把损坏资料静默转为空/部分成功；新增读取失败回归。最新组合 16 项通过。


合并多帧模块后，统一导出已接入 missingImageCount：缺图数量只报告一次，正文、时间点与缺图位置保留。课堂进度使用真实WindowsPlaybackProgressStore生成的CHEESE:SS<season>及CID键验证；不使用不存在的cheese_ep命名。设置包含横竖屏布局，问题诊断复用既有脱敏buildCopyText。最新导出服务12项+页面2项通过；合并notes/focus/filtering后的首轮跨模块集成168项通过，尚不代替最终1.8基线整合后的全量检查。

### 导出完整性补审与修复

- 笔记导出严格拒绝坏帧、非整数CID/页码、错误类型封面和未知顶层/帧字段，避免浏览容错解析静默裁掉资料。缺失图片文件仍以明确警告及占位导出，不影响文字和时间点。
- 学习清单、专注、收藏、历史等原始白名单偏好值完整封存，不解析成空数组，损坏字符串也保留原值；这不是一键恢复承诺。
- 订阅从权威原始快照独立解析，拒绝重复source/feed/pending和异常字段；冻结已提交history IDs，缺元数据即失败。兼容limited扩容复用末页，只接受原有ID，并保留删除来源后仍在本机的孤立历史。
- 文件历史批次在导出专用读取路径先校验raw JSON，常规浏览读取不变。实际合成临时page.json夹具验证坏布尔值不能被归一化为false后悄悄导出。
- 诊断使用strictStorage读取并重新脱敏；坏JSON、混合坏行、可选字段损坏和读取失败均阻断导出。常规诊断页面保留容错，不直接封存未脱敏的坏诊断原文。
- 六套组合：flutter test --no-pub test/unified_export_service_test.dart test/unified_export_page_test.dart test/playback_request_diagnostics_test.dart test/subscription_service_test.dart test/subscription_history_page_test.dart test/problem_diagnostics_page_test.dart --reporter expanded，53 passed，exit 0。
- GPT-6.1-sol / xhigh独立只读复核确认本轮P2全部关闭，无新增确定P1/P2；真实系统保存/分享仍未验收。最终1.8基线合入后还须完整回归。

### 冷服务导出的只读边界

后续合并预检又发现，导出先调用订阅 `initialize()` 会触发旧偏好向 SQLite 迁移；容错浏览的去重结果可能在严格校验前写回，使损坏的重复记录变成“成功导出”。初始化还可能在 1.8 的七天保留策略中清理过期已读记录。

导出现在直接读取权威快照，等待已有写入后独立校验，不启动初始化、迁移、备份、后台调度或清理；没有快照时使用独立空文档。两个冷服务合成夹具在修复前均失败，修复后连同上述六套回归 **55 项通过**。它们分别核对有效旧资料和含重复/过期已读记录的资料：原偏好字节与键集合不变，SQLite 没有事务或保存，损坏资料明确拒绝导出。

最终 1.8 整合仍须检查运行期设置适配器的读取顺序，防止先读设置开关时再次调用初始化，抢先归一化订阅内容。此项未由当前针对性测试代替验收。
