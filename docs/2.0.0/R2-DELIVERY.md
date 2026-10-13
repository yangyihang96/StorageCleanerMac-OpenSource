# 2.0.0 Beta R2 本地开发交付 — 2026-09-22

**方案尚未全部实现，未达到整体验收或正式发布门槛。** 已实际修改原项目、完成本轮全量本地回归，安装并启动当前开发 Beta。

## 当前运行版本

`/Applications/测试版.app` — 2.0.0，构建 `20260922062756`，Bundle ID `com.local.StorageCleanerMac.beta`，arm64，最低 macOS 14.0。

分支 `codex/2.0.0-beta-r2`，HEAD `6ec0a148c559fd1daf3c5ddf0e43b520cc82c717`，包含保留的原有未提交修改和本轮增量，没有提交或推送。

证据目录：`../StorageCleanerMac-2.0.0-Beta-R2-evidence-20260922/`。`incremental-vs-start.patch` 只对比本轮开始时输入，不将全部 git dirty 归为本轮成果。`unexpected-conflict-copies.json` 另记后出现的 9 个旧副本；原文件保留、明确排除编译。

## 执行与结果

| 检查 | 命令/日志 | 结果 |
|---|---|---|
| Debug 全量 | `swift test --scratch-path /tmp/storage-cleaner-2.0.0-r2 --jobs 2`；debug-full-final.log | PASS，退出 0，2913 项，18 条件跳过，0 失败 |
| Release + 严格并发全量 | `swift test -c release --scratch-path /tmp/storage-cleaner-2.0.0-r2-release --jobs 2 -Xswiftc -strict-concurrency=complete -Xswiftc -enable-testing`；release-full-5.log | PASS，退出 0，2858 项，17 条件跳过，0 失败；编译器并发警告 0 |
| 本地性能保护 | 打包调用 verify_menu_bar_performance.sh；beta-package-3.log | PASS，10 项，历史准备 P95 27.68 ms；不是 UI 输入延迟证明 |
| Beta 优化构建 | `STORAGE_CLEANER_SKIP_TESTS=0 ... ./script/build_and_run.sh --beta`；beta-package-3.log | PASS，退出 0。打包脚本使用 Xcode 27.0 正式工具链；全量回归工具链为 Xcode 27.0 Beta，分别记录 |
| 源码差异 | `git diff --check` | PASS |
| 代码签名 | `codesign --verify --deep --strict`，安装版、ZIP 解包、DMG 只读挂载 | PASS，Apple Development + hardened runtime；不是 Developer ID |
| 更新签名 | `sign_update --account com.local.StorageCleanerMac` + verify + CryptoKit 对照 App 内公钥 | PASS，ZIP/DMG 签名均匹配；没有生成新密钥或改公钥 |
| 版本顺序 | 真正 Sparkle SUStandardVersionComparator | PASS，20260922062756 高于 20260921051316 |
| Gatekeeper 发行判断 | `spctl --assess --type execute`；gatekeeper.log | BLOCKED/rejected，未放宽系统安全设置 |
| Developer ID/公证 | 当前无 Developer ID Application | BLOCKED；未提交公证请求 |
| 真正 Sparkle 升级和重启 | 隔离安装升级回路 | NOT RUN；手动原子替换并启动不冒充自动升级通过 |
| 原 49 项视觉 | 独立验收 | 未更新为通过 |

完整跳过原因和每轮失败/修复日志见 test-results.json。跳过包括 opt-in 私人目录扫描、真实安装器、跑分采集，以及仅在优化构建执行的计时用例；没有删除安全断言或将失败改为跳过。Debug/Release 条件编译的测试数不同，不合并为一个“通过总数”。系统 Contacts 服务产生的运行日志噪声已留本地，不应直接上传原始日志。

## 实机范围

开发机为 M5 Pro、18 逻辑核心、48 GiB、macOS 27.2，单横屏 1352×878 逻辑点、2x。

- PASS：新 App 启动、实际版本显示；设置日夜主题切换；草稿隐藏/取消还原；离开页面确认与继续编辑；静态 MacBook 预览开关；只读系统控制页面。
- PASS（原生内核/fixture 驱动）：生产协调器 Core18 完整调用及 raw-only、全部实际逻辑核心、GPU 离屏/FP32/FP16、存储预算和历史回读相关断言。未通过 App 一键入口采集本轮原始导出，不是正式跑分成绩。
- NOT RUN：真实三级导航 100 次、连续 resize、旋转/负坐标副屏/热插拔、睡眠唤醒、输入到显示 P95、持续内存/唤醒/写盘/能耗对照。
- BLOCKED：普通 M4 mini 与其他 M/SKU/macOS 的实机验收，需对应设备；风扇真实调速未授权且未执行。实际页面显示硬件模式未验证，不能称调速成功。

## 明确未实现的内容

1. 小窗、独立控制浮层仍有固定尺寸约束；尚未满足所有窗口连续调整。
2. 设置预览共用六个概览展示组件，但二三级完整页面还没有全部提取复用；不能声称预览与全运行模式一一对应。
3. 充电控制草稿/在途命令隐藏保护和完整预览副作用探针未补齐。
4. 全页面中英长文本、辅助功能、运行状态文案/主题/素材审计未完成。
5. 回执跨进程写入锁、大规模 CPU 比较开销和完整故障注入矩阵仍需补充。
6. Core18 扩展的 12 项 notImplemented、受控参考校准和发行服务器升级未完成；没有合成总分或声称所有 M 认证。

逐项状态见 R2-WORKSHEET.md；这些缺口是实际工作缺口，不统一归因于缺硬件或证书。

## 产物、体积与哈希

证据目录 `artifacts/`：

- ZIP：`StorageCleanerMac-2.0.0-Beta-20260922062756.zip`，34,281,099 bytes；SHA-256 `b0e0d754c03ce8ed84aacb6fff0a8332629bddad3fc6f06b398646da00a6efa0`。
- DMG：`StorageCleanerMac-2.0.0-Beta-20260922062756.dmg`，35,397,331 bytes；SHA-256 `95a73df2aaafe10198cec9fdf012e93463526335b4379bef71e052df81417ca6`。
- 安装 App：逻辑大小 77,376,493 bytes、实际分配 77,668,352 bytes；前版逻辑 76,751,407 bytes、实际分配 77,041,664 bytes。没有宣称包体积缩小。

本轮仅更新 /Applications/测试版.app；原正式版没有覆盖，正式/Beta appcast 都没有修改，没有 push/tag/Release/上传或收费 CI。读取过官方文档，并使用缓存/依赖获取，不应称“完全没有联网”。

## 回退与证据保留

原安装版暂存于 `/tmp/storage-cleaner-r2-install-backup-20260922/测试版.app`，不作为第二个安装入口使用；保留到当前开发安装回读和用户验收稳定后再清理。回退前正常退出 Beta，并连同受影响的偏好/回执数据评估兼容性；不要用旧程序操作新追加日志的恢复。

新清理回执的 `.json` 与 `.events` 必须一起保留；`.index` 可再生。旧 JSON 不重写、不删除有效历史；坏尾部保留，不自动截断。恢复仍重验身份，不覆盖新同名文件。应用版本、跑分协议、回执事件版本分别管理。

正式候选必须在余下 P0/导航/UI 门槛完成、M4 mini 验收后冻结源码，重新构建正式身份，并独立通过签名、公证、Gatekeeper、升级与数据保留。不能将此 Beta 简单改名发布。

## 编译输入与协议指纹

`compiled-input-manifest.json` 的 SHA-256：`7bf0d691eedd315df89090185fa2630a5b47b97d7a160d5e3bc459ed290d451f`。该清单在打包后核对现有生产输入；此后只更新交付文档，没有改动已安装的生产实现。

Core18 保持 `mseries-result-v10-draft2` / `mseries-core18-v10-draft2`，固定素材 `procedural-mit-seed-619a27de-v1`，实现族 `native-c-metal-posix-v1`，参考 `unavailable-raw-only`；合同 SHA-256：`c8b75dff7897d6ff8055d51fdf37afce20d1b656037e042a98c68e03e9083318`。本轮没有借应用版本升级重标旧成绩。

## 2026-09-22 用户要求清理后的产物状态

按用户要求删除其他 12 份测试版 App 副本、8 个测试版 ZIP/DMG 安装包及 4 个签名附件，包括上述临时回退副本。本文此前的安装包哈希保留为历史构建证据，对应文件及旧版回退 App 已不再保留。当前唯一测试版为 `/Applications/测试版.app`（2.0.0，构建 20260922062756），可执行文件哈希未变化，严格签名验证通过，原进程继续运行。源码、交接材料、正式版和用户数据未删除。逐项删除记录见证据目录 `cleanup-20260922.json`。
