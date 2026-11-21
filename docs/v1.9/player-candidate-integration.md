# 播放器候选基线交叉验证

本轮独立工作树 `v19-player-integration` / `codex/v19-player-integration` 从
`af282f5b2f4ccfb266b04e763b17ad6e17eb16e8` 开始。它包含获准继续整合的 1.8
**候选**基线，不代表正式最终 1.8，也不构成 1.9 发布验收。

## 修复与保留点

| 项目 | 状态 | 实际证据 |
| --- | --- | --- |
| `PlaybackSnapshot.bufferedRanges` 和可空 `playRequested` 共存 | 自动化通过 | 原生字典解析、`copyWith` 同时保留缓冲段与显式 false；旧 null 兼容用例仍通过 |
| Windows 课堂换账号撤销缓冲 | 实现 / 自动化通过 | 账号监听直接递增 source generation 时清空缓冲，并立即发送错误快照及 false 播放意图；等待既有 open/stop 的串行保护保留 |
| Windows 备用线路缓冲归属 | 实现 / 自动化通过 | 每次媒体实例打开先清旧缓冲；正在返回的主线路采样按 source generation / attempt index 拒绝，下一次采样仅显示新线路结果 |
| BV / CID / 账号 / 销毁后的迟到采样 | 自动化通过 | 实际 `WindowsPlaybackService` 加受控异步 mpv 属性读取，覆盖成功与异常分支；未调用真实 libmpv |
| Windows 缓冲 / 片尾暂停意图 | 实现 / 自动化通过 | `pause()` 在后端 Future 完成前发布 false；即使后端没有新的 `playing` 事件，AB 也可及时撤销续播。已发出的 play 返回时重新核对暂停意图；课堂换账号停流等待在途 open 与 play |
| 清晰度 / 听视频切换保留意图 | 实现 / 自动化通过 | 源切换读取播放意图，不把暂时 `isPlaying=false` 当用户暂停；普通片尾仍保持不自动续播。切换中显式暂停优先于早先捕获的 true |
| 1.8 自定义长按 / 双击不唤栏 | 自动化通过 | 360×800、1280×900 真实全屏 PlayerPage：2.5 倍速使 28→30 秒的 AB 边界按 800ms 回跳，松手恢复 1 倍；双击暂停保持隐藏栏且后续不自动 seek |
| AB / 缓冲 / 字幕实际底栏 | 自动化通过 | 320×900 / 160% 字号、1280×900 / 130% 字号真实 PlayerPage；AB 标记、Slider 共用宽度、左右边界及时长；双段缓冲进入实际 Slider；字幕在测量出的 bottom bar 上方 |
| 320px 大字号详情选集标题 | 实现 / 自动化通过 | 原先标题与“展开”按钮右溢出 21px；标题改为 Expanded 后自然换行，初始详情页及全屏组合均无 Flutter overflow |
| AB 原四项 P2 | 自动化通过 | 迟到片尾 seek + 暂停、内部截图保留区间、临时目标/还原 seek 排空、嵌套路由取消晚到截图恢复；原有真实控件回归均保留 |
| 课堂同 CID 切清晰度 / 听视频的暂时 duration=0 | 自动化通过 | 既有课程 AB 用例确认区间保留；真实无效新时长仍按原规则退出 |
| Android 播放意图与缓冲发送 | 实现已保留 / 本轮只读核对 | `NativePlaybackController` 保留 `onPlayWhenReadyChanged`、`nativePlayer?.playWhenReady`，缓冲段只在 `playbackPrepared && duration>0` 时发送；未改 Kotlin |
| Android / Windows 真机媒体验证 | 未做 | 本轮为 Windows host 上的合成服务、平台通道和 Flutter widget 测试，不是设备或真实播放验收 |

`bufferStateReader` 只是 Windows 服务可注入的只读异步属性读取函数。生产默认仍使用
NativePlayer 的 `demuxer-cache-state`；没有添加新的全局 PlaybackService 接口或要求修改所有 Fake。
源/线路/账号栅栏在读取前捕获、读取后复核，未知属性或解析错误不会伪造从零开始的缓存进度。

最后一层门控曾实际复现：切清晰度已发出的 `play` Future 卡住，显式暂停后放行旧 play，
最终 `state.playing` 为 true（期望 false）。现所有五个播放入口复用 `_playPlayerMedia`，
同代次下重新暂停，课堂账号失效时则由等候该命令的串行 stop 收尾。清晰度 / 听视频各有
source-load、media-open、media-play 三层回归，另有课堂 late-play 先完成再 stop 的顺序用例。

## 测试命令与结果

环境：Windows host；现有 Flutter 3.44.6 / Dart 3.12.2。所有视频、字幕、账号变更及
媒体属性均为合成夹具；SharedPreferences 为内存 mock。未读取实际会话或播放进度文件，
未启动应用、构建 APK、创建签名材料、接受 SDK license 或修改 SDK / Pubcache。

```powershell
C:\Users\L1XU4N\flutter\bin\flutter.bat pub get --offline
C:\Users\L1XU4N\flutter\bin\flutter.bat test --no-pub `
  test/ab_repeat_test.dart test/player_ab_repeat_test.dart `
  test/ab_repeat_capture_lifecycle_test.dart test/ab_repeat_nested_route_test.dart `
  test/ab_repeat_evidence_test.dart test/player_v18_gestures_test.dart `
  test/player_feedback_layout_test.dart test/playback_buffer_range_test.dart `
  test/classroom_account_race_test.dart test/classroom_access_test.dart `
  test/classroom_integration_test.dart test/windows_buffer_identity_test.dart `
  test/player_merged_controls_test.dart test/native_playback_service_test.dart `
  test/listening_playback_test.dart test/windows_local_source_resume_test.dart `
  test/windows_source_identity_race_test.dart test/windows_playback_progress_store_test.dart `
  test/windows_playback_recovery_policy_test.dart test/windows_playback_audio_lifecycle_test.dart `
  --reporter json
```

20 个相关文件 **140 通过 / 0 失败 / 0 跳过**，25.601s，exit 0。
报告中的另 20 个 hidden 成功事件是文件加载事件，不计作测试。
新增服务文件 16 项，新增真实控件文件 4 项，共 20 项；其余为既有回归。
初轮八文件 71 项与中间运行均为重叠集合，不额外累加。

最终静态检查、格式以及 lint 修正后服务回归的结果列于下方；不把早先含 1 条
`curly_braces_in_flow_control_structures` info 的分析算作通过。

```powershell
C:\Users\L1XU4N\flutter\bin\flutter.bat analyze --no-pub
C:\Users\L1XU4N\flutter\bin\flutter.bat test --no-pub test/windows_buffer_identity_test.dart --reporter expanded
C:\Users\L1XU4N\flutter\bin\dart.bat format --output=none --set-exit-if-changed `
  lib/services/windows_playback_service.dart lib/features/player/player_controls_view.dart `
  test/playback_buffer_range_test.dart test/windows_buffer_identity_test.dart `
  test/player_merged_controls_test.dart
git diff --check
```

- 最终 analyze：**No issues found**，16.7s，exit 0。
- 唯一 lint 修正只为测试 finally 中的 if 添加花括号；修正后单文件 **13/13 通过**，
  exit 0；最后增加迟到播放边界后该单文件 **16/16 通过**，均与上面 140 项重叠，不累加。
- format：5 files / **0 changed**，exit 0；diff check 无输出，exit 0。
- 既有 AB 核心 19、capture/lifecycle 14、nested routes 12、模型 3、证据布局 3；
  课堂 access 10、account race 7、integration 1；其余快照、1.8 手势/反馈、平台通道、
  逐 P 进度和 Windows 源恢复与新组合测试，共计 140。

Android 原生代码本轮未改，未运行 Gradle / Kotlin 编译或设备测试，不把既有其他树的
构建结果计作本轮平台验证。离线 pub get 自动改写的七个生成注册文件已原样还原。

## 人工设备步骤及预期

1. 使用普通多 P 视频，开启 10–30 秒 AB。缓存发生跳转空隙时只显示实际缓冲段；AB
   标记仍与正常 Slider 同轨。28 秒时按住自定义 2.5 倍速，到 B 回 A；松手恢复原速。
2. 在隐藏控制栏下双击暂停，等待超过一个区间，不能自动回跳或出声。继续播放后计时
   按新位置及实际速度重算；字幕 / 进度条 / 笔记的显式区间外跳转仍退出 AB。
3. 同 CID 切清晰度或听视频：短暂 duration=0 不丢区间；在请求播放源及打开媒体期间
   以及已发出的 play 命令完成前分别显式暂停，完成后保持暂停。合法后台听视频可继续循环，普通视频后台暂停后
   不能由迟到片尾 seek 重启。
4. 选择区间外旧笔记而不点击跳转，保存截图：只允许临时目标及还原 seek，返回原位置
   后保留 AB。临时 seek 在途时拖到 90 秒或切 P，旧命令先排空，不能落到新位置/新 CID。
5. 截图帧返回前打开作者 / mention / 下载 / 屏蔽管理，页面覆盖期间保持暂停，晚到帧
   不能还原 seek 或重新出声；内部跨 CID 捕帧仍按原导航身份保护运行。
6. 仅由人工测试者自有且已购有权账号检查课堂：播放中换账号，立刻清除缓冲显示并停流；
   新账号必须重新经过已购证明。不得靠旧备线恢复。未购 / 已过期 / 已下架均不得请求播放。
7. Android 真机检查 Media3 缓冲、通知栏 / 耳机暂停、AB B=片尾、清除后原整片循环与次数
   规则恢复；Windows 真实 mpv 检查分离音轨与主备线路。上述设备步骤本轮均未执行。

本轮没有确认的未修复 P1/P2。实际设备、真实已购账号、正式最终 1.8 SHA 仍待后续独立验收；
mock 通过不能替代这些证据。跨服务持久进度格式、课堂权限检查、notes UI 和版本均未改动。

## 5953862 独立审查后的播放意图追加修复

独立审查在 `59538629fa4e8df538e9d7255686173cb59b6086` 确认一项 P2：
先暂停，切清晰度时卡住 source load，用户重新播放，随后放行 load，最终
`playRequested=true` 而底层 `playing=false`。作者树复制审查夹具后也复现了原红例
`resume during paused quality source load stays playing`，断言期望 true / 实际 false。

原因是视频 `_openMediaAttempt` 在加载后仍将最初捕获的 `shouldPlay=false` 与最新意图
相与。现仅保留 `_openCurrentSource` 在首次异步等待前初始化意图，打开和备用线路阶段
删除该旧副本，播放及解码检查直接读取最新 `_shouldPlayAfterFallback`。
`_playPlayerMedia` 的 source/account 栅栏、迟到 play 后的暂停复核、课堂停流队列保持不变；
片尾切换初始化仍为 false，`restorePlayback:false` 的内部定位保护未改。

新增 `test/windows_playback_intent_ordering_test.dart` 采用审查人的 FIFO/state-first 夹具：
open / stop / play / pause / seek 经同一串行队列，状态先更新再等待命令完成；
没有依赖无序后端让原红例成立。11 项包括：

- 原审查 5 项：修正性 pause 期间更新 resume、旧 play 跨 BV/CID、新 resume 在 paused
  quality/audio source load 后保持播放。
- 片尾 quality/audio 两种切换，没有显式 resume 均不自启。
- 音频准备时强制恢复目标位置，内部 `restorePlayback:false` 在 seek 排空前不激活媒体。
- resume 后账号/BV/CID 失效，旧加载结果均不能打开或激活媒体。

最终代码后的定向验证：

```powershell
C:\Users\L1XU4N\flutter\bin\flutter.bat test --no-pub `
  test/windows_playback_intent_ordering_test.dart test/windows_buffer_identity_test.dart `
  test/windows_playback_audio_lifecycle_test.dart test/windows_source_identity_race_test.dart `
  test/windows_local_source_resume_test.dart test/listening_playback_test.dart `
  test/player_ab_repeat_test.dart test/ab_repeat_capture_lifecycle_test.dart `
  test/ab_repeat_nested_route_test.dart test/classroom_account_race_test.dart --reporter json
C:\Users\L1XU4N\flutter\bin\flutter.bat analyze --no-pub
C:\Users\L1XU4N\flutter\bin\dart.bat format --output=none --set-exit-if-changed `
  lib/services/windows_playback_service.dart test/windows_playback_intent_ordering_test.dart
git diff --check
```

- 十文件 **96 通过 / 0 失败 / 0 跳过**，17.608s，exit 0；另十个 hidden 成功事件是文件加载。
- 分组：新 ordered 11、既有 buffer/intent 16、Windows 音轨 7 / source identity 2 /
  local resume 3、听视频 5、AB 核心 19 / capture-lifecycle 14 / nested-route 12、课堂账号 7。
- analyze：**No issues found**，8.8s，exit 0；format：2 files / **0 changed**；diff check 无输出。
- 该 96 项与此前 140 项有重叠，不能相加为累计通过数。没有运行全量、Gradle、构建、
  应用或真实账号；Windows host 合成验证，设备步骤仍未执行。

人工补测：暂停普通视频，在清晰度加载期间点击播放，加载完成后应持续播放；改为在期间
点击暂停则保持暂停。听视频同样检查双向选择。普通片尾不主动播放时切换清晰度/听视频仍
保持暂停。作者回归通过后，仍交由独立审查复核，不作为发布授权。
