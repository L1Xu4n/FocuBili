# 1.8.0 Beta5：图片复用、字幕会话与缓存清理

基线重新核验：dev `dcb9368f7cb905b6d2723eb72a2912081d2775df`，master `9156ad90060d156095bc5484d5fe372fac26fa94`。Beta1/2 已在 dev；draft #49（Beta3）和 #51（Beta4）仍开放。独立分支 `codex/beta5-image-cache` 从 Beta4 `5a49fc6` 创建，包含其紧凑订阅、首页卡片、历史任务及宽屏双击动画修复。没有合并或正式发布。

## 图片

所有远程封面与头像改用同一编码文件缓存，保留完整 URL（含查询/缩放参数）和请求头身份。公开 MID 分区，不持久化 Cookie 或原始 URL/头。相同资源跨页面与服务重建复用；图片解码大小按实际显示尺寸决定。

默认 256 MiB，可选 64/128/256/512 MiB，按真实访问顺序淘汰；单图 16 MiB、最多 2000 项。跨实例/isolates 的 OS 锁保护索引，持久短租约合并请求并限制六个并行下载。HTTP 到期条件验证、ETag/304、no-store、离线回退、失败退避、校验损坏、异常租约和临时文件恢复都有定向测试。清空/移除撤销写租约，迟到下载不能回填；清空也移除本应用的已解码图片。账号变化只重载公共图片，不重发旧凭据请求。旧 flutter_cache_manager 管理的图片在首次启动清理，不扫描其他用户目录。

## 已确认的字幕竞态

旧桌面实现只按 BV/CID 定位字幕会话。轨道列表成功刷新后，相同 BV/CID 的旧正文 HTTP 响应仍可返回；旧请求没有比较其起始会话与当前会话。这不是仅更换缓存策略：`cached_player_overlay_service_test.dart` 中的 `desktop rejects old cue response after successful same-CID track refresh` 使用两个受控 Future，先发旧正文，再成功刷新同 CID（同轨道 ID、不同语言/URL），最后释放旧响应。基线得到 `available` 而测试期望 `unavailable`，修复后通过。

修复同时覆盖原生通道、UI 请求代次、账号/清空撤销和自动重取过期 URL 时的语言匹配。失败的元数据刷新保留原有效会话，成功刷新取消旧选择。正文复用绑定成功的轨道会话代次，8 MiB/64 轨道/5 分钟的内存 LRU；预算计算字幕 UTF-8 文本和时间戳，不是整个进程内存。当前显示字幕另持有有效引用。

这些确定性测试证明上述竞态被阻断，不代表真实设备中所有“串字幕”症状均已现场验收。

## 视频与桌面取舍（待确认）

Android 保留 Media3 边播缓存，改为访问 LRU，保护当前音视频 representation 和写入预约。听视频只保护正在使用的音轨。容量满或写盘失败时停止可选缓存写入，继续向解码器传递网络数据；关闭失败 writer 会释放对应范围预约。显式离线视频目录不参与此清理。

旧桌面配置是 `cache-on-disk=yes`，两项 demuxer 字节设置各取默认 512 MiB。[旧实现](https://github.com/L1Xu4n/FocuBili/blob/5a49fc60288e11265eda38b1da9c7b77171a9710/lib/services/windows_playback_service.dart#L767) 未实现按 BV/CID/分段检索文件或跨播放器重开的文件索引。mpv 文档说明该 packet 文件仅追加，关闭媒体即删除，不能作为后续播放资源复用；磁盘模式下字节设置限制的是内存元数据，不是磁盘文件大小。[官方依据](https://mpv.io/manual/stable/#cache)

当前草案改为每路 64 MiB 内存缓冲（可选 32/64/128），前向 3/4、回看 1/4。音视频独立 demuxer 各有一份预算，解码器/画面/其他内存另计，不能视为进程 RSS 硬上限。启动和最后播放器关闭后自动清理旧的专属磁盘残留，播放中拒绝删除。

**实际取舍：没有移除跨重启复用能力，因为旧模式从未实现它；但确实缩短了单次长视频播放中的回看范围。** 仍在缓冲范围内的 seek 可复用，范围外需要网络重新取数据；同会话长距离重复播放可能比旧磁盘模式耗更多流量，压缩媒体数据转入内存也可能比旧短时播放占更多 RAM。跨关闭/重启的重复播放两者都需重新联网。这里是配置和播放器语义推导，没有实测真实 B站流量或 Windows RSS；不把它写成无代价提升。已向用户提出明确取舍，draft 保留待审状态。

## 可复现证据

| 用例 | 前 | 后 |
|---|---:|---:|
| 原 Image.network 入口，清除解码缓存后重新打开 10 次 | HTTP 10 次 | 10 次打开加服务重建，HTTP 1 次 |
| 两缓存实例同时请求同一张图 | — | HTTP 1 次 |
| 相同 CID 成功更新轨道后释放旧正文 | 错误接受 | 拒绝旧会话 |
| 8 字节视频预算、当前占满后请求 4 字节 | 原 LRU 删除当前 span | 保留当前，拒绝可选写入 |
| 1000 次订阅 feed 读取 | 1000 份排序结果（dev） | 1 份 |
| 100 次未变化重读 | 100 次通知（dev） | 0 次 |
| 500 项订阅列表首屏预创建 | 500（dev） | 4 |

图片对照是本机 HTTP server + Flutter 实际解码，模拟内存压力或重启；只针对旧的 Image.network 入口，不声称旧 cached_network_image 的每次打开都联网。时间记录不作为跨机器速度承诺。[原始图片计数](image-performance.json)、[订阅复测](subscription-performance.json)、[分页复测](subscription-paging.json)、[dev 对照说明](../beta4/README.md)。

```sh
flutter test --no-pub test/image_resource_cache_test.dart test/cache_file_lock_test.dart test/cache_review_probe_test.dart test/cached_player_overlay_service_test.dart test/bilibili_auth_service_test.dart test/windows_media_cache_service_test.dart test/player_overlay_service_test.dart
flutter test --no-pub --dart-define=CACHE_PERF_OUTPUT=/tmp/image-performance.json test/cache_review_probe_test.dart
flutter test --no-pub --dart-define=PERF_OUTPUT=/tmp/subscription-performance.json --dart-define=PAGING_OUTPUT=/tmp/subscription-paging.json test/subscription_performance_probe_test.dart test/subscription_paging_probe_test.dart
flutter test --no-pub
cd android
bash ./gradlew :app:testDebugUnitTest :focubili_android:testDebugUnitTest
```

本地完整 Flutter 855 通过、1 项原有跳过；缓存定向 64 通过；截图/图片请求 4 通过；订阅性能 3 通过；Android JVM 42 项 / 10 suite 通过。analyze、格式、diff check 和三 ABI debug 构建通过。最终机器记录见 [validation.json](validation.json)。先前全量运行遇到测试文件编辑期间的加载失败，最终固定源码后重跑全量通过。

## 实际 UI 截图

以下是 Linux Flutter widget 夹具真实渲染，使用可控内容和缓存用量，不是设计图，也不是 Windows 真机画面。12 张覆盖 390px、320px/180% 字号、1280px 深色及桌面内存草案。

| 手机 | 大字号 | 桌面 |
|---|---|---|
| [视频](cache-video-mobile.png) | [图片](cache-images-large-text.png) | [磁盘缓存 UI 深色布局](cache-video-desktop-dark.png) |
| [图片](cache-images-mobile.png) | [字幕](cache-subtitles-large-text.png) | [桌面内存草案](cache-video-desktop-memory.png) |

订阅布局、首页卡片和宽屏双击反馈沿用 [Beta4 截图](../beta4/README.md)。其回归包含在本轮全量测试中。

## 交付限制

包名仍为 `com.focubili.app.preview`，共享版本 `1.8.0+25`，Android `1.8.0-beta.5`。本地 ARM64 code 2025，公开证书与本环境 Beta2/3/4 一致，见 [APK 核验](apk-verification.json)。没有配置新的签名或读取/上传凭据。CI 使用原有临时 debug 签名，不保证覆盖用户设备上的测试版；不要为覆盖安装卸载并丢失数据。

Library 保存返回 HTTP 401，未创建文件；本地同签名 APK 保留。远端采用既有 Actions artifacts。Windows/macOS CI 增加文件锁和缓存回归，但 Linux widget 与跨平台 CI 都不能冒充真实 Windows 播放验收；真实 B站请求、设备流量/RSS、Android 真机、Windows 连续 seek 尚未验收。iOS 产物沿用未签名开发交付路径。
