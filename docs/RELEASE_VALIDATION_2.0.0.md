# 2.0.0 发布验收

版本：2.0.0；Build：20261012230050；源码标签：`v2.0.0`（提交 `54504911`）；上一公开版本：1.10.1（Build 20260921051138）。

本记录分开说明源码回归、测试版实机检查、正式包、公开发布和更新实测。原定 49 项严格视觉验收另行进行，不能用本次测试结果代替。

## 授权

2026-10-13，所有者检查已安装的 2.0.0 测试版后回复“合格”，选择正式发布 2.0.0，条件与 1.9.13 相同：Apple Development 签名，不做公证，也不 staple。源码发布与 appcast 条目一次完成；允许用本机正式安装（`/Applications/存储清理助手.app`，公开版 1.10.1）做 Sparkle 真实升级验收。访达右键卸载（D88）和系统照片图库（D89）不进入正式版。

## 发布中发现并修复

第一次正式打包（提交 `8f97f91b`）在最终核对时失败：主程序记录的链接 SDK 是 14.0。逐项对比已验收的测试版后发现，`make_release_dmg.sh` 没有跟上 2.0 的开发：正式包缺少文件操作助手及其 LaunchDaemon、更新授权助手、`BuildInfo.plist` 和 `NSAppBundlesUsageDescription`，同时缺 `-platform_version` 链接参数。若照此发布，正式版的卸载、应用更新等受保护操作会失败。该候选包已作废，未上传。

修复提交 `54504911` 补齐上述组件，以及签名、归档核对和守卫测试 `ReleasePackagingParityTests`。把脚本换回修复前的版本，新测试会出现 20 处失败。核对同时要求正式包里不含扩展、不含照片权限。`v2.0.0` 标签原先指向 `8f97f91b`，那时只推送到私有源码仓库，没有任何 Release 或安装包引用它；经所有者同意，标签已移到 `54504911`。

## 验证状态

发布提交 `54504911` 本地门禁（2026-10-13 11:21–11:54）：

| 项目 | 结果 |
|---|---|
| Release 全量测试 | 5061 项，跳过 24 项，0 失败 |
| Debug 全量测试 | 5474 项，跳过 25 项，0 失败 |
| 严格并发编译、测试版配置构建 | 通过 |
| 源码守卫（views-process、purge、private-api、conflict-copies、diff-check） | 通过 |
| 小窗性能（16 项） | 1 项失败：`testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets` 测得 187.66 ms，预算 100 ms |

- 小窗性能失败发生在机器负载约 10 的时候，当时 Google Drive、OneDrive、powermetrics 和其他自动化会话都在运行。空闲时重跑 3 次分别为 81.3、90.5、92.4 ms，全部通过；修复前的提交 `8f97f91b` 门禁测得 101.96 ms，重跑为 81.7、89.6、103.0 ms。预算没有放宽，这项记为“不稳定，已披露”，并已另开任务恢复余量。没有运行 GitHub Actions。
- 测试版（同源 2.0.0）性能测试的标准流程跑完 18/18 项，用时 4 分 12 秒，其中持续阶段为 CPU 90 秒和 GPU 90 秒，没有跑 600 秒长时压力测试。系统助手没有重新连接，所以功率、频率和能效没有读到，分数显示“待校准”。
- 新发现的已知问题：跑分结果“保存失败”。原因是 `BenchmarkV7HistoryRepository.v11BudgetedResults` 用 1 MiB 预算衡量整个历史文件；测试版的历史文件为 1.55 MB，正式版为 1.31 MB，所以新结果都存不进去。这一点已在发布说明中披露，修复另行安排，没有为通过而放宽预算。

## 正式包

| 文件 | 字节 | SHA-256 |
|---|---:|---|
| StorageCleanerMac-2.0.0.dmg | 51774654 | `e8499d180f0bef5b3faa204ce9bb8a867263a578fc58a43fbb4c2e3c3dde2bb1` |
| StorageCleanerMac-2.0.0.zip | 51745098 | `4704de426da5bc7cb9ef3b9d6101747737619092c7f7e5183b4fa03845ed4a81` |
| StorageCleanerMac-zhHans-2.0.0.dmg | 51774727 | `1b4cf5a9dacb7f0d1591ea4289bd41351244fcb29278075b4ab3819d419fbace` |
| StorageCleanerMac-zhHans-2.0.0.zip | 51745149 | `ac29b286908f9b1009f67fe1d31989541ecbbfaa16be2f54104a723b4a387a58` |

- 4 个归档逐个解开或挂载核对：元数据、arm64、macOS 14+、链接 SDK 27.0、严格签名、资源与源文件逐字节一致，均通过；ZIP 内 `BuildInfo.plist` 记录的提交为 `545049117b24`，工作区干净（dirty=false）。
- Sparkle EdDSA：使用现有应用账户（`com.local.StorageCleanerMac`）签名；Sparkle 工具验证与 CryptoKit 用应用内嵌公钥验证均通过。
- Gatekeeper：`spctl` 拒绝（未公证），与授权条件一致。

## 公开发布与更新

- 2026-10-13，在 `StorageCleanerMacUpdates` 创建正式 Release `v2.0.0`（Latest），上传 4 个归档和 `CHECKSUMS-SHA256-2.0.0.txt`。用匿名方式下载全部 5 个文件，字节数与本地一致，SHA-256 校验全部通过。
- 正式 appcast（`appcast.xml`，Updates 仓库提交 `5c9308f`）在最前面新增 2.0.0 条目：Build 20261012230050，长度 51745098，带 EdDSA 签名，最低系统 14.0，仅 arm64。历史条目没有改动，`appcast-beta.xml` 也没有改动。匿名读回能看到新条目。
- 源码仓库创建 Release `v2.0.0`，不带附件，下载链接指向 Updates 仓库。
- 公开源码：所有者 2026-10-13 授权后，把脱敏的源码快照发布到 `StorageCleanerMac-OpenSource`，并建 `v2.0.0` Release。源码输入清单见 [manifest](releases/2.0.0-source-manifest.json)：1431 个文件，取自 `v2.0.0` 标签，聚合 SHA-256 为 `00e8717a5da7c3e74281e5c749a1586cb6000937bce61096ff9268d5d3c7100c`。脱敏只涉及文档中的个人路径和签名身份，不改动清单范围内的代码。
- 本机正式安装做了 Sparkle 实测（1.10.1 → 2.0.0）：
  - 工具菜单的“检查存储清理助手更新”能发现 2.0.0，并显示发布说明；
  - 点“安装更新”后完成下载和校验，再点“安装并重启应用”；
  - 应用已替换并自动重启，版本为 2.0.0 / 20261012230050，`BuildInfo` 提交 `545049117b24`；
  - 严格签名校验通过，`/Applications` 下只有一份；
  - 已安装的应用与发布 ZIP 解开后逐文件一致。
- 用户数据：`~/Library/Application Support/StorageCleanerMac` 中 19 个文件全部保留，跑分历史等文件的哈希不变。有变化的只是应用重启后正常写入的监控、容量和健康记录，记录条数与升级前相同。
- 没有实测：取消更新、下载损坏、签名错误、替换失败。

## 未完成或限制

- 访达右键卸载、系统照片图库只在测试版提供。
- 跑分历史超过 1 MiB 后，新结果无法保存（见上文）。
- 小窗长历史准备时间的性能测试不稳定（见上文）。
- Firefox Cookie、云盘和跨卷上的项目产物、扫描中途取消，均未实机验证。
- 失败恢复路径（下载损坏、签名错误、替换失败）未在隔离环境中实测。
- 原始诊断、设备性能记录与屏幕证据保存在本机，不随公开 Release 上传。
