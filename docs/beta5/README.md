# 1.8.0 Beta5：图片复用、字幕会话与缓存清理

基线重新核验：dev `dcb9368f7cb905b6d2723eb72a2912081d2775df`，master `9156ad90060d156095bc5484d5fe372fac26fa94`。Beta1/2 已在 dev；draft #49（Beta3）和 #51（Beta4）仍开放。独立分支 `codex/beta5-image-cache` 从 Beta4 `5a49fc6` 创建，包含其紧凑订阅、首页卡片、历史任务及宽屏双击动画修复。没有合并或正式发布。

## 图片

所有远程封面与头像改用同一编码文件缓存，保留完整 URL（含查询/缩放参数）和请求头身份。公开 MID 分区，不持久化 Cookie 或原始 URL/头。相同资源跨页面与服务重建复用；图片解码大小按实际显示尺寸决定。

默认 256 MiB，可选 64/128/256/512 MiB，按真实访问顺序淘汰；单图 16 MiB、最多 2000 项。跨实例/isolates 的 OS 锁保护索引，持久短租约合并请求并限制六个并行下载。HTTP 到期条件验证、ETag/304、no-store、离线回退、失败退避、校验损坏、异常租约和临时文件恢复都有定向测试。清空/移除撤销写租约，迟到下载不能回填；清空也移除本应用的已解码图片。账号变化只重载公共图片，不重发旧凭据请求。旧 flutter_cache_manager 管理的图片在首次启动清理，不扫描其他用户目录。

## 已确认的字幕竞态

旧桌面实现只按 BV/CID 定位字幕会话。轨道列表成功刷新后，相同 BV/CID 的旧正文 HTTP 响应仍可返回；旧请求没有比较其起始会话与当前会话。这不是仅更换缓存策略：`cached_player_overlay_service_test.dart` 中的 `desktop rejects old cue response after successful same-CID track refresh` 使用两个受控 Future，先发旧正文，再成功刷新同 CID（同轨道 ID、不同语言/URL），最后释放旧响应。基线得到 `available` 而测试期望 `unavailable`，修复后通过。

修复同时覆盖原生通道、UI 请求代次、账号/清空撤销和自动重取过期 URL 时的语言匹配。失败的元数据刷新保留原有效会话，成功刷新取消旧选择。正文复用绑定成功的轨道会话代次，8 MiB/64 轨道/5 分钟的内存 LRU；预算计算字幕 UTF-8 文本和时间戳，不是整个进程内存。当前显示字幕另持有有效引用。

这些确定性测试证明上述竞态被阻断，不代表真实设备中所有“串字幕”症状均已现场验收。

## 视频与桌面磁盘回看

Android 保留默认 512 MiB 的 Media3 边播缓存，改为访问 LRU，保护当前音视频 representation 和写入预约。听视频只保护正在使用的音轨。容量满或写盘失败时停止可选缓存写入，继续向解码器传递网络数据；关闭失败 writer 会释放对应范围预约。显式离线视频目录不参与此清理。

桌面最终保留 `cache-on-disk=yes`，撤回纯内存默认方案。原 `windows_media_cache_capacity_bytes` 偏好继续有效，默认 **512 MiB 磁盘软阈值**，可选 128/256/512/1024/2048 MiB。原来的前后各一份 demuxer 预算在磁盘模式下计量的是内存元数据，不能当作磁盘上限。mpv 使用只追加的临时 packet 文件；关闭媒体后不可复用，也没有本项目可调用的磁盘硬配额。[mpv 官方说明](https://mpv.io/manual/stable/#options-cache-on-disk)

实现使用正确的 `demuxer-cache-dir`、`demuxer-cache-unlink-files=whendone` 和每个播放器的独立目录，每 500 ms 汇总专属目录内真实文件长度。达到软阈值后请求 `cache-on-disk=no`，保留已打开的 packet 文件，后续新数据改用每路前后各 64 MiB 的 RAM 预算；独立音视频 demuxer 各有一份，解码器/画面内存另计。只在旧媒体文件都关闭且总占用低于阈值后为新媒体恢复写盘。回看仍取决于保留的索引范围，范围外需联网。

**该阈值不是硬上限**：采样、UI isolate 暂停及 demuxer 工作线程接收设置有延迟，超出量没有严格上界。每次设置均回读，因为 media_kit 的 setter 不返回 mpv 的错误码；运行中的读取/设置失败会显示明确状态并在下次检查重试；初始化失败会明确回退，不能宣称配额已生效。Windows 固定 mpv 依赖的工作线程会更新磁盘选项，关闭新增写入不会立即销毁已有文件。[固定版本源码：选项传播](https://github.com/mpv-player/mpv/blob/652a1dd90711839acdccc08004056d25514ef2d8/demux/demux.c#L2318-L2323)、[临时文件生命周期](https://github.com/mpv-player/mpv/blob/652a1dd90711839acdccc08004056d25514ef2d8/demux/cache.c#L74-L120)。这不等于 Windows 真实播放验收。

每个会话持有 OS 文件锁直到播放器完成释放；目录创建/回收另有跨进程锁。维护只清理已结束或崩溃遗留的会话，保留本进程/其他 isolate/其他进程的活跃文件。播放器关闭后自动回收，启动时回收残留；离线下载不受影响。相关单测覆盖真实文件字节、跨 isolate 互斥、播放中清空拒绝、设置失败及配置/释放竞态。

`tool/desktop_disk_cache_probe.dart` 随 Linux/macOS 既有原生探针运行，使用本机 HTTP 合成媒体和独立音轨，检查真实 packet 文件、缓存回看、阈值后的设置回读/保留文件和关闭清理。探针用明确记录的 256 KiB 测试填充文件触发阈值，不是 B站流量或长视频磁盘增长基准；最终结果见对应 Actions 日志。

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
flutter test --no-pub test/image_resource_cache_test.dart test/cache_file_lock_test.dart test/cache_review_probe_test.dart test/cached_player_overlay_service_test.dart test/bilibili_auth_service_test.dart test/windows_media_cache_service_test.dart test/desktop_disk_cache_session_test.dart test/async_service_failure_test.dart test/player_overlay_service_test.dart
flutter test --no-pub --dart-define=CACHE_PERF_OUTPUT=/tmp/image-performance.json test/cache_review_probe_test.dart
flutter test --no-pub --dart-define=PERF_OUTPUT=/tmp/subscription-performance.json --dart-define=PAGING_OUTPUT=/tmp/subscription-paging.json test/subscription_performance_probe_test.dart test/subscription_paging_probe_test.dart
flutter test --no-pub
cd android
bash ./gradlew :app:testDebugUnitTest :focubili_android:testDebugUnitTest
```

本地完整 Flutter 865 通过、1 项原有跳过；缓存定向 78 通过；截图/图片请求 4 通过；订阅性能 3 通过；Android JVM 42 项 / 10 suite 通过。analyze、格式、diff check 和三 ABI debug 构建通过。最终机器记录见 [validation.json](validation.json)。最终全量固定源码运行通过。桌面修改的首轮全量发现两项异步状态错误转换回归，已修复并完整重跑；相关错误处理用例纳入定向测试。

## 实际 UI 截图

以下是 Linux Flutter widget 夹具真实渲染，使用可控内容和缓存用量，不是设计图，也不是 Windows 真机画面。12 张覆盖 390px、320px/180% 字号、1280px 深色及桌面磁盘缓冲。

| 手机 | 大字号 | 桌面 |
|---|---|---|
| [视频](cache-video-mobile.png) | [图片](cache-images-large-text.png) | [磁盘缓存 UI 深色布局](cache-video-desktop-dark.png) |
| [图片](cache-images-mobile.png) | [字幕](cache-subtitles-large-text.png) | [桌面磁盘缓冲](cache-video-desktop-buffer.png) |

订阅布局、首页卡片和宽屏双击反馈沿用 [Beta4 截图](../beta4/README.md)。其回归包含在本轮全量测试中。

## 交付限制

包名仍为 `com.focubili.app.preview`，共享版本 `1.8.0+25`，Android `1.8.0-beta.5`。本地 ARM64 code 2025，公开证书与本环境 Beta2/3/4 一致，见 [APK 核验](apk-verification.json)。没有配置新的签名或读取/上传凭据。CI 使用原有临时 debug 签名，不保证覆盖用户设备上的测试版；不要为覆盖安装卸载并丢失数据。

Library 保存返回 HTTP 401，未创建文件；本地同签名 APK 保留。远端采用既有 Actions artifacts。Windows/macOS CI 增加文件锁和缓存回归，但 Linux widget 与跨平台 CI 都不能冒充真实 Windows 播放验收；真实 B站请求、设备流量/RSS、Android 真机、Windows 连续 seek 尚未验收。iOS 产物沿用未签名开发交付路径。
