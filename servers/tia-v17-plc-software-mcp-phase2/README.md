# TIA Portal V17 PLC-Software MCP 二期包

这是一个本地交付用的 `Phase 2 / Beta` 目录。

> Git 仓库版说明：本目录只保存源码、脚本、manifest、docs 和 fixtures，不提交 `runtime/`、`reports/`、TIA 工程、日志或调试符号。需要运行时，请先执行验证脚本构建，或使用本机已固化的交付包 runtime。

二期继续只暴露 PLC-Software 相关能力和最小可用底座，不物理裁剪 HMI、Online、Reflection 等源码。

默认 HTTP 地址为 `http://127.0.0.1:8770/mcp`，默认 API key 为 `codex-test-key`。

## 环境要求

- Windows + TIA Portal V17。
- 当前用户已加入 `Siemens TIA Openness` 用户组。
- 已安装 .NET Framework 4.8 与可用的 `dotnet` CLI。
- 运行脚本统一使用 `pwsh -NoProfile -ExecutionPolicy Bypass -File ...`。
- 低负载端到端验证前建议只保留必要的 TIA Portal 实例，避免内存不足。

## 启动

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-PlcSoftwareMcpV17Phase2.ps1
```

可选环境变量：

- `TIA_MCP_HTTP_PORT`：默认 `8770`。
- `TIA_MCP_HTTP_API_KEY`：默认 `codex-test-key`。
- `TIA_MCP_HTTP_RESPONSE_TIMEOUT_SECONDS`：默认 `300`，用于覆盖本地 HTTP 桥等待 TIA 长耗时操作的响应时间。

启动脚本固定使用 `plc-software-v17-phase2` profile。

## 停止

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Stop-PlcSoftwareMcpV17Phase2.ps1
```

停止脚本只停止本目录 `runtime\TiaMcpServer.exe` 对应的 MCP 服务，不会自动关闭你的 TIA Portal UI，也不会误杀其他工作区服务。

## 验证

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Verify-PlcSoftwareMcpV17Phase2.ps1
```

验证脚本会串行执行：

- 构建 `tools\tiaportal-mcp\src\TiaMcpServer\TiaMcpServer.V17.csproj`。
- 同步构建输出到 `runtime\`。
- 启动二期 HTTP 服务。
- 调用 `tools/list`，断言只暴露 `manifest\tools-list.phase2.json` 中的 74 个工具。
- 断言不出现 HMI、Unified、Online、Reflection、Reports、写值、下载和泛化反射工具。
- 低负载通过后，继续执行 CreateProject、AddDevice 1211C、PlcBuildAndImport、GlobalDB、FC/FB、TO 创建/导出/导入、Documents 门禁等端到端验证。

报告输出：

- `reports\latest\summary.json`
- `reports\latest\summary.md`
- `reports\latest\tool-surface.json`
- `reports\latest\e2e-results.json`

只做工具面验证：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Verify-PlcSoftwareMcpV17Phase2.ps1 -ToolSurfaceOnly
```

## 二期新增能力

二期在一期 71 个工具基础上新增：

- `CreateTechnologyObject`
- `ExportTechnologyObjectsToDirectory`

TO 创建优先以 `1211C DC/DC/DC + PID_Compact` 验证。

其他 TO 类型可以探索，但不作为二期成功承诺。

## 能力边界

支持：

- 连接、打开、新建、保存、关闭工程。
- 搜索硬件目录，添加 `1211C DC/DC/DC`，默认 MLFB 为 `6ES7211-1AE40-0XB0`。
- PLC tag table、UDT、GlobalDB、FC、FB 创建和导入。
- FC/FB 在 V17 固定走外部 SCL 导入，再执行 `GenerateBlocksFromExternalSource`。
- 块、类型、变量表、监控表、外部源、Technology Object 的导入导出。
- PLC 编译与结构化诊断。
- V17 不支持的 Documents 工具返回明确版本门禁。

不暴露：

- HMI、Unified、Classic HMI。
- Online 下载、上线、监控、写值。
- Reflection 泛化工具。
- Reports 工具。
- 未验证的 WatchTable 在线编辑/写值类工具。

## 目录结构

| 路径 | 作用 |
|---|---|
| `tools\` | Phase2 源码，保留完整底座，通过 profile 控制暴露面 |
| `runtime\` | 本地构建后的运行时，默认不提交到 Git |
| `scripts\` | Phase1/Phase2 启动、停止、验证脚本 |
| `manifest\tools-list.phase2.json` | 二期工具 allowlist |
| `docs\` | 工具规格、SCL 外部导入说明、二期状态说明 |
| `fixtures\technology-object\` | PID_Compact TO XML fixture |
| `reports\latest\` | 最近一次验证报告和服务日志，默认不提交到 Git |

## 常见故障

- 端口占用：启动脚本会拒绝启动，避免误连旧服务。先停止占用端口的 MCP 服务，或换用 `TIA_MCP_HTTP_PORT`。
- HTTP 504：通常是 TIA 操作耗时超过本地 HTTP 桥超时。二期默认已提升到 300 秒；仍不足时设置 `TIA_MCP_HTTP_RESPONSE_TIMEOUT_SECONDS=600` 后重启服务。
- TIA Portal 进程过多：验证脚本默认阈值为 12 个 Portal 进程，超过会进入 `gated`，不会继续开项目。
- 无 Openness 权限：先调用 `EnsureOpennessUserGroup`，加入用户组后重新登录 Windows。
- `Another project is already open`：二期验证脚本会在大场景之间主动 Save/Close/Disconnect；如果仍出现，优先检查前台是否已有同路径工程被 UI 打开。
- V17 Documents 工具失败：这是版本门禁，V17 使用 XML 导入导出或外部 SCL。
