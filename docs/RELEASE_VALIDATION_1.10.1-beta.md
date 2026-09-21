# 1.10.1 Beta 发布验证 — 2026-09-21

## 当前快照

- Version `1.10.1`，Build `20260921041501`，tag `v1.10.1-beta.20260921041501`。
- 此次归档当前已验证的 Beta，应用名称为 `测试版.app`，Bundle ID `com.local.StorageCleanerMac.beta`；最低 macOS 14，下载二进制为 arm64。
- 公共源码快照基于既有开源提交 `b9a152b44489ed75be6b7c5acc612620eb5c680f`，保留公开历史，不导入私有仓库历史。开发工作区保持原状，不 reset/clean。
- 原 App 的 BuildInfo 如实保留本地构建时的父提交和 dirty 标志；它不是这次发布提交的标识，也不声称可按位重现。外部 [源码清单](releases/1.10.1-beta-source-manifest.json) 将已验证的 700 个实际构建、资源、测试和服务端输入与公开快照关联。
- 输入清单聚合 SHA-256：`a698daf75d12a134bc05c7c0f48c29bf45ce62b4c11b5fc5f5dc14826c630a31`。
- App 可执行文件 SHA-256：`1e8064b46880a6e3337f03f20b5b58eabce90a7afb4a5927002b5af452dd18c8`。
- Beta 自动更新关闭，无正式版 appcast；不修改稳定版 `1.9.13`、正式安装或服务端部署。

## 本地检查

下列 App 检查是 2026-09-21 最终源码的真实运行结果。发布前逐文件核对上述 700 项，无差异；仅更新发布文档。日志保存在本机，公开记录不包含私人路径或进程信息。表中临时路径经过脱敏。

| 检查 | 本地执行方式 | 结果 |
| --- | --- | --- |
| Debug 完整测试 | `swift test --scratch-path <local-scratch>/debug --jobs 2` | exit 0；2891 项，18 跳过，0 失败 |
| Release 完整测试 | `swift test -c release --scratch-path <local-scratch>/release --jobs 2` | exit 0；2836 项，17 跳过，0 失败 |
| 严格并发构建 | `swift build --scratch-path <local-scratch>/strict --jobs 2 -Xswiftc -strict-concurrency=complete` | exit 0 |
| Beta 构建及打包门槛 | `bash script/build_and_run.sh --beta` | exit 0；优化配置的性能门槛 10 项，0 失败 |
| 服务端本地测试 | 在 `Server/BenchmarkLeaderboard` 中执行 `npm test -- --reporter=dot` | exit 0；5 个测试文件，106 项通过 |
| 服务端类型检查 | `npm run typecheck` | exit 0 |
| 归档签名完整性 | ZIP 解出与 DMG 只读挂载后分别执行 `codesign --verify --deep --strict --verbose=2` | exit 0 |
| 归档内容 | ZIP/DMG 内 App 的文件哈希、链接、类型、权限与当前已安装 Beta 比较 | 203 个条目完全一致；原安装未变 |
| DMG 容器校验 | `hdiutil verify` | exit 0；只读挂载检查后卸载 |

跳过项目需要显式启用真实应用、浏览器、登录项、Setapp 或目录扫描，真实下载/安装，旧协议实机捕获、能耗或 UI 测量；不为发布而触碰用户数据。部分性能计时仅在优化构建的专用入口执行。Debug 与 Release 有不同条件编译，测试数差异不表示跳过失败项。单元测试不替代实机视觉、性能或硬件认证。

## 实际界面与未完成项

- 同一 Beta 的浅色主窗口 14 个功能页面、6 类小窗二级/三级详情已实际查看；浅色运行/结果界面及明暗切换保持状态已检查。保留原素材和深色设计。
- 独立风扇/硬件控制浮层没有取得足够的实际窗口截图，仍待视觉验收；未为验收修改真实风扇或电源策略。
- 原 49 项黄金视觉验收继续独立，不能由本地构建/测试替代，本次未将其标记完成。
- 小窗真实端到端输入到屏幕的 P95、长期内存与功耗对照尚不完整；自动性能门槛不能代替这些测量。
- Core18 的本机一键运行及取消保留历史来自前一日的真实验证；本次浅色/发布步骤不重复运行压力测试。只有当前一台 Apple silicon Mac 的运行证据，M1、Max、Ultra 等其他机器仍待实测。

## Core18 协议边界

公共 Core 已接入 CPU 单/多线程共 8 项、GPU 3 项、内存 3 项、私有磁盘 4 项的真实内核；还有 CPU 线程曲线和短持续观察。固定素材为许可明确的程序生成数据。详情见 [协议记录](integration-20260919/PROTOCOL.md)。

- schema：`mseries-result-v10-draft2`
- plan：`mseries-core18-v10-draft2`
- workload：`mseries-fixed-kernels-v1`
- fixture：`procedural-mit-seed-619a27de-v1`
- implementation family：`native-c-metal-posix-v1`
- stats：`median-mad-all-samples-v1`
- scoring：`weighted-geomean-20-20-25-20-15-draft1`
- reference：`unavailable-raw-only`
- Core contract hash：`c8b75dff7897d6ff8055d51fdf37afce20d1b656037e042a98c68e03e9083318`

生产参考尚未校准，所以只保留原始单位和样本，没有总指数。GPU 高级/光追、工作集与队列深度曲线、媒体、AI、显示节奏及功耗效率扩展未完成，不能归类为硬件不支持。新协议服务端只在本地验证，提交关闭且未部署，不会降级混榜。旧 v7/v9 记录保持只读兼容。

## 真实签名与分发状态

- App：Apple Development 签名，hardened runtime 开启；嵌套签名完整性通过。
- Developer ID 发行签名：未完成。
- Apple 公证/staple：未完成。
- Gatekeeper 发行评估：exit 3，拒绝；其他 Mac 可能阻止打开。不得称为已获 Apple 发行批准，也不要求降低系统安全设置。
- ZIP/DMG：当前签名 App 的本地归档；DMG 没有单独的 Developer ID/公证。SHA-256 用于下载完整性，不是发行身份认证。
- Sparkle：Beta 没有发布归档签名或 appcast，没有进行正式版自动升级重启验收。
- GitHub：发布目标为公开源码仓库的 **prerelease**；仓库级 Actions 关闭，未开启或运行 GitHub 构建/测试。远程发布与附件回读另有本机回执。

## 安装包校验

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `StorageCleanerMac-1.10.1-beta-20260921041501-arm64.dmg` | 35166527 | `bf71400ad18e98a07ae0db3e8f522e95de64a94733742a6f0c6c2c9caa7d587f` |
| `StorageCleanerMac-1.10.1-beta-20260921041501-arm64.zip` | 34019142 | `1751ae10db1e4ea226724535b60b1fa9b00cacd0a78d04a697d846708fb7f794` |

压缩包内附 MIT 许可证、第三方声明及安装说明。只替换同名测试版，保留正式版；不合并 `.app` 包内文件。
