# 跑分社区排行榜 v1

## 目标与边界

- 在现有“电脑健康中心 → Mac 跑分”页面内展示共享排行榜，不新增侧边栏页面。
- 排行榜显示名、处理器型号、六项总分和测试完成时间。
- 快速/完整模式以及工作负载版本分别排名，永不把不可比结果混排。
- 跑分始终在本机离线完成；只有用户打开确认页并点击“上传并公开显示”后才联网提交。
- 显示名默认读取 macOS 电脑名称，但允许用户在每次上传前修改。
- 客户端生成随机安装标识用于更新同一设备的榜单记录。它不是硬件标识，不使用序列号、硬件 UUID、MAC 地址、IP 地址或系统账户名。
- 服务端不保存请求 IP。Cloudflare 平台自身的安全与运行日志不属于排行榜数据表。
- 社区成绩不是设备身份证明。无账号、证明服务或可信执行环境时，处理器名称和测量值仍可能被修改，因此界面必须明确标注“社区上传，未验证硬件身份”。

## 排名规则

- v1 只接受 Apple Silicon、六项完整、满足本机可比条件且使用当前 v3 工作负载的结果。
- 允许 1.7.0 客户端上传本机历史中由 1.6.0 及以上版本产生的 v3 可比结果。
- `quick` 只接受 `mac-benchmark-quick-v3`；`full` 只接受 `mac-benchmark-full-v3`。
- 冻结基准版本为 `m5-pro-2026-07-v3`。
- 每项分数为 `1000 × clamp(实测中位数 / 冻结参考值, 0.2, 5.0)`，总分是六项直接相加。
- 服务端使用冻结参考值重新计算分数，不信任客户端提交的总分。
- 同一随机安装标识在同一模式/工作负载下只保留一条记录；新上传替换旧记录并更新完成时间。
- 排序为总分降序、完成时间升序、记录 ID 升序。

## HTTP API

所有 JSON 响应都带 `X-Leaderboard-Schema: 1`。错误格式稳定为：

```json
{
  "error": {
    "code": "invalid_submission",
    "message": "提交内容不符合排行榜要求",
    "details": { "field": "displayName" }
  }
}
```

### `GET /v1/health`

返回服务状态、schema 版本和当前冻结基准版本。

### `GET /v1/leaderboard`

参数：

- `profile`: `quick` 或 `full`，必填。
- `workloadVersion`: 与 profile 对应的 v3 工作负载，必填。
- `page`: 从 1 开始，默认 1。
- `pageSize`: 默认 50，范围 1...100。

成功响应：

```json
{
  "data": [
    {
      "id": "公开记录 ID",
      "rank": 1,
      "displayName": "工作室 Mac",
      "processorModel": "Apple M5 Pro",
      "score": 6123,
      "profile": "quick",
      "workloadVersion": "mac-benchmark-quick-v3",
      "completedAt": "2026-07-17T05:30:00.000Z"
    }
  ],
  "pagination": {
    "page": 1,
    "pageSize": 50,
    "total": 1,
    "totalPages": 1
  },
  "meta": {
    "baselineVersion": "m5-pro-2026-07-v3",
    "profile": "quick",
    "workloadVersion": "mac-benchmark-quick-v3",
    "generatedAt": "2026-07-17T05:31:00.000Z"
  }
}
```

### `POST /v1/submissions`

请求体：

```json
{
  "submissionId": "UUID",
  "installationId": "随机 UUID",
  "displayName": "工作室 Mac",
  "processorModel": "Apple M5 Pro",
  "profile": "quick",
  "workloadVersion": "mac-benchmark-quick-v3",
  "baselineVersion": "m5-pro-2026-07-v3",
  "architecture": "arm64",
  "completedAt": "2026-07-17T05:30:00.000Z",
  "appVersion": "1.7.0",
  "appBuild": "20260717xxxx",
  "conditions": {
    "powerSource": "acPower",
    "lowPowerModeEnabled": false,
    "preflightThermalState": "nominal",
    "postflightThermalState": "nominal"
  },
  "metrics": {
    "cpuSingle": 413.86,
    "cpuMulti": 6924.68,
    "gpu": 3319.99,
    "memory": 29.96,
    "diskRead": 0.1895,
    "diskWrite": 1.9313
  },
  "proposedScore": 6000
}
```

服务端校验字段长度、UUID、时间窗口、模式/工作负载/基准匹配、运行条件、六项有限正数、合理比值和客户端/服务端分数误差。`installationId` 只在 Worker 内通过服务端密钥做 HMAC，D1 不保存原值。

成功响应返回服务端重算后的记录、当前名次和 `created`/`updated` 状态。重复请求以安装标识、模式和工作负载为幂等边界。

### `DELETE /v1/submissions`

用户可在应用内明确确认后移除本机对应模式的公开成绩。请求只包含随机安装标识、模式和工作负载版本；服务端使用相同 HMAC 定位记录。删除接口幂等，不存在的记录返回 `deleted: false`。

## UI 状态

- 未加载：显示说明与“刷新排行榜”。
- 加载：保留已有内容并显示轻量进度，不阻塞本机跑分。
- 空榜：明确提示尚无人上传，不伪造示例成绩。
- 失败：显示可恢复错误和单一“重试”动作。
- 可上传：仅在当前结果具有可比分数、完整六项、当前 v3 键匹配时显示上传动作。
- 上传确认：显示可编辑名称、处理器、分数、模式、时间和将公开的数据说明；用户必须勾选公开确认。
- 上传成功：刷新对应榜单并高亮本机刚上传的记录。
- 上传失败：保留确认页内容以便重试，不把失败显示为已发布。
- 已上传：提供一个含二次确认的“移除我的成绩”动作，不影响本机历史。

## 运维与发布门槛

- D1 migration、Worker 单元测试、本地 D1 集成测试通过。
- Worker 使用 Cloudflare secret 保存 HMAC 密钥，密钥不得提交 Git。
- 真实部署、健康检查、写入、读取、替换同一安装记录和限流行为验证通过后，客户端才写入生产 URL。
- Swift 针对模型解码、输入清洗、请求构造、并发代际和 UI 文案添加测试。
- 完成全量测试、打包、安装和真实 UI 检查后再发布 1.7.0；不得重新校准或改写 1.6.0 冻结基准。
