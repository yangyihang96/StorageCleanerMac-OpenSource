# 主视觉与状态插画（D58，风格 A“玻璃光泽 3D”）

- 来源：Codex `codex exec` 的图片生成工具，提示词由主会话编写；工具没有返回实际模型名。用户在 2026-10-07 晚的三种风格样图中选定 A。
- 母版（1024×1024 RGBA PNG）放在仓库外 `~/Developer/.sc-build/art/set-A/`，不提交。本目录只放导出件：
  - `*-512.heic`：初始页插画中心（最大约 256 pt @2x）；
  - `*-192.heic`：页头主图标（约 64–96 pt @2x）。
  - 都由 `sips` 转成 HEIC，质量 80，保留透明通道；共 40 个文件，约 888 KB。
- 打包：`script/build_and_run.sh` 与 `script/make_release_dmg.sh` 把本目录的 `*.heic` 复制到应用包 `Contents/Resources/Art/`；代码经 `GeneratedArt`（`Sources/StorageCleanerMac/Support/GeneratedArt.swift`）按需解码一次并缓存，缺图时退回代码绘制的图块，不会崩溃或空着。
- 对应关系：
  - `module-smartscan`：智能扫描
  - `module-cleanup`：安全清理
  - `module-devcaches`：开发工具与产物
  - `module-health`：系统健康
  - `module-privacy`：浏览器隐私
  - `module-benchmark`：性能测试
  - `module-startup`：登录项与后台任务
  - `module-memory`：内存管理
  - `module-energy`：能耗
  - `module-uninstall`：卸载
  - `module-updater`：应用更新
  - `module-fileanalysis`：文件分析
  - `module-migration`：文件搬家
  - `module-duplicates`：重复文件
  - `module-similarphotos`：相似照片
  - `state-success`：清理完成
  - `state-allclear`：没发现问题
  - `state-empty`：空列表
  - `state-permission`：需要权限
  - `state-error`：出错
- 无第三方素材，不含文字和品牌标志。全部是装饰图，对读屏隐藏；轨道、节点、星点和光晕仍由代码绘制。

## 光场二期选项图标（D70）

- 用户确认的导出源：`~/Developer/.sc-build/art/set-A-mini/export/`；85 条选项映射对应 70 个独立图标。原映射及资源清单保存在 `lightfield-options.json`。
- `opt-*-56.png` 与 `opt-*-84.png` 是 28 pt 在 2x／3x 下的透明缩略图，共 140 个；直接复制已确认的 RGBA 导出件，未重绘、改色或覆盖原图。
- 本批沙箱 `sips -s format heic` 编码失败（Error 13，没有可读输出），采用用户明确允许的 PNG 回退。原模块／状态插画仍用 HEIC。
- `LightfieldOptionIcon` 复用 `GeneratedArtLibrary` 解码缓存与缺图记录，按显示倍率选档；缺失或损坏时该图不显示，行名与 AX 语义照常保留。
- 两个打包脚本只新增选项 PNG 与清单的复制规则；正式包核对亦检查这些新增资源。
