

## 2026-10-13：Android v1.7 360P 问题隔离调查与修补

- 用户确认 Android / v1.7 正式版，尚未确认是否所有视频。修补分支 `codex/fix-v170-playback-auth` 从原始 v1.7.0 标签提交 `4a99e44efeb2ad2b374e3cb6c3d296b61558eed6` 创建；正式 Android APK 于 2026-10-02 上传，发布说明确认后续 Apple/Linux 更新没有替换它。未将 Beta5 合入修补分支。
- 比较 dev `dcb9368f7cb905b6d2723eb72a2912081d2775df`、Beta5 `a6c83343a6bfbeb5378e89558617414fa1935823`：同样存在登录合并 www/api/passport Cookie、Android 播放只读 www 且读失败静默使用空字符串的不一致。以合成域容器编译原有 CookieController 和提取的原生播放方法，复现登录有会话、播放无会话；修补后两端复用同一策略，读取异常明确失败，不再伪装成匿名请求。
- 原生轨道评分可让 360P AVC 压过请求的 1080P HEVC，且仍上报接口 `quality=80`。原方法合成复现：requested=80 / returned=80 / selected=16 / reported=80；修补后 selected=80。现在先满足目标上限内最高档位，同档继续优先 AVC；上报实际选中轨道编号。清晰度回退不再一律提示大会员问题。
- 使用新媒体缓存键命名空间和实际选中档位，避免误标旧缓存继续污染播放；不清除用户会话、笔记、观看记录或离线文件。旧媒体字节交给既有 LRU 回收。
- 新增每次 playurl 请求独立诊断：request_id、wbi_enabled、wbi_signed、wbi_fallback、playurl_attempted、session_read、auth_state、requested_quality、returned_quality、selected_quality、stage、outcome、api_code、http_status。WBI 开关来自本次请求快照；从未自动回退无签名接口。仅实际 nav 验证成功时标记 authenticated，Cookie 存在本身为 session_present_unverified，游客/过期/未知分别记录。成功但低清的响应也记录。
- 诊断入口采用类型、范围、固定枚举白名单；未知键及动态内容被丢弃，不接收 Cookie/token/签名 URL/响应正文。记录最多 20 条；扩充单条安全字段上限至 16。同一 Dart isolate 的多服务实例写入及清空串行化，防止紧邻的请求和播放错误记录互相覆盖。导出脱敏回归通过。
- 网络边界隔离测试使用真实提取的请求/解析/轨道方法和原 WBI 签名器，替换 CookieManager、Android Uri 与网络/JSON 输入。WBI 关闭 1 次 playurl；开启首次 1 次 nav + 1 次 playurl，缓存后额外 1 次 playurl、0 次 nav。覆盖匿名签名、会话过期、已认证但服务端仍返回低清，以及签名失败/Cookie 读取失败不回退、不发送 playurl。没有访问真实 B 站账号。
- 最终验证：Flutter 全套 673 passed / 1 skipped；Dart 定向（请求诊断、诊断页面、诊断存储、原生通道、WBI）30 passed；Android JVM 27 passed / 0 failures / 0 errors；flutter analyze 无问题；git diff --check 通过。测试在 Linux 云端完成，不是 Android 真机验收。
- 尚不能把已复现缺陷认定为这位用户的根因。若界面确实显示 360P，优先排查播放请求会话和服务端实际返回；轨道评分缺陷通常表现为画面低清但显示更高档位。还需公开视频 BV/链接、手动选择 720P 后的结果、同账号同视频在官方客户端的结果；不索取 Cookie、密码或 token。
- 安装交付限制：本地无正式签名配置；GitHub 集成无权列出仓库 secret 名称（HTTP 403），未读取凭据、生成新凭据或改动签名/应用 ID/版本。未运行正式发布。dev 后续移植需适配 CookieController 已迁入 `packages/focubili_android` 的模块边界，不能把本修补当成 Beta5 整体合并。
- 云端复现脚本及原始日志：`/workspace/scratch/focubili-360p-investigation/`。`reproduce.py`（原版）与 `reproduce.py --fixed`（修补版）、`request_harness.py` 均只使用合成输入；`cross-version-code-check.json` 记录跨版本代码核对。
