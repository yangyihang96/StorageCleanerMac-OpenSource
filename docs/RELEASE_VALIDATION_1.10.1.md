# 1.10.1 应用内更新发行记录 — 2026-09-21

本次修复“GitHub 有下载包，应用内却检查不到新版”的发布链路。不是对整轮 UI、Core18 或性能任务的完整验收。

## 实际改动

- `AppUpdater` 对正式版、测试版都启动原生 Sparkle，并保留其默认兼容版本选择；不自行下载安装或绕过验证。
- 正式版 Bundle ID `com.local.StorageCleanerMac`，Build `20260921051138`，继续读取原 `appcast.xml`。
- 测试版 Bundle ID `com.local.StorageCleanerMac.beta`，Build `20260921051316`，读取独立 `appcast-beta.xml`；自动检查开启，自动安装关闭。
- 两个更新包均采用旧正式版公钥对应的 Sparkle EdDSA 签名；公钥 `9zE8Bh4PM/yp47qqC5RmAVnvkrqlX7TtT7POVCz2wEo=`。密钥只在本机钥匙串中由 Sparkle 签名工具使用，不导出、不上传。
- 老测试版的二进制禁用了更新器，因此首次必须替换本次测试版，远程更新源无法自行解除旧代码拦截。正式版保持原更新地址，无须手动改配置。
- 构建脚本的 `STORAGE_CLEANER_SKIP_TESTS=1` 仅在明确指定时跳过测试并打印 NOT RUN；默认仍运行原门槛。签名、架构、最低系统与更新配置检查不跳过。

## 本次执行

**用户明确要求不跑测试，本次没有运行单元测试、回归测试、性能测试或 UI 测试套件。** 上一 Beta 的测试数不作为此修订通过证据。

| 操作 | 结果 |
| --- | --- |
| `STORAGE_CLEANER_SKIP_TESTS=1 bash script/build_and_run.sh --beta` | 本地 Release 优化构建，exit 0 |
| `STORAGE_CLEANER_SKIP_TESTS=1 BUNDLE_CONFIGURATION=release bash script/build_and_run.sh --bundle-only` | 本地正式身份构建，exit 0；没有启动或覆盖正式安装 |
| 两个 App 的 `codesign --verify --deep --strict` | exit 0；包括解压 ZIP、只读挂载 DMG 中的 App |
| ZIP 与 DMG 内容 | 每个通道 203 个条目的文件哈希、类型、链接与权限匹配其构建 App |
| `sign_update --account com.local.StorageCleanerMac -p <archive.zip>` | 两个更新 ZIP 均签名成功 |
| `sign_update --account com.local.StorageCleanerMac --verify <archive.zip> <signature>` | 两个更新 ZIP 均验证成功 |
| Gatekeeper 发行评估 | 两个 App 均 exit 3，拒绝；未公证 |
| GitHub Actions | 源码与更新仓库均关闭，不使用远端构建/测试额度 |

公开源码输入见 [manifest](releases/1.10.1-source-manifest.json)，共 700 项；聚合 SHA-256 `d424ae976e0f5ccbdd9a40c364ee8fe1401efec822ed6b37dfd01e88b52073d6`。App 原始 BuildInfo 如实保留本地构建时父提交与 dirty 状态，不改写成事后发布提交，也不声称按位可重现。

## 发行边界

- 使用 Apple Development 签名和 hardened runtime。缺少 Developer ID 发行证书、公证和 stapling；其他 Mac 可能阻止打开。更新包签名通过不是 Gatekeeper 发行批准，不降低系统安全设置。
- 发布次序：先上传并公开可下载且签名正确的归档，再将现有正式更新源和新 Beta 更新源指向它们。
- 不覆盖本机正式安装，不部署服务器，不上传用户数据；本机旧 Beta 需要一次正常退出后的手动替换。发布与安装回执保存在本地，未用这份文档代替实际运行回读。
- 本次不做隔离环境的完整“旧版下载、替换、重启”故障测试，因此不宣称全链路升级场景已全部实测。
- Core18 缺生产参考，保持 raw-only；媒体、AI 等扩展尚未完成。其他 M 型号、独立风扇浮层、全部端到端性能预算和原 49 项视觉验收继续独立，不因发行而完成。

## 归档

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `StorageCleanerMac-1.10.1.zip` | 33849437 | `82f4c16311ddaf81de7b2bf910cb8d8857b6bfb6944167635d8fd3d466e7e8c1` |
| `StorageCleanerMac-1.10.1.dmg` | 36846673 | `866cc33cdca95e749420e54ccb99d09ca0b86fb33605385477b837a7bf17d3c9` |
| `StorageCleanerMac-Beta-1.10.1.zip` | 34018521 | `5f668dd3e27aba5860dc91d59569b515b5e4b4bb7e60330dfa4ec2d2f13e11cf` |
| `StorageCleanerMac-Beta-1.10.1.dmg` | 37031377 | `1f524931fd4cf43984bd82b77fb702a5b7909e09a514dd802d391e9f544ac268` |

[安装包与说明](https://github.com/yangyihang96/StorageCleanerMacUpdates/releases/tag/v1.10.1) · [源码](https://github.com/yangyihang96/StorageCleanerMac-OpenSource/releases/tag/v1.10.1)
