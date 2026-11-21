# FocuBili v1.9.0 Beta 5 候选

计划构建号 `2030`，仅用于下一轮私用预览准备。本文不是发行公告；最终功能以整合后通过验收的签名构建为准。上一轮 Beta 4（`2029`）不变。

<!-- focubili-update-summary:start -->
- 首页从底部「自定义」进入编辑；隐藏全部卡片后，可从底部小抽屉恢复编辑。
- 已购课堂显示封面，并可按课程名或简介搜索当前账号的已购课程。
- 播放器的三点菜单集中常用工具；在长视频画面上横滑可看当前分 P 的缩略图。拖动底部进度条不显示缩略图。
<!-- focubili-update-summary:end -->

## 已合入本候选基线

- 首页普通态不再显示卡片设置，编辑时才可选择收藏与关注来源。隐藏最后一张卡片只关闭抽屉，点底部小抽屉回到编辑，不替你添加卡片。[#127](https://github.com/L1Xu4n/FocuBili/pull/127)
- 已购课堂的搜索在本次加载的全部已购课程里查找，不随输入重复联网；切换账号不会沿用旧列表。收藏、UP 主资料与学习清单也有新的操作入口。[#116](https://github.com/L1Xu4n/FocuBili/pull/116) · [#117](https://github.com/L1Xu4n/FocuBili/pull/117) · [#118](https://github.com/L1Xu4n/FocuBili/pull/118)
- 播放器功能分组独立显示。横滑画面时，有图集则预览当前分 P，图集不可用仍显示时间；没有新增拖动进度条的预览。已有笔记可追加当前画面。[#126](https://github.com/L1Xu4n/FocuBili/pull/126) · [#128](https://github.com/L1Xu4n/FocuBili/pull/128) · [#131](https://github.com/L1Xu4n/FocuBili/pull/131)

## 拟纳入，仍需在最终构建验证

- 首页收藏、关注卡片编辑时先选「仅显示快捷入口」或「添加自选」。点已有项目的名称或图片会打开详情，只有点加号才添加，最后点保存。上拉抽屉时欢迎区恢复随手势下坠、模糊和渐隐，卡片保持清晰。[#132](https://github.com/L1Xu4n/FocuBili/pull/132) · [#141](https://github.com/L1Xu4n/FocuBili/pull/141)
- 触屏双击快进、快退的反馈不再被控制栏压扁，跳转手势不变。桌面鼠标单击播放或暂停、双击切换全屏；不按键悬停在进度条可看时间和可用的采样帧，按下拖动时收起预览。A–B 自动回跳不弹出播放或暂停反馈；点铅笔向下展开时间编辑，全屏可长按右侧把手移动。[#119](https://github.com/L1Xu4n/FocuBili/pull/119) · [#134](https://github.com/L1Xu4n/FocuBili/pull/134) · [#139](https://github.com/L1Xu4n/FocuBili/pull/139)
- 视频标签默认点开才显示，同次观看保持，可在设置中改为默认展开或隐藏。横屏笔记点外侧只收起，不暂停或跳转；点右侧把手继续原草稿。播放器新建 B 站收藏夹可选公开或私密，取消不创建，选私密失败不会转为公开。[#122](https://github.com/L1Xu4n/FocuBili/pull/122) · [#130](https://github.com/L1Xu4n/FocuBili/pull/130) · [#133](https://github.com/L1Xu4n/FocuBili/pull/133)
- 来源条和订阅时间线拟一起交付。订阅更新超过 14 天自动隐藏，已读、未读相同；不动订阅源、收藏、笔记、学习清单和播放历史。多分类搜索和屏蔽规则以整合验收为准；屏蔽成功的提示通常会自动收起，无障碍导航开启时仍可手动关闭或撤销。[#135](https://github.com/L1Xu4n/FocuBili/pull/135) · [#137](https://github.com/L1Xu4n/FocuBili/pull/137) · [#138](https://github.com/L1Xu4n/FocuBili/pull/138) · [#140](https://github.com/L1Xu4n/FocuBili/pull/140)
- 可选的 HTTP User-Agent 设置用于普通接口与已确认的普通视频播放信息请求。留空沿用原行为，不影响登录、课程和受保护播放，不会在请求被拒绝时轮换或重试，也不保证解决 HTTP 412。[#136](https://github.com/L1Xu4n/FocuBili/pull/136)
- Android / Windows 拟提供已购非 DRM 章节的本机缓存。须为当前账号已验证购买、可完整播放、没有已知保护或禁止缓存的章节。无客户端自设的 24 小时期限或每日联网要求；服务端明确给出的购买或离线截止仍有效，下载地址的临时有效期只约束请求。已知到期、权限撤销、试看或受保护内容不走这条路径；不导出、不绕过限制。获得播放权限不等于获准使用第三方离线功能，请遵守[平台协议](https://www.bilibili.com/blackboard/topic/activity-6yl-8aM9C.html)和课程提供方许可。现有验证使用合成授权及本机媒体，尚未用真实付费账号或 Android / Windows 真机验证完整流程。

## 安装与验收边界

Android 候选沿用 `com.focubili.app.preview`。只有实际产物使用与官方 Beta 4 相同的签名，且 `versionCode` 从 `2029` 增至 `2030`，才具备覆盖更新条件；正式版仍与预览并存。签名不一致请不要先卸载旧包，先备份资料。此准备只核对版本元数据和测试，不生成 APK 或安装包，不代表签名、实机升级、最终整合或发布已完成。
