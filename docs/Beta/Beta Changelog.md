# 存储清理助手 Beta Changelog

## 1.9.10 Beta — Build 20260810040455

- 构建时间：2026-08-10 14:04:55 AEST（2026-08-10T04:04:55Z）
- Commit：`78c6d3520e59-dirty`
- 安装路径：`/Applications/测试版.app`
- 签名：Apple Development，Team ID `T9GZL52H8R`，Hardened Runtime

### 本构建

- 建立稳定独立身份：App `com.local.StorageCleanerMac.beta`，Helper 与 Mach Service `com.local.StorageCleanerMac.beta.FanControlHelper`。
- Finder、菜单栏、Dock 和本地化名称使用“测试版”；设置页显示“存储清理助手 1.9.10 测试版”、Build、Commit、构建时间和配置。
- 生成不含用户目录、序列号或凭据的 `BuildInfo.plist`，并支持“复制测试版信息”。
- 测试版使用独立 Application Support 根目录 `StorageCleanerMac-Beta`，不复制或覆盖正式版配置与历史。
- 测试版关闭正式 Sparkle Feed 自动更新；后续更新统一由 `script/build_and_run.sh --beta --install --verify` 完成。
- 复用同一个受限 Helper、SMAppService daemon 和 XPC 协议；电源、手动风扇和温控曲线不增加第二次授权。
- 保留风扇租约、watchdog、睡眠与热保护回退、写入后回读；安装与截图流程没有执行任何硬件写入。
- 修正外置卷容量探测：可回收容量仅对启动卷请求，避免在有效 ExFAT 卷上持续产生 CacheDelete 错误。
- 删除小窗内存压力卡下方的冗余说明文字。
- 增加稳定的一键 Beta 构建、测试、inside-out 签名、staging 安装、启动验证和真实窗口截图流程。

### 验证

- `./script/build_and_run.sh --beta --install --verify --screenshots` 全流程退出码为 0：2408 tests、10 skipped、0 failures；Debug、Release 与严格并发检查通过。
- App、Helper、Sparkle 嵌套组件通过 `codesign --verify --deep --strict`；Helper LaunchDaemon plist 通过 `plutil -lint`。
- 安装后的真实进程来自 `/Applications/测试版.app/Contents/MacOS/StorageCleanerMacBeta`，主小窗、硬件详情、曲线编辑器、电源状态和内存历史均可打开。
- 实际截图位于 `artifacts/beta-preview/20260810040455/`。

### 当前限制

- Beta Helper 当前为 `SMAppService.status = notFound`，未注册、未批准，XPC 未连接；界面保持只读并显示真实不可用状态。
- 未执行真实手动风扇、最大风扇、温控曲线或电源模式写入；截图中的相应页面不是硬件写入成功证明。
- 当前只有 Apple Development 身份；未进行 Developer ID 签名、公证、Sparkle 上传或公开发布，`spctl` 不会将其视为可分发公证版本。
- 未在其他 Intel / Apple Silicon、无风扇、双风扇或无电池机型上进行真实硬件验证。
