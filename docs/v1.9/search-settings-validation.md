# 搜索设置迁移的纯校验 API

分支 `codex/v19-search-settings` 从 `3f104aa` 创建；本提交不修改普通浏览读取、1.8 候选设置服务或 integration。

公开入口：`SearchContentFilter.fromJsonStrict(Object? value)`，参数为已解码的 JSON 值。返回经过关键词正常化的不可变规则；错误根类型、未知字段、缺失必需字段或错误值抛 `FormatException`。该入口不访问偏好、账号、网络或文件。

最终基线合入后，`SettingsTransferService._validateValue` 的 `search.content_filter_v2` 分支可直接调用：

```dart
SearchContentFilter.fromJsonStrict(decoded);
```

规则契约：

- 仅接受 `learningOnly`、`minimumPlayCount`、`titleKeywords`、`ownerKeywords` 四个字段。
- `learningOnly` 必须为 bool；`minimumPlayCount` 必须为 int，且在 `0..SearchContentFilter.maximumPlayCount`（含两端）内。
- 旧两字段格式仍有效；两个关键词数组可以分别缺省，缺省得到空数组。字段存在时，null、不为 List 或任意非 String 元素均拒绝，不静默删项。
- 合法关键词使用现有 `parseKeywords`，修剪空格、拆分已有分隔符、忽略空词、按大小写无关方式去重；保留首次出现的写法和词序。结果不保留输入可变列表引用。
- 本 API 不新增比现有设置文件体积上限更严格的项数或字数限制。迁移文件的体积控制仍由设置迁移服务负责。

普通浏览的 `SearchContentFilterService.load()` 继续使用原有容错逻辑；迁移服务不要通过容错读取来判断导入值是否合法。本 API 不把黑名单纳入设置重置。

验证仅使用合成内存对象：

- `flutter test --no-pub test/search_content_filter_validation_test.dart`：19 项通过，退出码 0，`All tests passed!`。
- `dart analyze lib/models/search_content_filter.dart test/search_content_filter_validation_test.dart`：退出码 0，`No issues found!`。
- `git diff --check`：通过。

未运行全量测试，未读取真实偏好或账号数据。
