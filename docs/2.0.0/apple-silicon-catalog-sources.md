# Apple Silicon 规格表来源审计（B1 review r2）

核对日期：2026-10-10（Australia/Sydney）。按主会话本轮评审改为具体CPU/GPU SKU的带宽与内存记录；数据schema `apple-silicon-catalog-v2`，版本 `2026-10-10-b1-review-r2`。原B1四份文件、prepared及证据完整备份于scratch `revisions/b1-r1/`，没有删除上一轮产出。此前核对的身份、年份、核心选项、能力、制程空值与逐字段来源继续保留。

## 1. 结构与核对规则

`skus[]`是唯一组合表；每个条目包括id、cpuOption（cpu数组零基索引）、gpuCores、memoryBandwidthGBps、maxUnifiedMemoryGB，并在需要时附memoryLimitsByMac。所有非null叶字段的来源以芯片对象内JSON Pointer逐项记录，不只给整行一个URL。来源URL存在和静态指针合法不等于网站每个值已被生产审核批准；目录reviewStatus仍表示待主会话最终逐字段复核。

本轮逐芯片使用网页搜索查找Apple技术规格页，重点覆盖**所有Pro/Max/Ultra及M5系列**，打开具体MacBook Pro、Mac Studio、Mac Pro、Mac mini与MacBook Air规格核对CPU/GPU组合、带宽和内存限制。新闻稿中的“up to”家族上限不作为缺值SKU的数字。相同技术规格中同时列两种完整CPU/GPU配置并给共享带宽的，以该共享字段支持两种SKU；只出现基础配置＋“可配置为”另一GPU而没有明确另一配置带宽的，后者保持null。

如果分配置带宽没有直接证据，保留可选的芯片级memoryBandwidthGBps单值及unverified说明；**此单值不能自动继承到SKU**。所有SKU带宽已确认的型号删除顶层单值。memoryBandwidthOptions/configurationPairs不再与skus平行维护。v1资料只在归档保留，当前schema已升级，B2/B3不得按旧字段解码后忽略skus。

带宽单位统一十进制GB/s，保留官方精度；官方1.2TB/s只做SI单位换算为1200GB/s，不补估算小数。内存上限要同时核对GPU bin与机型：SKU值为已明确确认的示例Mac中的最大值，实际已知机型用memoryLimitsByMac收窄；芯片顶层maxUnifiedMemoryGB保留旧来源的历史上限，不能覆盖SKU。memory实际bytes不参与评分，规格不能当实测吞吐。

process仍全部null，不把5nm/第几代3nm猜成TSMC精确节点；processDescription及NE/TOPS/媒体/光追等非本轮修订字段保留其原来源与未核实原因。sources/unverified元数据不递归给自身添加来源；编辑性id/index也指向支撑该配置的官方页。

## 2. 每个SKU的带宽与内存核对结果

下面每行是具体组合，不再把Max家族最大值套给低配。带宽为空的条目必须显示“当前配置未核实”，而不是芯片单值。内存标注对应本轮技术规格可确认上限，旧历史公布上限另记。

| 芯片 | SKU ID | CPU / GPU | GB/s | SKU内存上限GB | 技术规格来源 |
|---|---|---|---|---|---|
| Apple M1 | `m1-8c-7g` | 8C / 7G | 未核实 | 16 | [Apple](https://support.apple.com/en-us/111883) |
| Apple M1 | `m1-8c-8g` | 8C / 8G | 未核实 | 16 | [Apple](https://support.apple.com/en-us/111883) |
| Apple M1 Pro | `m1-pro-8c-14g` | 8C / 14G | 200 | 32 | [Apple](https://support.apple.com/en-us/111902) |
| Apple M1 Pro | `m1-pro-10c-14g` | 10C / 14G | 未核实 | 32 | [Apple](https://support.apple.com/en-us/111902) |
| Apple M1 Pro | `m1-pro-10c-16g` | 10C / 16G | 200 | 32 | [Apple](https://support.apple.com/en-us/111901) |
| Apple M1 Max | `m1-max-10c-24g` | 10C / 24G | 400 | 64 | [Apple](https://support.apple.com/en-us/111900) |
| Apple M1 Max | `m1-max-10c-32g` | 10C / 32G | 400 | 64 | [Apple](https://support.apple.com/en-us/111901) |
| Apple M1 Ultra | `m1-ultra-20c-48g` | 20C / 48G | 800 | 128 | [Apple](https://support.apple.com/en-us/111900) |
| Apple M1 Ultra | `m1-ultra-20c-64g` | 20C / 64G | 未核实 | 128 | [Apple](https://support.apple.com/en-us/111900) |
| Apple M2 | `m2-8c-8g` | 8C / 8G | 100 | 24 | [Apple](https://support.apple.com/en-us/111867) |
| Apple M2 | `m2-8c-10g` | 8C / 10G | 100 | 24 | [Apple](https://support.apple.com/en-us/111869)、[Apple](https://support.apple.com/en-us/111867) |
| Apple M2 Pro | `m2-pro-10c-16g` | 10C / 16G | 200 | 32 | [Apple](https://support.apple.com/en-us/111340) |
| Apple M2 Pro | `m2-pro-12c-19g` | 12C / 19G | 200 | 32 | [Apple](https://support.apple.com/en-us/111838) |
| Apple M2 Max | `m2-max-12c-30g` | 12C / 30G | 400 | 64 | [Apple](https://support.apple.com/en-us/111340) |
| Apple M2 Max | `m2-max-12c-38g` | 12C / 38G | 400 | 96 | [Apple](https://support.apple.com/en-us/111838) |
| Apple M2 Ultra | `m2-ultra-24c-60g` | 24C / 60G | 800 | 192 | [Apple](https://support.apple.com/en-us/111835) |
| Apple M2 Ultra | `m2-ultra-24c-76g` | 24C / 76G | 未核实 | 192 | [Apple](https://support.apple.com/en-us/111343) |
| Apple M3 | `m3-8c-8g` | 8C / 8G | 100 | 24 | [Apple](https://support.apple.com/en-us/118551) |
| Apple M3 | `m3-8c-10g` | 8C / 10G | 100 | 24 | [Apple](https://support.apple.com/en-us/118551) |
| Apple M3 Pro | `m3-pro-11c-14g` | 11C / 14G | 150 | 36 | [Apple](https://support.apple.com/en-us/117736) |
| Apple M3 Pro | `m3-pro-12c-18g` | 12C / 18G | 150 | 36 | [Apple](https://support.apple.com/en-us/117736) |
| Apple M3 Max | `m3-max-14c-30g` | 14C / 30G | 300 | 96 | [Apple](https://support.apple.com/en-us/117736) |
| Apple M3 Max | `m3-max-16c-40g` | 16C / 40G | 400 | 128 | [Apple](https://support.apple.com/en-us/117736) |
| Apple M3 Ultra | `m3-ultra-28c-60g` | 28C / 60G | 819 | 256 | [Apple](https://support.apple.com/en-us/122211) |
| Apple M3 Ultra | `m3-ultra-32c-80g` | 32C / 80G | 819 | 256 | [Apple](https://support.apple.com/en-us/122211) |
| Apple M4 | `m4-8c-8g` | 8C / 8G | 未核实 | 未核实 | [Apple](https://support.apple.com/en-us/121523) |
| Apple M4 | `m4-10c-10g` | 10C / 10G | 120 | 32 | [Apple](https://support.apple.com/en-us/121552) |
| Apple M4 Pro | `m4-pro-12c-16g` | 12C / 16G | 273 | 64 | [Apple](https://support.apple.com/en-us/121553)、[Apple](https://support.apple.com/en-us/121555) |
| Apple M4 Pro | `m4-pro-14c-20g` | 14C / 20G | 273 | 64 | [Apple](https://support.apple.com/en-us/121553)、[Apple](https://support.apple.com/en-us/121555) |
| Apple M4 Max | `m4-max-14c-32g` | 14C / 32G | 410 | 36 | [Apple](https://support.apple.com/en-us/121553) |
| Apple M4 Max | `m4-max-16c-40g` | 16C / 40G | 546 | 128 | [Apple](https://support.apple.com/en-us/121553) |
| Apple M5 | `m5-10c-8g` | 10C / 8G | 153 | 32 | [Apple](https://www.apple.com/macbook-air/specs/) |
| Apple M5 | `m5-10c-10g` | 10C / 10G | 153 | 32 | [Apple](https://www.apple.com/macbook-air/specs/) |
| Apple M5 Pro | `m5-pro-15c-16g` | 15C / 16G | 307 | 64 | [Apple](https://support.apple.com/en-us/126318)、[Apple](https://support.apple.com/en-us/128108) |
| Apple M5 Pro | `m5-pro-18c-20g` | 18C / 20G | 307 | 64 | [Apple](https://support.apple.com/en-us/126318)、[Apple](https://support.apple.com/en-us/128108) |
| Apple M5 Max | `m5-max-18c-32g` | 18C / 32G | 460 | 36 | [Apple](https://support.apple.com/en-us/126318) |
| Apple M5 Max | `m5-max-18c-40g` | 18C / 40G | 614 | 128 | [Apple](https://support.apple.com/en-us/126318) |
| Apple M5 Ultra | `m5-ultra-30c-64g` | 30C / 64G | 1200 | 256 | [Apple](https://www.apple.com/mac-studio/specs/) |
| Apple M5 Ultra | `m5-ultra-36c-80g` | 36C / 80G | 1200 | 512 | [Apple](https://www.apple.com/mac-studio/specs/) |

### 未分配置单值保留

| 芯片 | 保留的芯片单值GB/s | 未明确带宽的SKU | 使用限制 |
|---|---|---|---|
| Apple M1 | 未知 | m1-8c-7g, m1-8c-8g | 不继承为SKU值 |
| Apple M1 Pro | 200 | m1-pro-10c-14g | 不继承为SKU值 |
| Apple M1 Ultra | 800 | m1-ultra-20c-64g | 不继承为SKU值 |
| Apple M2 Ultra | 800 | m2-ultra-24c-76g | 不继承为SKU值 |
| Apple M4 | 120 | m4-8c-8g | 不继承为SKU值 |
| Apple M6 | 未知 | 配置全集未确认 | 不继承为SKU值 |

## 3. 逐芯片网页检索记录

每行列出本轮检索目的和实际用于SKU字段的官方技术规格入口；详细pointer仍以JSON为准。所有必查的Pro/Max/Ultra/M5条目都已检索，未取得的字段明确留下原因，没有把无搜索结果当成硬件不支持。

| 芯片 | 检索目的 | 官方规格入口 | 结果限制 |
|---|---|---|---|
| m1 | `site:support.apple.com MacBook Air M1 2020 technical specifications` | [Apple](https://support.apple.com/en-us/111883) | 带宽缺明确分配置证据：m1-8c-7g, m1-8c-8g |
| m1-pro | `site:support.apple.com MacBook Pro 14-inch 2021 memory bandwidth 200GB/s` | [Apple](https://support.apple.com/en-us/111902)、[Apple](https://support.apple.com/en-us/111901) | 带宽缺明确分配置证据：m1-pro-10c-14g |
| m1-max | `site:support.apple.com MacBook Pro 16-inch 2021 M1 Max memory bandwidth` | [Apple](https://support.apple.com/en-us/111900)、[Apple](https://support.apple.com/en-us/111901) | SKU带宽已录入 |
| m1-ultra | `site:support.apple.com Mac Studio 2022 48-core GPU memory bandwidth` | [Apple](https://support.apple.com/en-us/111900) | 带宽缺明确分配置证据：m1-ultra-20c-64g |
| m2 | `site:support.apple.com MacBook Air M2 2022 100GB/s` | [Apple](https://support.apple.com/en-us/111867)、[Apple](https://support.apple.com/en-us/111869) | SKU带宽已录入 |
| m2-pro | `site:support.apple.com/en-us/111340 200GB/s; site:support.apple.com/en-us/111838 12-core 200GB/s` | [Apple](https://support.apple.com/en-us/111340)、[Apple](https://support.apple.com/en-us/111838) | SKU带宽已录入 |
| m2-max | `site:support.apple.com MacBook Pro 16-inch 2023 96GB 38-core` | [Apple](https://support.apple.com/en-us/111340)、[Apple](https://support.apple.com/en-us/111838) | SKU带宽已录入 |
| m2-ultra | `site:support.apple.com Mac Studio 2023 800GB/s; Mac Pro 2023 800GB/s` | [Apple](https://support.apple.com/en-us/111835)、[Apple](https://support.apple.com/en-us/111343) | 带宽缺明确分配置证据：m2-ultra-24c-76g |
| m3 | `site:support.apple.com MacBook Air 13-inch M3 2024 specifications` | [Apple](https://support.apple.com/en-us/118551) | SKU带宽已录入 |
| m3-pro | `site:support.apple.com MacBook Pro 14-inch M3 Pro M3 Max 150GB/s` | [Apple](https://support.apple.com/en-us/117736) | SKU带宽已录入 |
| m3-max | `site:support.apple.com MacBook Pro 14-inch M3 Pro M3 Max 300GB/s` | [Apple](https://support.apple.com/en-us/117736) | SKU带宽已录入 |
| m3-ultra | `site:support.apple.com/en-us/122211 819GB/s` | [Apple](https://support.apple.com/en-us/122211) | SKU带宽已录入 |
| m4 | `site:support.apple.com MacBook Pro 14-inch M4 2024 120GB/s` | [Apple](https://support.apple.com/en-us/121523)、[Apple](https://support.apple.com/en-us/121552) | 带宽缺明确分配置证据：m4-8c-8g |
| m4-pro | `site:support.apple.com MacBook Pro 14-inch M4 Pro M4 Max 2024; Mac mini 2024 64GB` | [Apple](https://support.apple.com/en-us/121553)、[Apple](https://support.apple.com/en-us/121555) | SKU带宽已录入 |
| m4-max | `site:support.apple.com MacBook Pro 14-inch M4 Pro M4 Max 2024 410GB/s` | [Apple](https://support.apple.com/en-us/121553) | SKU带宽已录入 |
| m5 | `site:apple.com/macbook-air/specs M5 153GB/s` | [Apple](https://www.apple.com/macbook-air/specs/) | SKU带宽已录入 |
| m5-pro | `site:apple.com/macbook-pro/specs M5 Pro 307GB/s; Mac mini M6 or M5 Pro specs` | [Apple](https://support.apple.com/en-us/126318)、[Apple](https://support.apple.com/en-us/128108) | SKU带宽已录入 |
| m5-max | `site:apple.com/macbook-pro/specs M5 Max 460GB/s` | [Apple](https://support.apple.com/en-us/126318) | SKU带宽已录入 |
| m6 | `site:apple.com/mac-mini/specs M6 M5 Pro (retain prior partial row; RAM-dependent configurations require separate review)` | [Apple](https://support.apple.com/en-us/128108) | 原部分行保留；内存容量相关带宽与旧冲突资料需另行复核 |
| m5-ultra | `site:apple.com/mac-studio/specs M5 Ultra memory bandwidth 256GB` | [Apple](https://www.apple.com/mac-studio/specs/) | SKU带宽已录入；36C核心类型分拆仍未知 |

## 4. 配置差异、纠错和遗留

- **M3 Max**：14C/30G为300GB/s、最高96GB；16C/40G为400GB/s、最高128GB。M4 Max14C/32G为410GB/s、最高36GB；16C/40G为546GB/s、最高128GB。原来的家族400/546不再作为顶层带宽供识别使用。
- **M2 Max**：30G可确认64GB上限，96GB限定38G；M5 Max32G/40G带宽460/614GB/s，内存36/128GB。CPU总数相同也不能忽略GPU bin。
- **M4 Pro / M5 Pro机型差异**：M4 Pro的MacBook Pro规格给48GB、Mac mini给64GB；M5 Pro15C/16G的MacBook Pro给48GB、当前Mac mini给64GB。本轮逐SKU保存两种机型上限，不能把跨机型最大值直接称为本机型可选配置。
- **M3 Ultra历史与现售**：保留新闻稿曾公布的芯片家族512GB历史值；现行Mac Studio2025技术规格列96/256GB，本轮可直接确认的两个SKU上限为256GB。不从历史家族512GB推算每个SKU能否选512；旧source和unverified说明继续留在JSON，必要时在B5前后的资料复核中更新。
- **M1 Pro10C/14G、M1 Ultra20C/64G、M2 Ultra24C/76G**：官方材料确认其配置存在，但本轮所取规格没有明确给该分配置独立带宽。具体SKU值null，200/800/800仅作为芯片级来源单值保留并说明；不把它们冒充已核实的SKU值。
- **M1 / M4低配**：M1官方已核对材料没有明确GB/s，不采用第三方68.25/68.3；M4的8C/8G这轮未取得直接可回读的分配置带宽/内存上限，保留空值及芯片级120，不猜其上限。
- **M5 base**：当前MacBook Air规格包含10C/8G、10C/10G，153GB/s与最高32GB记录在两个条目，来源为该官方规格共享字段。NE核型仍按超级/效率术语，不改成旧P/E简称。

### M5 Ultra本轮可回读数据与上轮冲突记录

上一轮美/澳新闻稿及支持页有不一致记录，原文件与证据已归档。本轮重新搜索并打开当前Mac Studio技术规格，采用它**明确列出的配置字段**：30C/64G与36C/80G、1.2TB/s，内存256/512GB按配置限制记录。30C拆分为10超级＋20性能；36C处未明确列分拆，因此cpuOption中的类型数量保持null，不能按比例计算12超级/24性能。

此次只更新取得直接官方SKU证据的字段；M5 Ultra的其他未知能力/引擎字段并没有因SKU带宽确认就全部变成已核实。M6继续保留原部分行，没有把该机型与内存容量相关的153/170GB/s变体强制合并成一个CPU/GPU“唯一SKU”；未来若启用它，需在schema中明确内存配置条件并复核旧冲突材料。

### 来源定位与旧字段保护

延续上一轮纠错：M1 Pro/Max真实Newsroom URL为apple-unveils-game-changing-m1-pro-and-m1-max；M5 Pro/Max支持页126318与当前MacBook Pro规格可回读。M1 Max24G字段用Mac Studio2022规格、32G用16英寸2021规格，不能让仅列M1 Pro的14英寸页背书M1 Max带宽。通用电源模式页101613不作为风扇证据；已有散热来源不变，未查到对应机型证据继续null。其他NE TOPS、精确节点与未声明能力的空值不是0/false。

## 5. 本机识别证据与参考基准

主会话在沙箱外实际回读（由用户本轮转交）：brand Apple M5 Pro；nperflevels=2；Super物理6、Performance物理12；physicalcpu=18；GPU20；memsize51539607552。规范与静态匹配据此唯一返回 `m5-pro-18c-20g`，cpuOption=1，官方规格307GB/s、最高64GB；这里的带宽是规格值，不是本机实测吞吐。

当前本机SKU识别为PASS（主会话回读），本Codex没有绕过沙箱重读；Metal API名称及logicalcpu未提供，保持未知，不阻塞该SKU识别。上一轮沙箱sysctl失败/本轮主会话成功证据分开保存。识别成功不代表v11参考集已采到。B5之前的基准策略是本机M5 Pro暂定集；没有有效冻结v11数值时仍待校准。M1具体机型/内存/SSD/散热是B5待办，不阻塞B2–B4。

## 6. 来源URL集合、哈希与验证

本轮JSON原始字节SHA-256：`8a63e9abe52a78b70449002406767af003193efdafa1f3bdbc0553f024f0745e`。哈希证明字节一致，不证明官方来源审核或app资源已启用。SKU来源仅使用Apple产品技术规格与support历史技术规格；非本轮字段保留其原Newsroom/技术规格/维修来源。

- https://support.apple.com/en-us/103912
- https://support.apple.com/en-us/103944
- https://support.apple.com/en-us/104061
- https://support.apple.com/en-us/111340
- https://support.apple.com/en-us/111343
- https://support.apple.com/en-us/111835
- https://support.apple.com/en-us/111838
- https://support.apple.com/en-us/111867
- https://support.apple.com/en-us/111869
- https://support.apple.com/en-us/111883
- https://support.apple.com/en-us/111900
- https://support.apple.com/en-us/111901
- https://support.apple.com/en-us/111902
- https://support.apple.com/en-us/117736
- https://support.apple.com/en-us/118551
- https://support.apple.com/en-us/121523
- https://support.apple.com/en-us/121552
- https://support.apple.com/en-us/121553
- https://support.apple.com/en-us/121555
- https://support.apple.com/en-us/121562
- https://support.apple.com/en-us/121582
- https://support.apple.com/en-us/122211
- https://support.apple.com/en-us/125819
- https://support.apple.com/en-us/126318
- https://support.apple.com/en-us/128107
- https://support.apple.com/en-us/128108
- https://www.apple.com/au/newsroom/2021/10/apple-unveils-game-changing-macbook-pro/
- https://www.apple.com/au/newsroom/2022/06/apple-unveils-all-new-macbook-air-supercharged-by-the-new-m2-chip/
- https://www.apple.com/au/newsroom/2026/08/apple-introduces-m6-and-m5-ultra-for-a-big-leap-in-performance-and-ai-compute/
- https://www.apple.com/mac-studio/specs/
- https://www.apple.com/macbook-air/specs/
- https://www.apple.com/macbook-pro/specs/
- https://www.apple.com/newsroom/2020/11/apple-unleashes-m1/
- https://www.apple.com/newsroom/2020/11/introducing-the-next-generation-of-mac/
- https://www.apple.com/newsroom/2021/10/apple-unveils-game-changing-m1-pro-and-m1-max/
- https://www.apple.com/newsroom/2022/03/apple-unveils-all-new-mac-studio-and-studio-display/
- https://www.apple.com/newsroom/2022/03/apple-unveils-m1-ultra-the-worlds-most-powerful-chip-for-a-personal-computer/
- https://www.apple.com/newsroom/2022/06/apple-unveils-m2-with-breakthrough-performance-and-capabilities/
- https://www.apple.com/newsroom/2023/01/apple-unveils-m2-pro-and-m2-max-next-generation-chips-for-next-level-workflows/
- https://www.apple.com/newsroom/2023/06/apple-introduces-m2-ultra/
- https://www.apple.com/newsroom/2023/10/apple-unveils-m3-m3-pro-and-m3-max-the-most-advanced-chips-for-a-personal-computer/
- https://www.apple.com/newsroom/2024/03/apple-unveils-the-new-13-and-15-inch-macbook-air-with-the-powerful-m3-chip/
- https://www.apple.com/newsroom/2024/05/apple-introduces-m4-chip/
- https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/
- https://www.apple.com/newsroom/2025/03/apple-reveals-m3-ultra-taking-apple-silicon-to-a-new-extreme/
- https://www.apple.com/newsroom/2025/10/apple-unleashes-m5-the-next-big-leap-in-ai-performance-for-apple-silicon/
- https://www.apple.com/newsroom/2026/03/apple-debuts-m5-pro-and-m5-max-to-supercharge-the-most-demanding-pro-workflows/
- https://www.apple.com/newsroom/2026/03/apple-introduces-macbook-air-with-m5/
- https://www.apple.com/newsroom/2026/08/apple-introduces-m6-and-m5-ultra-for-a-big-leap-in-performance-and-ai-compute/

静态检查：schema/版本；20个型号与18必需型号；SKU id唯一且CPU/GPU选项合法；完整CPU核型和总数一致，未知分拆有原因；每个非null叶字段有官方URL，每个null有原因；缺值SKU不继承芯片单值；M3/M4/M5 Max差异与内存GPU限制；主会话命名层级唯一匹配本机SKU；已确认GPU权重与scoring契约哈希；补丁、白空白和提交守卫。报告在prepared/static-checks.json，本轮不会把这些结构检查称为Swift测试或完整规格生产获批。

打包方式仍按规范第12节，根Resources/Benchmark不会自动进入现有app；本轮不改Swift/Package/构建脚本。主会话后续启用前继续核对新SKU来源、未知字段和机型内存限制，并在实际bundle读回字节hash/解码。主会话已确认的GPU四项等权规则不再作为未决事项。
