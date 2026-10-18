# 当前整合与历史候选证据：9c7 / 080 / d605961

当前前置源码为 `9c7ea4b894e3c790e0a8ecf57d104f54b663add1`：已通过两亲普通合并纳入实际维护 B=`f868ef67d92f3504ea5b6f445864141b804e61f4`，树 `eb0055cf574401ac3f2779a52b41aed88ace193b` 与 080 精确相同。080此前普通合并dev52，已有55 Python/3 Dart发布配置定向验证；这些不是本次重跑，也不是P/B的全量Flutter/native验收。下表1600/2/0、analyze和format仍仅属于历史d605961，原9bc/f6d等文档基点记录保留在progress历史中。维护已完成，最终安全source H+D3、实际精确CI/native候选、Beta实包及预发布仍pending；1.9未公开。本任务只更新四份文档，没有测试、构建或远端操作。

| 核验 | 实际证据与边界 |
| --- | --- |
| 完整 Flutter | 根 `flutter test --no-pub --reporter expanded`：**1600 passed / 2 skipped / 0 failed，03:28，exit0**。日志 `task-5/v19-candidate-cleanup-full-tests.log`，SHA-256 `54054de52102a94af44dfd8d1b9181c267c01cf991fdcf02621f0903cc028e2a`；末尾结果与consolidated JSON一致。 |
| 静态分析 | 根 `flutter analyze --no-pub`：**no issues，25.5s**。日志 `task-5/v19-candidate-cleanup-analyze.log`，SHA-256 `2ae8bb6f56d3a67003d35c63f837d6ab8ab1a24dc111cee171f1cdf1382deee6`。 |
| 格式 | 根 `output/current-consolidated-test-evidence.json`记录 **492 files / 0 changes**；完整formatter调用未附，不另行猜测或重跑。 |
| 两项跳过 | Windows symlink：日志第1425行明确 `Skip: Creating symlinks requires Windows developer mode`；可选截图生成按 `test/v19_focus_learning_evidence_test.dart:18,129` 的 `V19_EVIDENCE` 默认关闭条件归因，正常命令未开启、所需字体存在。并发expanded reporter没有独立命名该截图skip，不能借相邻测试名归因；未改系统/权限。 |
| 身份门修复 | 原 `b07db359c5000efac6aab6ee0ed1276c7f163ac9` 已在 `e04e783870b5c6d0c4b110a0675baace6a675eae` 整合；d605祖先检查通过，原修复与整合提交的 `app_update_service.dart` 相同，d605全量包含该修复。原90项定向记录保留。 |
| 正式 1.8 M 与发布 | PR #64 已合并，**M=`5a76dbba192660f652fbd09d38c78eea6a10ffb5`**；注解标签对象 `b60ea6a93ea47ec8a222ccb5974f025f16104537` peeled 到 M。[v1.8.0](https://github.com/L1Xu4n/FocuBili/releases/tag/v1.8.0) 现有 **6 个公开资产、5 个平台**；从 M 原 CI 补充了 Windows portable ZIP 与 iOS unsigned device IPA，原四资产的 ID/大小/digest、M、标签和 stable latest 不变。原四项历史 live **70/70** 保留；新增 Windows 静态 **23/23**、iOS arm64/平台2/source/time 严格验证及独审通过，两份新增资产匿名下载 SHA256 匹配。iOS 是公开未签名 device IPA，仍需自己的签名/provisioning，不是真机安装验收。见[公开事实 receipt](v18-formal-release-receipt.json)。 |
| 当前 1.9 整合 | PR66 → D2 `2f41b5cd9a2f06498263a9f2cf41457fc8d6b5a6`；PR67 → dev52 `52d947a8c1eb0ec5bdacd8ec213a68745980beba`；PR68于08:34:45Z → **B `f868ef67d92f3504ea5b6f445864141b804e61f4`**。14 checks成功、独审P1/P2为0、未解决threads为0；B树 `a1fc9d499ae81d75f739fbbb3e6a3da9f5149549` 精确等dev52/已审9c。私有080的两父为ba50b8d/dev52；9c7的两父为080/B，树与080相同。 |
| 既有维护配置定向验证 | `output/v19-maintenance-080ecdf-verification.json`，SHA256 `42478c551e3b77b258e764187ce23ce612db73b4f6f3b7240899e771bc40e6a3`：080上55 Python、3 Dart通过，命令/日志hash见progress第52项。报告当时B尚待PR68；后续实际B见receipt维护记录。没有P/B全Flutter或native重跑，不与d605的1600/2/0相加。 |
| 人工清单 | 对照补丁基点bfdc，原31条与附加14条checkbox的UTF-8字节逐条相等；**45未勾 / 0已勾 / 设备0**。 |

[progress.json](progress.json) 保留旧1353、旧计数断言失败1487/2/1、随后3f的1488/2/0、599的1585/2/0及各独立定向/native记录。所有历史checks保留，旧验证不能相加，也不能替代d605或最终发布source的证据；visual仍为历史预览，交由父任务最终更新。

公开 [#61](https://github.com/L1Xu4n/FocuBili/issues/61) 最新只读记录为 **2026-10-18 06:52:46 UTC** 的 `task-5/output/v19-issue61-final-refresh.json`，SHA-256 `6d1a10a45d7e711ad7b0c4aef2675197d53c9fe81f385717ff576e1a93c1dbd0`。此前 #61/#56/#60/#58/#50 的 **04:49:46–47 UTC** 记录继续保留：`task-5/output/v19-final-issue-evidence.json`，SHA-256 `deb68eb2ad2d1a481a4cf53e791c9479299dca5b6c6a498964833990190cc739`。#61 最新仍是维护者 [10月17日追问](https://github.com/L1Xu4n/FocuBili/issues/61#issuecomment-6231343140)，没有报告者补充平台、App版本、步骤或导出故障录屏；**未确认/复现Mac导出故障**。#58 自己fork的安卓反馈不计作本候选真机通过；本次文档只读取现有记录，未重新联网查询、评论或联系报告者。

正式 M 的6资产/latest事实保持不变，维护 B 已完成并普通合入私有9c7。1.9 工程发布仍须审计安全 source H+D3、精确 source 必要/native 候选 CI、有效签名、递增 code2026、ABI、BuildTime/source 与实包 SHA/bytes 对应，并仅 prerelease、保持正式 1.8 latest。当前 `source/finalCI/release/newApk` 仍 pending；M 的 70 项验包结果不替代 1.9 候选 CI 或实包验证。设备0、原 #61 待调查和旧 Beta 证书不兼容是人工/安装风险，**不单独要求等待人工或报告者才发 Beta**；不换 key、不改严格直链保护，不卸载旧应用或清数据，可在空白专用环境测试。

本次读取的consolidated JSON更新时间为 `2026-10-18T05:32:46.112887+00:00`，文件SHA-256 `091fcd1eab26c078da2a91be5daeec19dca75a92637475bfbe9eff144d6a2252`；这是可变output记录的当时快照。覆盖升级只限**同包名、同签名、构建号递增且已安全备份合成资料的独立测试环境**，不对旧Beta做强行覆盖，不卸载、不清数据、不导出真实用户资料。
