# 2026-09-19 本地发行边界核对

未发布、未部署、未 push/tag/Release。用户随后明确要求基于现有测试版开发未来 1.10.1；已只更新 `/Applications/测试版.app`，正式版未改。

## 官方来源（执行当日核对）

- Developer ID / Gatekeeper: https://developer.apple.com/developer-id/
- 独立发行的 hardened runtime / Developer ID / 公证: https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html
- 公证流程及商店渠道区别: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- App Store Connect 隐私申报与第三方数据收集: https://developer.apple.com/app-store/app-privacy-details/
- Metal 能力以 API/能力表判断: https://developer.apple.com/metal/capabilities/
- GPU 时间戳: https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime
- 推荐 GPU 工作集: https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize
- VideoToolbox 解码能力查询（扩展尚未接入）: https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:)

独立发行需要 Developer ID 与相应公证/Gatekeeper 验证；App Store 的提交流程含对应安全审查，不以本地 codesign 成功代替。商店隐私信息要按实际数据流和第三方收集填写。联网开关关闭与服务端未部署并不构成已完成商店申报的证据。

## 本机证据边界

只有 Apple Development 开发证书，没有 Developer ID Application 发行证书。本次用开发证书签名隔离验收 App，签名、公证、Gatekeeper、Sparkle 归档签名、真实升级重启是独立检查项。没有上传公证请求、没有签署发布归档、没有真实更新正式安装。

现有测试版更新为 1.10.1 / `20260919151211`，bundle ID 仍为 `com.local.StorageCleanerMac.beta`，原偏好与数据目录保留，更新 feed 为空。实际运行路径和二进制 hash 已读回，`codesign --verify --deep --strict` exit 0；Gatekeeper 评估仍 exit 3。该本地开发测试更新不等于 Sparkle 发行升级验收。

SDK 27 编译时 Swift 6.4 新构建驱动曾将最终 LC_BUILD_VERSION 的 sdk 写成部署目标 14；脚本现在向链接器明确传入实际所选 SDK 版本，并保持原最小系统及产物验收门槛，不事后修改二进制头。

第一次隔离启动的 dyld 失败来自手工改 bundle ID 后以 ad-hoc + hardened runtime 重签名、未统一 Sparkle 的签名身份。日志已保存。改用同一 Apple Development 身份重签名嵌套组件后真实 App 成功启动并完成一键测试，没有修改系统安全设置。

尚未完成：Developer ID 发行、公证/staple、发行版 Gatekeeper 放行、Sparkle 归档签名与隔离升级/重启故障演练、商店 sandbox/权限适配和最终隐私申报核对。以上不得标记通过。
