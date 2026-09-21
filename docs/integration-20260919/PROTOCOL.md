# MSeries Core18 草案协议与材料登记

本文件描述已接入 App 的实现，不是正式校准证书。原 v7/v9 保留原版本，新结果不借用旧参考。没有有效参考时只显示原始数据；服务端新入口默认拒绝提交。

## 版本

| 字段 | 值 |
|---|---|
| schema | mseries-result-v10-draft2 |
| plan | mseries-core18-v10-draft2 |
| workload | mseries-fixed-kernels-v1 |
| fixture | procedural-mit-seed-619a27de-v1 |
| 实现族 | native-c-metal-posix-v1 |
| stats | median-mad-all-samples-v1 |
| scoring | weighted-geomean-20-20-25-20-15-draft1 |
| reference | unavailable-raw-only |
| CPU 扩展 | mseries-cpu-extensions-v1 |
| Core 合同 SHA256 | c8b75dff7897d6ff8055d51fdf37afce20d1b656037e042a98c68e03e9083318 |

逐文件实现 SHA256 见本次证据目录的 implementation-manifest.json。固定输入的 13 项内容/定义 hash 见 validation/fixture-content-manifest.json：CPU/内存由生产 C workspace 直接取输入，GPU/存储按已记录的固定公式生成；这些不是参考跑分数据。协议仍为草案；修改计时合同、素材规模、精度或实现族后必须修改对应版本并重新校准，不能改名沿用旧成绩。

## 真实 Core 内核

| 任务 | 固定工作单元 | 正确性验证 |
|---|---|---|
| CPU integer（单/多） | 262144 个 UInt64，固定混合函数/种子 | 全部输出重算 |
| CPU floating（单/多） | 128×128 FP32 矩阵乘 | 独立 Double 参考，逐元素比较 |
| CPU compression（单/多） | 1 MiB 固定数据，LZFSE | 解压后逐字节比较 |
| CPU image（单/多） | 512×512 灰度 3×3 高斯 | 逐像素参考，含边界 |
| GPU 离屏 | 1024×1024 RGBA8 固定三角形/片元 | 全像素固定颜色验证 |
| GPU FP32 / FP16 | 262144 元素，每元素 256 次 FMA | 全输出对照同精度参考，最多 2 ULP |
| Memory copy / triad | 每数组 32 MiB，固定 Double 输入 | 全数组比较 |
| Memory pointer chase | 4M 个 UInt32 随机排列单环，16 MiB | 依赖 volatile 读取；要求实际执行，验证完整排列的唯一性、全部链接和环起点，保存链内容校验值 |
| Storage 顺序读/写 | 64 MiB 私有文件，1 MiB 操作 | 全字节对照固定生成数据 |
| Storage 4K 随机读/写 QD1 | 1024 次，固定偏移序列 | 全字节验证，另存逐次 I/O 延迟 |

所有 CPU 多线程 Core 使用全部逻辑核心；每 worker 独立固定工作单元。预热不计分，自适应只调整完整固定单元的重复次数。保留三次有效重复，不丢慢样本。A/B/C 仅为样本稳定程度。

GPU 不使用屏幕 drawable、present 或显示同步。编译、编码准备和 CPU 校验不计入 command-buffer GPU 时间。短 GPU 工作有界，但驱动级不结束情况下仍持有租约等待，尚缺完整超时隔离演练。

磁盘 F_NOCACHE 请求绕过文件缓存；每轮写入末尾 fsync 计时在内，不声称 SSD 物理持久化。读取校验不进读取计时，但进入安全超时。正常 Core 初始化 64 MiB + 4×64 MiB 顺序写 + 4×4 MiB 随机写 = 336 MiB。总写预算 512 MiB。预算由会话持有，初始化失败重试不能重置额度；预留额度与实际成功写入字节分开记录。测试资源残留持久化仍需加固，不能把当前预算视为已穷尽故障验证。

共享内存预算上界为物理内存的 1/5、保守可用内存的 1/2、2 GiB 三者最小值。按实时资源复核，不暗中减少多核线程数。GPU 工作额外按推荐工作集复核。预算是工程上界，尚未跨 SKU 冻结。

## 扩展

已接入 CPU 线程曲线（1、2、4…全部逻辑核心）和约 6 秒、最多 12 批次的短 CPU 持续观察。每批三次样本全部保留。扩展环境另存，不追溯修改 Core 的环境记录。

GPU 高级/硬件光追、内存/存储工作集和队列深度、H.264/HEVC/ProRes/AV1、AI 图像/文本、显示节奏、功耗效率仍标记 notImplemented。原项目存在部分相关内核，但尚未完成新协议预算/取消/回执合同适配，不能将其算为新协议完成。

## 参考与计分

无生产参考。校准验证器要求至少三次独立、非重叠 Release 完整 Core，会话 Core 环境为 AC/nominal/非低电量，才允许生成候选共同参考。该结构校验不替代人工控制环境、跨机器复现和发行审核。

草案指数 = 1000 × exp(Σ 每项权重 × log(相对共同参考表现))。
组权重：CPU single 20%、CPU multi 20%、GPU 25%、Memory 20%、Storage 15%；组内等权。pointer chase 低延迟更好，其余高吞吐更好。不以型号、核心/内存/SSD 大小加分，不对 5 倍以上结果截断。缺任何 Core 不生成总分，不重新分权重。

服务端新增 mseries-contract.ts，拒绝未知/身份附加字段，使用原始重复值重新计算中位数和几何平均；不接受 proposedScore。新增 /v3/mseries/capabilities 明确 acceptingSubmissions=false，提交返回 503，不读取提交正文、不写数据库。尚无新协议生产存储、激活参考或部署，不能宣称服务端产品闭环完成。旧删除接口保留。

## 素材与许可

本次 Core 数据由项目源码按固定公式生成，随本项目 MIT 许可分发，没有复制第三方图片/视频/私人文档。系统 Compression、Metal、Foundation/POSIX 通过系统 SDK 调用，不打包额外模型。旧包中的合成参考未进入生产。AI/媒体扩展所需的固定模型/素材许可与 hash 尚未齐备，故没有伪造该类结果或默认下载大型模型。
