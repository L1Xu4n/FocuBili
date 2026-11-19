# 搜索：视频 / 用户切换与视频多分区

已提交的关键词会随视频、用户标签切换立即搜索。尚未提交的输入保留在搜索框，不会被标签切换自动发送。BV 或课堂直达不发往用户查询；用户搜索的筛选不含内容分区。

视频可选择一个或最多五个分区。“全部”和单区仍走原有单次查询；只有多选才按分区查询。关闭筛选面板不会应用草稿。

## 查询与排序依据

[哔哩哔哩开放平台文档](https://openhome.bilibili.com/doc)没有公开本站通用关键词搜索的多值分区契约，[B 站公开搜索页](https://search.bilibili.com/all/)也未说明此契约。开发环境的匿名请求工具没能读取该搜索端点，因此不宣称服务端不支持或支持多值。实现复用仓内已有的单个 `tids` 请求，每个分区保留独立页码，单轮每区至多一页，页面同时最多三个分区请求。不会先查询全站再筛，也不为排序批量补详情。

- 默认将各区的名次交替合并：先第 1 页第 1 位，再第 1 页第 2 位；同名次按分区编号稳定排序。不是 B 站官方跨分区综合排序。
- 播放、弹幕、时间、收藏使用已加载的可用数值，平局按同一名次规则。缺发布日期或收藏数时排在有数值的结果之后，再按分区名次；没有收藏数不按零收藏处理。
- BV 号去重；普通下一页跳过失败和结束的分区。某个分区出错，已经加载的结果仍保留，只重试该分区的失败页。
- 本机筛选和黑名单作用于加载过的结果，松开本机规则时可直接恢复，即使网络不可用。多选时不会为要求过滤而连续自动抓空页；可主动继续加载。

## 可复现画面

以下图片是实际 Flutter 搜索页面用合成结果渲染所得，未连接 B 站账号或真实流量。用两个明确已选分区（知识、科技）演示一次请求失败；只重试科技后，两个分区的结果一起显示。

- [修复前的单选分区](before-choices.png)
- [修复后同时选择两个分区](after-choices.png)
- [科技分区失败时保留知识结果](after-partial.png)
- [单独重试后保留两个分区](after-recovered.png)

```sh
mkdir -p /tmp/focubili-search-evidence
FOCUBILI_SEARCH_EVIDENCE=/tmp/focubili-search-evidence \
  FOCUBILI_DESKTOP_INPUT_FONT=/path/to/NotoSansCJK-Regular.ttc \
  FOCUBILI_DESKTOP_INPUT_ICON_FONT=/path/to/MaterialIcons-Regular.otf \
  flutter test test/search_modes_multi_category_test.dart --plain-name 'multi-category search raster evidence'
```

截图变量可选，图标字体来自 Flutter SDK 的 `bin/cache/artifacts/material_fonts`。修复前用同一测试文件从 `c16a52f` 的独立工作树重放。通过可注入的真实请求组装代码断言 URL 和页码；界面与失败响应均为测试夹具，未对真实 B 站请求重试或抓取。
