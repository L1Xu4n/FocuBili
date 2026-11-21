# 1.9 beta：笔记、多帧与已有字幕

执行分支：`codex/v19-notes-subtitles`；起点：1.8 beta4 `5a49fc6`。只在指定 worktree 修改，未发布、未创建 PR、未联系 issue 报告者。按要求使用 GPT-6.1-sol / xhigh。根目录无 AGENTS.md；已阅读 CONTRIBUTING.md。

## 状态

状态词：未做 / 实现 / 自动化通过 / 真机通过 / 阻塞。自动化运行宿主是 Windows，Flutter 3.44.6、Dart 3.12.2；注入 macOS/Android 平台的测试仍是模拟，不算对应系统真机。

| 项目 | 状态 | 证据或缺口 |
| --- | --- | --- |
| #61 原始问题复现与根因确认 | 阻塞 | 父任务已读最新 issue/comments：报告者尚未回复平台；作者 10/17 追问是否 Mac。没有复现步骤或录屏，不能认定 Mac 已复现。 |
| 导出路径、macOS 权限与依赖静态排查 | 实现 | 当前锁定 file_picker 11.0.3 的 macOS/Windows/Linux saveFile 都调用 saveBytesToFile；并非只返回路径。macOS DebugProfile/Release entitlements 已包含 user-selected.read-write。没有擅加权限或重复写文件。 |
| 通用另存为、取消和安全诊断 | 自动化通过 | LocalExportService 保留插件写入；桌面校验文件存在及长度，移动端不把 content URI 当成本机路径。错误显示平台/阶段/安全码，不显示原始详情、文件路径或会话。 |
| Linux 分享降级为保存时取消 | 自动化通过 | shareExportPackage 返回 false，笔记页保留选择；失败也展示脱敏诊断。 |
| 单条笔记多个视频帧 | 自动化通过 | 保存有序 frames，每帧独立 positionMs；追加当前画面保持原笔记锚点和原播放位置；可重排、单张移除，编辑正文不丢帧。 |
| 旧单图数据兼容与清理 | 自动化通过 | 旧 framePath 映射为笔记锚点处单张；保存和删除只清理已无任何笔记引用的帧。 |
| 详情、编辑器、全屏预览、分享长图 | 自动化通过 | 共用多帧展示，显示各张序号/时间，详情点击逐张放大，长图保留顺序及时间；缺失图显示占位。 |
| Markdown / JSON 多帧导出 | 自动化通过 | JSON version 2；完整有序帧和毫秒位置，ZIP 内相对路径；缺失图保留 unavailable 位置并返回 missingImageCount。Markdown 同样保留逐张时间。 |
| 已有字幕列表、搜索和点击跳转 | 自动化通过 | 轨道旁“查看字幕列表”；按已有条目时间排序；搜索不改完整数据，点击跳到 from；键盘弹出时列表避让；旧视频晚回包不能填入新视频列表。 |
| SRT / 带时间轴文本导出 | 自动化通过 | UTF-8，毫秒起止时间，稳定编号；搜索过滤时仍导出完整已读取轨道。空、锁定、需登录、失败都不补造字幕。 |
| Windows 原生取帧、保存对话框与外部软件打开 | 未做 | 自动化使用假播放服务和临时文件，未操作真实登录会话。 |
| macOS / Android / iOS / Linux 原生验证 | 未做 | 无这些设备的操作证据；#61 仍需要准确平台、版本、操作和诊断码。 |

**真机通过：无。** 原生平台验收不能由单元测试或截图替代。

## 可复用接口

- `VideoNoteFrame(path, position)`；`VideoNote.allFrames` 统一兼容旧单图；`copyWith(frames: ...)` 更新有序列表。`framePath` 继续表示第一张，供旧调用兼容。
- `VideoNoteExportService.buildPackage(notes, format)` 返回 bytes、fileName、noteCount、imageCount、missingImageCount。
- `LocalExportService.save({required fileName, required Uint8List bytes, dialogTitle})` 返回路径或 null（取消）；失败抛 `LocalExportException`，其 `message` 和 `diagnosticCode` 已脱敏。可注入 saveDialog / verifyFile / platform。
- `SubtitleExportService.buildPackage({required List<SubtitleCue> cues, required SubtitleExportFormat format, videoLabel, trackLabel})` 返回 fileName、bytes、cueCount、extension。仅接受已读取字幕；空/全无效条目抛 ArgumentError。`srt` 和 `text` 两种格式。
- `VideoNoteShareService.shareExportPackage` 返回 `Future<bool>`，Linux 保存取消时为 false。

共享播放器改动仅：overlay 构造提供 loadCues/onSeek；video coordinator 的笔记重置从单图变量改为帧列表。课堂 agent 将在其入口处理 course guard，父整合需确认新增 loadCues 回调也拒绝课程 UGC 字幕接口。

## 验证命令与证据

在此 worktree，使用 `C:\Users\L1XU4N\flutter\bin\flutter.bat`。首次 `pub get --offline` 因未缓存 media_kit_libs_linux 失败，随后正常 `pub get` 成功；未修改 pubspec / lock。默认 sandbox 无法写外部 SDK 锁，改用授权的 Flutter 命令运行。Git common index 写锁同样按用户授权执行。

```powershell
flutter analyze --no-pub
flutter test --no-pub test/video_note_service_test.dart test/video_note_export_service_test.dart test/local_export_service_test.dart test/subtitle_export_service_test.dart test/video_note_composer_layout_test.dart test/video_notes_page_test.dart
flutter test --no-pub --dart-define=UPDATE_V19_EVIDENCE=true test/notes_subtitles_widgets_test.dart
flutter test --no-pub test/player_overlay_service_test.dart test/player_note_flags_test.dart test/player_note_tile_layout_test.dart
flutter test --no-pub test/widget_test.dart
git diff --check
```

验证结果：相关 10 个测试文件共 59 项通过；完整 `widget_test.dart` 114 项通过，覆盖新增追加/重排画面以及原有字幕异步身份隔离。之后追加取帧失败的草稿自动保存回归 1 项通过；字幕键盘避让小修后该组件文件 4 项再次通过。最终 `flutter analyze --no-pub` 无问题，`git diff --check` 通过。

本地依赖源码证据：file_picker 11.0.3 的 `file_picker_macos.dart:124`、`file_picker_windows.dart:221`、`file_picker_linux.dart:188` 都调用 `FilePickerUtils.saveBytesToFile`。因此本次没有把“桌面只返回路径、不写 bytes”当成 #61 的确认根因。

- [字幕列表截图](evidence/subtitle-list.png)：组件渲染，演示字幕，未访问 B 站或登录资料。
- [多帧笔记截图](evidence/multi-frame-note.png)：组件渲染，应用图标代替视频画面，展示独立时间点与重排入口。

截图仅为自动化视觉证据，不能列为真机通过。`UPDATE_V19_EVIDENCE` 只在生成证据时读取当前 Windows 的微软雅黑和 SDK Material Icons 字体；普通测试无该依赖。

## 人工验收步骤与预期

1. 在各目标系统创建一条文字笔记，分别导出 Markdown/JSON；取消另存为时仍保留选择，没有成功提示；正常保存后文件存在且外部编辑器可打开。
2. 同一条笔记在 00:10 插入锚点画面，再在 00:42 和 01:05 追加当前画面。预期原笔记锚点不变，三张各自显示来源时间，视频回到捕获前位置；重启后顺序与时间不变。
3. 调整到第三张、第一张、第二张，编辑正文并保存；在详情逐张放大和分享长图中检查顺序、时间；删除中间一张再保存，其余保留。
4. 导出含图片笔记并解压，检查 images/、Markdown 图片顺序和时间、JSON frames 的 positionMs 及相对路径。人工移走一张源图再导出，预期明确警告缺图数量，其他图和正文可读，缺图时间仍在导出内容中。
5. 用一个确有 B 站字幕的视频打开轨道旁列表，搜索已知短句并点击；预期跳到其起始毫秒附近。分别导出 SRT 和文本，检查过滤未删掉其他字幕，起止时间与播放器一致。
6. 对无字幕、锁定、需登录和断网场景检查明确状态及重试；快速切换视频/分 P 时，旧加载结果不能显示或操作新视频。没有提供字幕的视频不出现合成内容。
7. #61 若报告者后续提供平台和步骤，使用同版应用重试保存到有权限/只读/取消/含中文空格路径，收集界面诊断码和操作录屏；不要导出真实 Cookie、账号存储或带会话的原始日志。

## 已知限制

- #61 原始平台与根因未确认；本次是可验证的健壮性和诊断改进，不宣称修复一个已经复现的 Mac 问题。
- 历史截图若已被系统清理，应用无法恢复原图；会保留文字、时间及可读缺图说明。
- 新数据的 JSON version 2 支持多图；旧版本应用只理解首张 framePath。降级后用旧版本重新保存会丢失它不认识的多帧字段。
- 新增字幕入口只读取 B 站已提供、当前会话有权访问的轨道；不包含 ASR、翻译、绕过锁定或离线生成字幕。

## 独立复核后的异步修复

| 项目 | 状态 | 验证 |
| --- | --- | --- |
| 删除后待执行自动保存复活旧笔记 | 自动化通过 | 确认删除后取消待执行计时器，等待在途保存，再取消它可能补排的自动保存；删除后新草稿不再 flush 旧记录。分别覆盖 800ms 内删除、自动保存已开始但存储回包阻塞。 |
| 追加截图晚到干扰新视频播放 | 自动化通过 | 捕获到保存共用 noteSaveCompletion，合集切换等待完成；每个异步边界及恢复播放前校验 BV、草稿和导航代次。内部切 P 只接受本次预期代次。暂停回包/截图回包晚到都不能 seek 新 BV。 |
| 撤销捕获产生的孤立图片 | 自动化通过 | 迟到图片若未被任何笔记引用则清理；仍被引用或存储无法解析时保留。测试仅使用新建临时目录。 |
| 上述竞态的原生平台验证 | 未做 | 延迟原生服务使用假实现；没有读取真实用户偏好文件、Cookie 或凭据。 |

本次复测命令：`flutter analyze --no-pub` 无问题；`flutter test --no-pub test/widget_test.dart test/video_note_service_test.dart test/video_note_export_service_test.dart` 共 **133 项通过**。包括四个真实 PlayerPage 延迟交错组件用例与一个引用安全清理用例，另保留原有播放器、笔记和导出回归。

补充人工预期：编辑笔记后立刻确认删除，等待及重启后记录均不应再次出现；取帧未返回期间发生视频/分 P 导航时，旧结果不能恢复新视频的播放位置，已保存文字仍在原视频笔记中。

## 1.8 候选合入后的横竖截图预览

本轮独立分支 `codex/v19-notes-preview` 基于准确合并点 `af282f5b2f4ccfb266b04e763b17ad6e17eb16e8`，包含父任务授权继续的 1.8 候选 `95b2323`。该合并点已保留旧 `framePath` 紧凑预览的 `BoxFit.contain`、视口高度 38% / 108–280 像素上限，以及旧测试的 contain 断言。本轮不重复覆盖已合入的实现，只修复同一编辑器中多帧仍固定最高 240 像素的差异。

| 项目 | 状态 | 证据或边界 |
| --- | --- | --- |
| 旧单帧与多帧紧凑预览共用比例及高度规则 | 自动化通过 | 两者均 contain；紧凑无边框编辑器每张最高 `clamp(viewportHeight * .38, 108, 280)`，详情页默认最高 240 不变。320×240、420×1000、1000×700 三个实际 MediaQuery 视口覆盖上下限与中间值。 |
| 混合横竖图、顺序、各自毫秒时间和查看器 | 自动化通过 | 新测试真实生成、解码 90×160 与 160×90 PNG，检查完整源图区域；故意使用非时间排序的 00:42.125 / 00:03.500，实际点击重排后保存、重读及逐张打开原图，笔记锚点仍为 00:20。 |
| 晚到保存、删除与捕帧边界 | 自动化通过 | 既有删除两种自动保存交错、追加截图晚到两种交错、临时 seek drain / 切 CID / 还原位置确认 / 睡眠 / 嵌套路由取消夹具，在此候选合并基线上重新通过。未修改播放器文件、模型、服务或导出逻辑。 |
| 原生平台与真实视频截图 | 未做 | 只使用 Widget、临时合成 PNG、内存偏好和假播放服务；未运行应用、未读取真实账号或用户资料。 |

新夹具的有效红绿证据：在修复前，`test/video_note_frame_preview_test.dart` 的 `--plain-name 'Size(320.0, 240.0)'` 已验证 legacy 高度不超过 108；多帧实际高 240，断言 `<= 108.01` 失败。改为共用高度上限后，新文件 4 项全部通过。旧 `video_notes_page_test.dart` 已是 contain 断言，本轮只纠正其“铺满”过时注释。

在此独立工作树执行：

```powershell
$flutter = 'C:\Users\L1XU4N\flutter\bin\flutter.bat'
& $flutter test --no-pub --dart-define=UPDATE_NOTES_PREVIEW_EVIDENCE=true test/video_note_frame_preview_test.dart test/video_note_composer_layout_test.dart test/video_notes_page_test.dart test/video_note_service_test.dart test/video_note_export_service_test.dart test/notes_subtitles_widgets_test.dart test/player_note_flags_test.dart test/player_note_tile_layout_test.dart test/flutter_video_frame_capture_test.dart test/ab_repeat_capture_lifecycle_test.dart test/ab_repeat_nested_route_test.dart --reporter expanded
& 'C:\Users\L1XU4N\flutter\bin\cache\dart-sdk\bin\dart.exe' 'C:\Users\L1XU4N\flutter\bin\cache\flutter_tools.snapshot' test --no-pub test/widget_test.dart test/player_v18_visual_test.dart --name '删除笔记|追加截图|竖屏时间点笔记|时间点笔记截图失败|全屏时间点笔记|截图预览保留' --reporter expanded
& $flutter analyze --no-pub
git diff --check
```

前两条分别 **72 / 9 项通过，共 81 项**，其中新测试 4 项。`flutter analyze --no-pub` 无问题；4 个修改的 Dart 文件 format 0 changed，`git diff --check` 通过。第二条直接运行同一现有 SDK 的 Flutter tool snapshot，避免 Windows bat 将正则 `|` 解释成 shell 管道；最初 bat 选择命令未启动测试，重复 `--plain-name` 为 AND 选择也未匹配到测试，均不计入测试通过数量。未运行全量或构建。

- [420×1000 视口的完整可滚动内容](evidence/notes-mixed-420x1000.png)
- [1000×700 视口的完整可滚动内容](evidence/notes-mixed-1000x700.png)

两图均由真实编辑器 Widget 和合成三色图片生成并已目检：横竖画面的三条色带完整，序号、独立时间和重排按钮可读。宽视口截图包含滚动区域的完整内容，因此图片高度可超过视口高度；实际高度上限仍取对应 MediaQuery 视口。字体只在证据开关开启时读取已安装字体，普通测试不依赖字体文件。这些不是原生播放器或真机证据。

人工验收：在一条笔记中混合追加横屏和竖屏画面，缩短窗口或进入全屏紧凑编辑器，逐张检查整张画面可见并可滚动；重排、保存、重开详情和逐张放大后，顺序与每张时间应保持，笔记原锚点不变。候选后的真实设备验收仍待执行。
