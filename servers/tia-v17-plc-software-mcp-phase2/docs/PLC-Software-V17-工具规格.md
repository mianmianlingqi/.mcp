# PLC-Software V17 工具规格

本规格记录 `Phase 2 / Beta` 公开工具。

二期 profile 为 `plc-software-v17-phase2`。

最终状态只使用 `success`、`gated`、`failed`。`beta` 只表示二期新增能力的成熟度标签，验证报告里仍会落到 `success/gated/failed`。

## 二期新增

| 工具 | 类别 | Phase2 status | 验收方式 | 备注 |
|---|---|---|---|---|
| CreateTechnologyObject | TO | beta | `1211C DC/DC/DC + PID_Compact` 创建、编译、读回 | 其他 TO 类型不作为二期成功承诺 |
| ExportTechnologyObjectsToDirectory | TO | beta | PID_Compact 批量导出目录实际落盘 | 依赖 `GetTechnologyObjects` 能读回 TO |

## 工具矩阵

| 工具 | 类别 | V17 状态 | Phase2 status | 验收方式 |
|---|---|---|---|---|
| Bootstrap | 底座 | success | success | tools/list + 自检 |
| RunCapabilitySelfTest | 底座 | success | success | 只读自检 |
| Connect | 底座 | success | success | 附着或启动 TIA Portal |
| Disconnect | 底座 | success | success | 释放 Openness 连接 |
| ListPortalProcessProjects | 底座 | success | success | 枚举 Portal 进程和工程 |
| EnsureOpennessUserGroup | 底座 | success | success | 用户组检查 |
| GetState | 底座 | success | success | 状态读回 |
| GetProject | 底座 | success | success | 工程列表读回 |
| OpenProject | 底座 | success | success | 同路径前台工程优先附着 |
| AttachToOpenProject | 底座 | success | success | 按名称附着 |
| CreateProject | 底座 | success | success | 新建 V17 工程 |
| SaveProject | 底座 | success | success | 显式保存 |
| CloseProject | 底座 | success | success | 关闭当前工程 |
| GetProjectTree | 底座 | success | success | 读回 `PLC_1` |
| SearchHardwareCatalog | 底座 | success | success | 搜索 1211C |
| AddDeviceWithFallback | 底座 | success | success | 添加 `6ES7211-1AE40-0XB0`，优先 V4.7，允许 V4.5 |
| BuildPlcUdtXml | PLC-Builders | success | success | 离线构建 |
| BuildPlcTagTableXml | PLC-Builders | success | success | 离线构建 |
| BuildPlcGlobalDbXml | PLC-Builders | success | success | 离线构建 |
| BuildStructuredTextXml | PLC-Builders | success | success | 离线构建 |
| BuildFlgNetCallXml | PLC-Builders | success | success | 离线构建 |
| ComposePlcFcBlockXml | PLC-Builders | success | success | 离线构建 |
| ComposePlcFbBlockXml | PLC-Builders | success | success | 离线构建 |
| ComposePlcLadFcBlockXml | PLC-Builders | success | success | 离线构建 |
| BuildPlcSymbolManifestFromXmlPath | PLC-Builders | success | success | fixture XML 解析 |
| GetSoftwareInfo | PLC-Software | success | success | 结构化读回 |
| PlcBuildAndImport | PLC-Software | success | success | tagtable/udt/globaldb；V17 FC/FB 主路径改用外部 SCL |
| GetCrossReferences | PLC-Software | success | success | 真实引用关系非空 |
| GetPlcExternalSources | PLC-Software | success | success | 外部源列表 |
| GetPlcTagTables | PLC-Software | success | success | 变量表列表 |
| ExportPlcTagTable | PLC-Software | success | success | 文件落盘 |
| ImportPlcTagTable | PLC-Software | success | success | 导入后读回 |
| ImportPlcTagTablesFromDirectory | PLC-Software | success | success | 批量导入后读回 |
| GetPlcWatchTables | PLC-Software | success | success | 监控表列表 |
| ExportPlcWatchTable | PLC-Software | success | success | 文件落盘 |
| ExportPlcWatchTablesToDirectory | PLC-Software | success | success | 目录落盘 |
| EnsurePlcWatchTableEntry | PLC-Software | beta | beta | 离线创建监控表地址条目；不写 PLC 值 |
| ImportTechnologyObject | TO | success | success | PID_Compact fixture 导入 |
| ImportTechnologyObjectsFromDirectory | TO | success | success | PID_Compact fixture 批量导入 |
| ImportPlcExternalSource | PLC-Software | success | success | SCL 外部源导入 |
| DeletePlcExternalSource | PLC-Software | success | success | 幂等删除 |
| GenerateBlocksFromExternalSource | PLC-Software | success | success | 生成 FC/FB |
| CompileSoftware | PLC-Software | success | success | 0 error |
| GetSoftwareTree | PLC-Software | success | success | 块/类型树读回 |
| GetBlockInfo | PLC-Software | success | success | 精确路径读回 |
| GetPlcDbMembers | PLC-Software | success | success | GlobalDB 成员读回 |
| GetBlocks | PLC-Software | success | success | 块列表 |
| GetBlocksWithHierarchy | PLC-Software | success | success | 层级块列表 |
| ExportBlock | PLC-Software | success | success | 文件落盘 |
| ExportBlockToTemp | PLC-Software | success | success | temp 路径存在 |
| ImportBlock | PLC-Software | success | success | 导入后编译 |
| ImportBlocksFromDirectory | PLC-Software | success | success | 批量导入后编译 |
| ImportPlcProgramFromDirectory | PLC-Software | success | success | 全程序回灌 |
| CompileAndDiagnosePlc | PLC-Software | success | success | 无失败诊断 |
| RepairAndReimportBlock | PLC-Software | success | success | 导入并编译 |
| ExportBlocks | PLC-Software | success | success | 批量文件落盘 |
| ExportBlocksToTemp | PLC-Software | success | success | temp 路径存在 |
| ExportPlcMigrationBundle | PLC-Software | success | success | bundle 和 manifest 落盘 |
| GetTypeInfo | PLC-Software | success | success | 类型详情读回 |
| GetTypes | PLC-Software | success | success | 类型列表 |
| ExportType | PLC-Software | success | success | 文件落盘 |
| ExportTypeToTemp | PLC-Software | success | success | temp 路径存在 |
| ImportType | PLC-Software | success | success | 导入后读回 |
| SeedProjectFromReference | PLC-Software | success | success | `failed.Count=0` |
| ExportTypes | PLC-Software | success | success | 批量类型落盘 |
| ExportTypesToTemp | PLC-Software | success | success | temp 路径存在 |
| GetTechnologyObjects | TO | success | success | PID_Compact 读回 |
| ExportTechnologyObject | TO | success | success | XML 实际落盘 |
| CreateTechnologyObject | TO | success | beta | PID_Compact 候选版本创建、读回、编译 |
| ExportTechnologyObjectsToDirectory | TO | success | beta | TO XML 批量落盘 |
| ExportAsDocuments | Documents | gated | gated | V17 返回 V20+ 门禁 |
| ExportBlocksAsDocuments | Documents | gated | gated | V17 返回 V20+ 门禁 |
| ImportFromDocuments | Documents | gated | gated | V17 返回 V20+ 门禁 |
| ImportBlocksFromDocuments | Documents | gated | gated | V17 返回 V20+ 门禁 |

## 明确排除

- HMI、Unified、Classic HMI。
- Online 下载、上线、监控、写值。
- Reflection 泛化工具。
- Reports 工具。
- `SetWatchTableModifyValue` 等在线写值或潜在设备写入工具。
- `GetTechnologyObjectProperties` 这类探索性反射工具，二期不对外交付。

## 证据入口

- `reports\latest\summary.json`
- `reports\latest\summary.md`
- `reports\latest\tool-surface.json`
- `reports\latest\e2e-results.json`

## 验收命令

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File A:\project\TIA_V17_PLC_Software_MCP_Phase2\scripts\Verify-PlcSoftwareMcpV17Phase2.ps1
```

如果只验证工具面：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File A:\project\TIA_V17_PLC_Software_MCP_Phase2\scripts\Verify-PlcSoftwareMcpV17Phase2.ps1 -ToolSurfaceOnly
```
