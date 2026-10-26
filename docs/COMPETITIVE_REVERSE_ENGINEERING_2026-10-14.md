# 清理与监控软件逆向参考（2026-10-15 修订）

适用对象：StorageCleanerMac 2.0.1；工作树 /Users/developer/Developer/sc-worktrees/v2.0.1，HEAD 6e660a59f7b6dc406201b156e6c8ab1d3a6a6f4b，包含 Claude 已有的未提交修改。本文件不取代 AGENTS.md、D98 或协作决定。

本轮目的：修正上一版五类审查问题，补齐实际函数、保存可复查证据，并把建议改成对照当前实现查缺补漏。D98 所称旧版“§3 P0”对应本修订版 §5。原报告已备份为 [report-before.md](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/report-before.md)。

## 1. 方法、证据等级与样本

历史材料使用 REA 6.4.0 + Hopper 6.6.0-demo；本轮补查使用 REA 6.4.0 + Ghidra 12.1.4（OpenJDK 21，mac_arm_64 原生组件），Mac Sai 的全程序自动分析超时后改为直接 Ghidra 限定函数分析，其输出明确标记为非 REA 记录。Hopper Demo 未被破解，也未用于本轮 GUI 分析。全部分析在后台进行；未主动运行目标清理器、执行清理、提权、风扇或充电写入，未抓包，未读取 Keychain。

证据等级：
- 函数级：反编译、汇编、调用或条件分支支持所述局部行为；不是原始源码或完整安全证明。
- 符号/字符串级：仅证明相关名称、文案、选择子或端点存在；不证明默认行为、实际调用或启用状态。
- 源码级：当前 2.0.1 工作树的实现、测试文本或项目决定；不自动代表安装包行为或测试通过。
- 运行时未知：联网、恢复效果、异签名 XPC 拒绝、硬件控制等未执行的场景。

REA Ghidra provider 不接收 universal Mach-O 时，先从原文件复制 arm64 切片分析，不修改原文件。切片与样本哈希在持久证据目录中记录。

~~~bash
GHIDRA_INSTALL_DIR="$HOME/Developer/tools/ghidra_12.1.4_PUBLIC" \
JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" \
rea function <arm64-binary> <symbol-or-address> --provider ghidra --format json
~~~

[安装快照](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/installation-snapshot.json)记录本轮读取的版本、Build 和两个特权服务检查。以下是本机样本，不代表厂商当前最新版。

| 软件 | 本机版本 | 本轮能支持的定位或能力 | 删除/特权结论边界 |
| --- | --- | --- | --- |
| CleanMyMac（Setapp） | 5.7.1 | 清理、监控；含特权 agent | 已反编译 PrivilegedFileRemover；未验证全部恢复路径 |
| CleanMyMac CLI | 1.0.0 | CLI 包装入口 | 本轮未独立完成其 scan/clean/purge 的逐函数追踪 |
| 腾讯柠檬清理 | 5.3.4 | 清理、LemonMonitor、root daemon | 已反编译 daemon 接入校验；删除命令面主要为符号证据 |
| Mac Sai | 1.21.3 | 清理、SafetyGuard、SecureEraser、合并相关符号 | 已补限定函数及必要被调函数；守卫仅支持局部条件，不代表全部入口安全 |
| PureMac | 3.0.0 | 清理、应用管理、管理员删除脚本构造 | 函数中可见清单及脚本拼接；实际执行载体仍有未闭合部分 |
| MacOptimizer | 1.1.9 | 清理、进程监控 | dry-run 初值与危险命令构造有函数证据；补查见下文 |
| 本机正式版 / Beta | 2.0.0 / 2.0.1 | 清理、回执、浏览器隐私、风扇控制 | 必须区分普通移入废纸篓、清空废纸篓、数据库行级删除与自有数据维护 |
| iStat Menus（Setapp） | 7.30 | 菜单栏监控、SMC、风扇、天气相关接口 | daemon 接入函数与哈希白名单有代码证据；其他能力部分为接口清单 |
| Stats | 3.0.20 | 模块化监控、SMC helper、Remote 子系统 | 已反编译远程控制开关；不能据此推定当前已开启 |
| AlDente Pro（Setapp） | 1.39.4 | 电池策略、SMC helper | 已追踪 8 位和 32 位写入分支及驱动调用；未执行硬件写入 |

对 Stats 与 AlDente，安装快照只确认：对应 /Library/PrivilegedHelperTools 文件不存在，launchctl 在 system 域按指定标签查询均返回 113（未找到服务）。这不是对全部标签、域或加载方式的全局否定。

## 2. 删除与恢复

### 2.1 自研 RestrictedMove：已补到真正函数

旧 ev_72c8e1c0e390927976ef2aad1fd82d004217a43e7531db4433654798ef7eed36 对应 perform 的 defer 清理片段，只关闭句柄，不能作为完整移动流程的证明。该历史记录仍保留，但不再用于支持移动安全性。

新增 [sc-restricted-move-full.json](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/raw/supplement/sc-restricted-move-full.json)：
- Evidence ID：ev_4567415c9de9729244a9c351971d7b65a86657696cfeeb47e825f49ad3eba6a1。
- 目标：已安装正式版的 StorageCleanerFileOperationHelper；不是当前工作树重新构建的 Beta。
- 函数入口 0x100004644，Ghidra 识别函数体 0x100004644–0x100005a4b，共 5128 字节。
- 函数内可见 fstatat(..., 0x20)、openat(..., 0x1100100)、移动前 stat 字段复核，以及 renameatx_np(..., 4)。
- [本机 SDK 常量快照](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/sdk-constants.json)对应 AT_SYMLINK_NOFOLLOW、O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW 和 RENAME_EXCL。这里支持“具有这些防护调用及局部复核分支”，不声称全部竞态已被排除。
- 完整反编译与汇编已保存；该大函数的 high-pcode value-flow 标为 truncated，不能把保留的值流图当成完整证明。

现有产品路径不是“全部 Trash”：普通用户文件清理偏好移入废纸篓；清空废纸篓是永久删除；浏览器隐私有数据库行级删除；App 自有缓存与备份还有维护删除。本轮不再使用“这批里最保守”或“竞品没有同等回执”的整体排名。

### 2.2 PureMac

ev_71e552717b53e433ee5856c66b86affdbab28c3a7b8068c5ab22edd8b9092582 支持 cleanWithAdminPrivileges(items:) 在 0x1000aabb8 构造 NUL 分隔路径清单、临时文件 puremac-rm-UUID、原子写入和管理员 AppleScript 命令串；ev_5f3c64fd 前缀对应的完整字节记录见证据索引。

命令串包含 /usr/bin/xargs -0 /bin/rm -rf -- 和 with administrator privileges；可以判断设计上存在绕过废纸篓的管理员删除分支。实际 NSAppleScript/osascript 执行点未在已检查函数内闭合；上层或其他流程是否另有备份仍未知。不能把“本函数未见恢复步骤”写成“全产品没有备份”。

### 2.3 Mac Sai

历史 ev_d59cca485fee70c0c1326833384b123c1c3d4065fa86d3e96378f1fcf71e13ca 是 search_procedures，ev_00d4ac5c913ef43391de22a3fbada87fa93d562dcbfb0c9a605d716053bc44eb 是 search_strings。它们证明相关名称和文案存在，不能单独证明调用必达、默认使用或所有目录均被拒绝。

本轮已补 [限定函数输出](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/raw/supplement/macsai-focused-ghidra.json)和[必要被调函数](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/raw/supplement/macsai-focused-ghidra-callees.json)，合计 13 个函数体/入口记录，保留 nm 边界、伪代码、汇编、原始样本及 arm64 切片 SHA-256。REA 全程序自动分析在 900000 ms 超时并关闭；替代分析使用 Ghidra -noanalysis 的有限反汇编/反编译，不冒充成功的 REA Evidence，也不伪造编号。

- validatePath 的 0x10043ceb0 是包装入口，实际实现为 0x10043ed90。可见空路径/NUL 检查、解析链接、路径规范化、保护路径集合与排除项比较，以及针对 /System 的拒绝分支。对这些分支的语义解释是结合汇编与字符串的分析判断，不等于所有链接都被拒绝或系统 SIP 状态已被检测。
- validateDeletion（0x10043de5c）比较数量与 0x2711，超过 10000 项时进入 SafetyError/throw 分支；未超限时逐项调用 validatePath。常量 getter 0x1003fa200 返回 10000。
- secureOverwrite（0x1000643f8）读取 fileSize、isDirectory、isSymbolicLink 等资源值。isDirectory 明确为 true 时走写入前错误分支，isSymbolicLink 明确为 true 时也有错误分支；nil/false 会绕过各自的检查，不能宣称“未知属性必定拒绝”或“所有模式只允许普通文件”。
- erase 的异步 resume（0x100063b04）包含逐项路径检查，但批量验证的不同错误并非全部提前终止；数量超限有零计数提前返回路径。伪代码含移除不可达块和未解析间接跳转警告，因此错误控制流须结合汇编阅读，不能仅凭一段伪代码判断全部情况。

结论限定为“上述具体函数内存在这些判断及边界”。未运行安全覆写，未验证恢复效果、所有入口的守卫覆盖或遥测状态。

APFS clone/合并目前作为后续评估线索。未验证原子替换、元数据保持、跨卷限制、实际回收量，不能承诺“保留全部文件即可释放全部冗余空间”。

### 2.4 腾讯柠檬与 CleanMyMac

腾讯柠檬 ev_2ecaa9b5 前缀对应 daemon 的 MCCMD 命令面；该清单说明存在特权操作入口，不能证明全产品没有撤销或备份。

CleanMyMac ev_39dd82c1a3f1bcad0f89120751e0816e169ae02d91d801bbbd1111bcd17b8274 对应 PrivilegedFileRemover.remove(at:)，包含未获授权时构造 NotAuthorizedPrivilegedAgentError 的分支。没有对整个产品恢复层做穷尽分析，因此撤回“没有通用撤销”的确定断言。ev_38a52e9b 对应的旧记录仅搜索到 SMAuthorizedClients 键，不能单凭它宣称具体白名单已逐连接验证。

本轮另用本机 LLVM 工具读取已安装 helper 的嵌入式 Info.plist，并由 plutil 解析为 [声明快照](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/cmm-helper-declared-clients.json)。声明包含主程序、Menu、HealthMonitor 三个精确 identifier，均要求 anchor apple generic 及 Team ID S8EX82NJP6。该快照保留二进制 SHA-256，属于静态元数据观察，不是 REA 记录或实际拒绝测试；helper 自报版本为 5.3.1，不能直接套用主程序 5.7.1 的版本号。

### 2.5 MacOptimizer

历史 ev_2b9fd8db5dd9349b4028e927499dbdc9b46aa09ba68136dbe4c9436b9a59baa2 支持 dry-run 初值为 true；ev_4286d8d1d79fda577f413af4a4e2f0f4bbf354810928b41ce55382296e490479 覆盖 clean() 的分支。ev_ad7614af47a599d095d3a0cf1989dc5410119991b4745e9b1cb2c6328720fb1f 的函数伪代码在 0x10004108c 将立即数 0x272066722d206d72 解为命令前缀，追加路径和单引号。

旧 ev_b6dadb38820e7791688d55b6848259ad2f4d30c8198487f7d24810e5c75b14f6 只有历史命令输出中的编号及两条字符串，完整原始记录未保存。已从有效证据索引退役，不把恢复的两行文本冒充完整 Evidence。替代它的完整函数记录为：

| 函数/分支 | 完整 Evidence ID | 实际支持的结论 |
| --- | --- | --- |
| 0x10004108c，performClean 的分支 | ev_30ed4109997c0a2ffb47a834660c33300f24eaa290aeb4b37f4af6f73bf74d14 | 存在类型判别；非值 4 的分支构造 rm -rf 路径命令，转后续普通执行分支 |
| 0x100041430，后续执行分支 | ev_d8079c69986872449b41ab0eb810528c265830b0bb34dfbf07c3e788050d0320 | 读取命令上下文并调用 ShellRunner.run；不是 runWithAdmin |
| 0x100032714，管理员执行器闭包 | ev_ae31d754913718e0cc5c86b406b304236f1bcdc2da8f8e728388aa4dfdbfe3c0 | 构造 NSTask、参数和终止处理器，并调用 launchAndReturnError；调用者含 performClean 的另一分支 0x10004114c |

原报告把普通删除和管理员分支合并成“关闭 dry-run 后经 osascript 提权删除”，这一表述撤回。新证据支持“普通分支具有 shell 命令拼接/永久删除风险；另有管理员执行器及独立调用分支”，不支持“所有清理都会提权”。尚未在本轮执行任何命令、验证命令注入或清理效果。Ghidra 对 Swift 参数和字符串拼接的恢复有误差，应结合完整汇编与历史 Hopper 记录阅读；三份完整输出保存在 raw/supplement/mo-*.json。

## 3. 特权、监控与硬件

### 3.1 自研 XPC：二进制与源码分开

新增 [sc-listener-accept.json](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/raw/supplement/sc-listener-accept.json)，Evidence ID ev_4676768fa21da81b791ce3639079d1cae4cb034de2b67eb4bbdd779522899f7f，对应已安装正式版 helper 的真实接入函数，入口 0x100005a4c。可见用户标识检查、currentSigner、setCodeSigningRequirement，之后才导出对象和 resume。

当前 2.0.1 源码另有：
- FileOperation 两端在 resume 前设置签名要求，要求精确对端 identifier 及共同叶证书指纹，构造失败拒绝。见 Sources/FileOperationHelper/main.swift:179、Sources/FileOperationShared/FileOperationContract.swift:69、AuthorizedApplicationMover.swift:52、AppUpdateProtectedApplicationAuthorization.swift:77。
- FanControl 服务端使用 audit token 定位代码，做静态签名验证，再比较完整非空证书链及精确 App identifier。见 Sources/FanControlHelper/main.swift:305、:2535 和 Sources/FanControlShared/HelperUpgradeSafety.swift:4。
- 普通 FanControl 接入还没有消息级 setCodeSigningRequirement 和动态有效性检查；功耗采样路径另有动态检查。App 的 FanControl XPC 连接也未绑定对端签名要求。见 FanControlCoordinator.swift:2189、FanControlHelper/main.swift:2413；已对应 BOARD L1/L7。
- 显式 Team ID、证书轮换兼容性需要单独评估，不能因为当前未直接比较 Team ID 就断言没有身份绑定。

以上源码结论不代表本次已做真实异签名连接拒绝测试。已有测试文本与是否运行通过分别记录。

### 3.2 腾讯柠檬与 iStat Menus

腾讯柠檬 ev_dc062814d00239a1935182fc5fa2c1add029db5e1319f0fb17f0615c9308572a 支持 listener 接入中使用 audit token、SecTask requirement 验证及可执行文件名检查。它是已观察到的身份验证设计，不因竞品采用而成为本项目的唯一实现方式。

iStat ev_30f97e11f635eb7309c9cbcc399d739c90909e93b53ba512b7a183f8bd5b12a5 与 ev_85cae73d038c68ca7b25259626b5fb019f57c02790879ff24ce5b937d0bc2283 支持客户端 teamid/identifier 哈希比较。团队哈希和一个 identifier 哈希可对应 MD5(Y93TK974AT)、MD5(com.bjango.istatmenus)；其余三个 identifier 哈希尚未还原。SMC、风扇、电池及天气能力部分来自字符串或接口清单，不视为本轮实机验证。

### 3.3 Stats

ev_bc6534b737cc62884566291bb50df1e5a2a6336a9b64797fdd15ee86137a6695 与 ev_4136ea046fd6877c6a268a3fb93c2575815576fda11d5c5d8e5a88bb196aac37：
- toggleRemoteControlState: 入口 0x1000171c4，内部实现 0x10001bae8。
- 仅在 state == 1 的启用分支构造 NSAlert，提供 Enable/Cancel，runModal 成功后提交启用；取消会还原开关。关闭分支直接提交 false。
- 该确认是启用时确认，不是“每次切换均确认”，也不是每项远程命令均确认。
- loginToRemote 和 handleRemoteUpdate 的转发函数、APNs/Keychain 相关符号支持存在远程子系统；当前启用状态、令牌有效性和实际网络行为仍未知。

Remote.framework 的空搜索只代表 Ghidra 已定义字符串集合内未命中所查字面量，不能证明字节中绝对不存在、没有运行时拼接或不联网。SMC helper 的 setFanSpeed/setFanMode/resetFanControl 等目前主要为符号/字符串级证据。

### 3.4 AlDente Pro：已分清 8 位与 32 位写入

8 位路径：setSMCByteWithKey:value:（0x100003480）转 0x100003120；Swift String.count 不等于 4 时进入陷阱，记账使用 modifiedKeysUInt8。旧 ev_9cd776a619a53547696acd819e5cfafdb92b6820431b3ee5a18c2e879d6fe1e8、ev_7d979f53fd42d03f7a8992cedc591fad5bd71922073fa9755de86582c1240083 支持该分支。

32 位路径：setSMCByte32WithKey:value:（0x1000030c0）转 0x100002b88；同样检查字符数量，记账使用 modifiedKeysUInt32，并按 4 字节值构造写入数据。新增完整证据：
- ev_aa336f40822eed13641513d55c11c77532e909ed471640b10946929d7d9aef75：[wrapper](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/raw/supplement/aldente-u32-wrapper.json)。
- ev_54783f57fc6a627812d197fc3e2904b8f22c9492b08bbcf8a355e7d448babc60：[实现](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/raw/supplement/aldente-u32-body.json)。

callDriver（0x10000a690）使用 0x50 字节结构调用 IOConnectCallStructMethod，并含 kIOReturnNotPrivileged 的处理，见 ev_9fb8f70848726e51777503acde88f355e2d3ce2671be1b6a15defed2b512ad16。本轮没有向 SMC 写值。硬件拒绝、恢复效果与安全性不由静态函数自动证明。

## 4. 联网与遥测的正确口径

本轮没有网络抓包或完整的所有网络入口审计。端点、SDK、诊断入口或 Keychain 符号的存在，不等于正在上报；局部搜索没有命中，也不能推出零遥测。

| 软件 | 静态观察 | 尚未证明 |
| --- | --- | --- |
| 腾讯柠檬 | 历史材料含 Bugly/QAPM、动态配置和 HTTP 日志端点线索 | 当前请求、上传内容、用户选择及覆盖面；不再按未测量流量排名“最重” |
| CleanMyMac | 历史材料含分析/授权/通知、Moonlock 和云 SDK 线索 | 默认发送哪些字段、是否启用、全部网络目的地 |
| Mac Sai / PureMac / MacOptimizer | 已检查部分更新或链接相关材料 | 不作“仅这些域名”“零遥测”或“完全不联网”的承诺 |
| iStat | 授权、更新、天气端点与定位/诊断相关接口 | 当前定位使用和请求内容 |
| Stats | 主程序含 api.mac-stats.com、system-stats.com 等线索 | 远程开关当前状态、实际注册和请求 |
| AlDente | 含分析上报端点和 Sparkle 线索 | 当前上报开关与流量 |
| 自研 | 有 Sparkle 与基准排行榜相关实现 | 本轮未审计客户端与服务端全部字段；不能仅凭客户端未显式发 IP 就承诺服务端无法观察 IP |

可复查的字符串记录见完整证据索引；未保留成完整 Evidence 的历史观察不升级为已证实网络行为。

## 5. 给 2.0.1 的修订建议

以现有 D98 和 BOARD 为准。以下是工程判断，不是从竞品直接复制实现或改变产品决定的命令。

### 已有措施：保留并核验

1. 保留 FileOperation 双向签名约束和 FanControl 服务端已有校验；相关测试、私有接口理由与源码守卫在当前工作树中已有代码，不再列为从零新增。
2. 保留 FanControl 启动恢复、恢复标记、RPM 硬件钳制、租约看门狗和闲时退出。正式版 RunAtLoad + KeepAlive{SuccessfulExit:false} 承担恢复/持久策略职责；Beta 构建为按需配置，不能用 Beta 结果代替正式版启动恢复验收。
3. 删除守卫已有固定命令/AppleScript/旧式提权检查；不变量测试覆盖既定用户文件清理入口。文本守卫不是完整数据流分析，不能一概禁止全部 Process 调用。
4. 密码保护已有固定路径/表适配器和触发器防护；浏览器备份策略是最长 7 天且最多 12 份，不保证每一份都保存满 7 天。agent 会话/历史/检查点排除也有规则与执行前复查，但有规则和遍历范围边界。

### 仍需核验：本轮不冒充已通过

- 相关定向测试和源码守卫在当前工作树的结果；本轮只做文档/证据修订，没有重新跑产品构建或全量测试。Claude 前一轮自报的门禁结果须沿用其原始日志，不写成本轮独立复现。
- 签名构建下的真实异证书、异 identifier XPC 拒绝与正确客户端通过。
- 正式版开机、异常退出、恢复失败和闲时退出；Beta/正式版启动配置差异。
- 遗留菜单清空废纸篓与 D23 冻结快照流程的差异。

### 后续优化：与 L1–L8 对齐，不机械实施旧 P0

优先评估 FanControl 客户端/服务端消息级身份约束和普通接入动态检查（L1/L7），以及旧菜单清空废纸篓的确认后重新枚举问题（L5）。后者可能包含确认之后新放入的项目；可考虑复用 D23 冻结计划和双确认，或移除重复入口。两项涉及既有边界，应按 D98 和项目决定选择批次。

保留 L2 的 Team ID/证书轮换评估、L3 的启动恢复差异、L4 的硬件操作记录、L6 的会话授权增量收益和 L8 的删除原语/外部进程清单。不能为了减少驻留而让必要恢复等待新的 UI 授权。

APFS 合并、全新监控模块和远程控制属于后续需求评估，不在 2.0.1 修复清单中顺带扩张。继续用现有回执、重型工作协调器、测试夹具和日志机制。

## 6. 持久证据、索引与复核

证据根目录：/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15

- [完整编号与原始文件索引](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/EVIDENCE_INDEX.md)：每项完整 Evidence ID、操作类型、文件路径及值流截断标记。
- [MANIFEST.json](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/MANIFEST.json)：原始 JSON 的 SHA-256、目标身份、源码快照哈希、仓库 HEAD 与工作树状态。
- [evidence-bundle.json](/Users/developer/Developer/reverse-engineering/cleaners-monitors-2026-10-15/evidence-bundle.json)：由 REA 校验/规范化的完整记录包，保留 provider 的局限与分析配置。
- raw/previous 为旧记录的逐字节副本；raw/supplement 为新增完整输出；source-snapshot 是源码审计快照，不冒充 REA Evidence。
- 历史 sc-main.json 仅初始化 listener；sc-help.json 是字符串搜索；sc-move.json 仅 defer。三者已与新增的真实接入、真实移动函数分开。
- 失败或超时输出留在 work 和 raw 的非 Evidence 文件中，不计为有效记录。

完整 Evidence ID 及存档不再依赖 /tmp。本文中的短前缀必须在索引内唯一解析；退役的 ev_b6dadb38 不再作为有效证明引用。已保存 74 份有效 REA 记录（67 份历史记录 + 7 份新增完整函数记录）与 20 份源码快照；Mac Sai 的 13 个直接 Ghidra 函数记录、安装/SDK/嵌入声明及失败日志单独列为非 REA 材料。REA evidence-export 已成功验证编号与规范清单并导出 evidence-bundle.json，记录数 74，文件 14067437 字节。

## 7. 未决事项

- 没有做目标程序的动态删除、恢复、提权、网络或硬件写入验收。
- Stats 远程控制和 AlDente 分析上报的当前开关状态未确认；不读取 Keychain 以填补这一问题。
- iStat 另外三个 identifier 哈希未还原，不影响本次报告错误修订，但白名单身份仍不完整。
- PureMac 管理员分支的实际执行载体及日志参数未完全闭合。
- 未以局部符号/字符串搜索证明任何产品绝对没有遥测、备份或撤销。
- 大型 Swift 函数可能有未解析间接调用、反编译类型错误、终止调用假设或截断值流；必须保留各记录自身 limitations。
- 五类报告修订已落实：真实函数替代错误片段、建议对照现有实现、绝对断言收窄、AlDente/Stats 分支纠正、持久证据与编号索引补齐。剩余未决项按以上边界保留，不把报告修订完成写成全产品逆向或动态安全验收完成。

## 8. 给 Claude Code 的交接要求

~~~text
用户要求：修正逆向报告、补齐证据后，交给正在开发 2.0.1 的 Claude Code，参考这些结果继续优化。
请读本修订版、持久证据索引和 manifest，并对照当前 D98、BOARD 与未提交改动查缺补漏。

不要把旧报告“两个 helper 没校验”“取消 RunAtLoad/KeepAlive 更安全”“所有入口均双重确认”当作事实。
不要回滚现有代码、重复添加已有机制，或把源码审计/静态分析写成运行时验证。

在现有授权与 D98 的 2.0.1 范围内，继续完成能复用现有实现的测试、守卫、证据/文档一致性改进。
涉及删除策略、签名信任边界或硬件生命周期的 L1–L8 项，先对照已有决定选择批次，明确收益和验收条件。
先确认收到这份修订材料并列出会采用/已完成/仍待实测的项目，然后继续当前工作。
不要代替用户提交、发布、安装或执行真实清理/硬件写入。
~~~

