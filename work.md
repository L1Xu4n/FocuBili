# FocuBili 本轮工作记录

## 2026-10-10 · Beta3

按本轮模型要求：主任务 GPT-6 Astra / xhigh；两个只读代码探查子代理 GPT-6 Luna / medium。代码修改、验证和审查由主任务执行。

### 基线核验

- 环境原默认分支 `work` 没有本轮修改。普通 fetch 只更新 master 后，显式 fetch 全部分支。
- 最新 dev `dcb9368f`，master `9156ad9`；dev 包含 Beta1 `99839fa`、Beta2 `1fdf145` 及合并 `77d6f2b`。
- GitHub 工具与 gh 查询开放 PR 均为空。未发现 AGENTS.md 或项目 .agents/skills；已读 CONTRIBUTING.md、CI、后台说明和 Beta2 核验记录。
- 新建独立分支 `codex/beta3-focus-performance`；基线比较放在独立 detached worktree `/workspace/FocuBili-baseline`，未改 dev/master。

### 实现与审查

- 缓存只跳过相同快照的解析，跨引擎边界仍读取；每个 mutation 仍通过原 CAS。应用 action 前清除快照标识，部分 restore 失败前也清除标识，确保回放/回滚不误用缓存。
- 首屏惰性构建、稳定键、紧凑左右排布、响应式按钮；首页卡片复用服务，不新增轮询，保留已读与学习进度独立。
- 复现宽屏动画偏移 293.5px；从提示列分离方向反馈，保留触摸透传和原动画重入逻辑。并非听视频进度问题。
- 自检移除了构建工具产生的 gradlew 权限变化；无凭据、产物或用户数据提交到代码树。

### 验证结果

- 基线定向服务/后台/动画测试 43 通过；本轮最终定向 68 通过。
- 本轮完整 Flutter：799 通过、1 项原字体依赖跳过，0 失败。
- Android JVM：35 通过 / 9 suite，0 失败/错误/跳过。
- Dart analyze、全目录 format、diff check 通过。生产 APK 已构建并核验包名、版本与公开证书。
- 性能：1000次 feed读取的排序列表1000→1；100次无变化重读通知100→0；100次小时内自动刷新通知300→0；首屏卡片预创建500→4（实际挂载4→4）；20个同时刷新调用仍只有20来源请求，并发上限2。
- 真实 Flutter 夹具渲染覆盖390px、320px/180%字号、1280px深色；播放器1600px窗口及缩放/方向切换回归通过。截图、性能原始计数、复现命令见 docs/beta3/README.md。

### 交付边界

- 版本共享 `1.8.0+23`，Android debug `-beta.3`，preview 包名与签名配置保持。
- ARM64 versionCode 2023，公开证书 `5bd1fc4daa8a0887e213c4dc1231d0eba4f7f309a0e64c2d15fe404302bd00b0`，与记录的本地Beta2一致。
- Library 保存返回授权失败；本地同签名 APK 保留。远端使用既有 Actions artifacts，不发布 release。CI 临时签名与通用包23的覆盖限制已写明。
- 本轮无 Windows 真机、Android 真机/模拟器和真实 B站接口验收；CAS/后台回归采用存储与网络替身。Windows CI 中新增 widget 检查，原生编译与真实播放验收分开报告。
- 首次推送被 GitHub 邮箱隐私保护拒绝，改用已核验账号的公开 noreply 身份重新记录本轮提交，未更改账号隐私设置。
- 仅独立分支和 draft PR；不合并、不正式发布、不删除分支。最终提交、PR和实际CI产物链接由任务交付回复提供。
