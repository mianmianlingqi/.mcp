# MCP_CellLine_Sim_V17 仿真实战验证指南

> 适用包：`TIA_V17_PLC_Software_MCP_Phase2_Deliverable_20260608_101552`  
> 目标：用一个可下载到 `S7-PLCSIM V17` 的灌装输送线工程，验证 Phase2 MCP 的 PLC 软件生成、编译、导出、迁移和读回能力。

## 1. 验证边界

- MCP 负责离线工程生成、PLC 软件对象写入、编译诊断、保存、导出、迁移和读回。
- TIA Portal UI + S7-PLCSIM V17 负责下载到仿真 CPU、RUN、在线变量修改和截图留证。
- 不测试真实 PLC 下载。
- 不测试 Online、监控写值、HMI、Unified、Reports。
- 当前 Phase2 工具面故意不暴露 `DownloadToPlc`、`GoOnline`、`SetWatchTableModifyValue`。

## 2. 一键生成实战工程

先启动 Phase2 MCP 服务：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "A:\project\TIA_V17_PLC_Software_MCP_Phase2_Deliverable_20260608_101552\scripts\Start-PlcSoftwareMcpV17Phase2.ps1"
```

执行仿真实战验证脚本：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "A:\project\TIA_V17_PLC_Software_MCP_Phase2_Deliverable_20260608_101552\scripts\Invoke-McpCellLineSimV17Validation.ps1"
```

只生成目录、SCL 和手工指南，不调用 MCP：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "A:\project\TIA_V17_PLC_Software_MCP_Phase2_Deliverable_20260608_101552\scripts\Invoke-McpCellLineSimV17Validation.ps1" -PrepareOnly
```

默认输出目录：

```text
A:\project\TIA_MCP_PracticalValidation\MCP_CellLine_Sim_V17\YYYYMMDD_HHMMSS\
```

关键文件：

- `projects\MCP_CellLine_Sim_Main\MCP_CellLine_Sim_Main.ap17`
- `_mcp_reports\acceptance-summary.json`
- `_mcp_reports\acceptance-summary.md`
- `_mcp_reports\plcsim-manual-validation.md`
- `_mcp_logs\*.request.json`
- `_mcp_logs\*.response.json`
- `_mcp_exports\`

## 3. 工程对象

固定对象名：

- PLC：`PLC_1`
- 标签表：`TT_IO_Map`、`TT_SimControl`、`TT_Commissioning`
- 监控表：`WT_Simulation`
- UDT：`UDT_DeviceState`、`UDT_AlarmState`、`UDT_Recipe`
- DB：`DB_SimControl`、`DB_ProcessData`、`DB_Alarms`、`DB_Recipe`
- FB：`FB_ModeManager`、`FB_Conveyor`、`FB_FillStation`、`FB_PlantSimulator`、`FB_AlarmManager`
- FC：`FC_IOMap`、`FC_ResetCounters`
- OB：`OB1`

仿真控制入口：

- `DB_SimControl.EnableSim`
- `DB_SimControl.StartCmd`
- `DB_SimControl.StopCmd`
- `DB_SimControl.ResetCmd`
- `DB_SimControl.EStop`
- `DB_SimControl.BottlePresentOverride`
- `DB_SimControl.LevelLowOverride`
- `DB_SimControl.FillTimeoutFaultInject`

备用 M 区入口：

- `Sim_Enable` `%M20.0`
- `Sim_Start` `%M20.1`
- `Sim_Stop` `%M20.2`
- `Sim_Reset` `%M20.3`
- `Sim_EStop` `%M20.4`
- `Sim_BottlePresent` `%M20.5`
- `Sim_LevelLow` `%M20.6`
- `Sim_FillTimeoutFault` `%M20.7`

仿真输出观察点：

- `DB_ProcessData.SystemReady`
- `DB_ProcessData.CycleStep`
- `DB_ProcessData.ConveyorRunning`
- `DB_ProcessData.BottleAtFillStation`
- `DB_ProcessData.FillValveOpen`
- `DB_ProcessData.TankLevel`
- `DB_ProcessData.GoodBottleCount`
- `DB_ProcessData.ActiveAlarmCode`

## 4. PLCSIM V17 手工仿真

1. 用 TIA Portal V17 打开 `MCP_CellLine_Sim_Main.ap17`。
2. 启动 `S7-PLCSIM V17`。
3. 在 TIA Portal 中选择 `PLC_1`，下载到仿真 CPU。
4. 将仿真 CPU 切到 RUN。
5. 打开 `WT_Simulation`。
6. 设置 `Sim_Enable := TRUE`。
7. 设置 `Sim_Start := TRUE`，保持一个扫描周期后复位为 `FALSE`。
8. 观察 `CycleStep` 从 `0 -> 10 -> 20 -> 30 -> 0`。
9. 观察 `ConveyorRunning`、`BottleAtFillStation`、`FillValveOpen`、`TankLevel`。
10. 确认 `GoodBottleCount >= 1`。
11. 设置 `Sim_EStop := TRUE`，确认 `ActiveAlarmCode=100`，输送和阀门停止。
12. 复位 `Sim_EStop := FALSE`，再置位 `Sim_Reset := TRUE` 一个扫描周期。
13. 再次启动，确认系统可重复运行。

## 5. MCP 通过标准

- `tools/list` 与 Phase2 manifest 匹配，工具面为 `74/74`。
- 工程创建成功。
- PLC 设备创建成功。
- UDT、DB、标签表、FB、FC、监控表均可读回。
- `CompileAndDiagnosePlc` 无失败诊断。
- 保存、关闭、重开后对象不丢失。
- 块、类型、标签表、监控表和迁移包均可导出。
- Documents 四个 V17 gated 工具返回 `requires TIA Portal V20 or newer`。

## 6. PLCSIM 通过标准

- 工程可下载到 S7-PLCSIM V17。
- CPU 可进入 RUN。
- `SystemReady` 可置 TRUE。
- 启动后 `CycleStep` 按流程推进。
- `GoodBottleCount` 至少增加 1。
- `Sim_EStop` 注入后设备停机并产生报警。
- 复位后系统可再次启动。

## 7. 失败处理

- 若 `Another project is already open`，先关闭 TIA Portal 中其他工程，再重启 MCP 服务。
- 若 OB1 外部源未自动生成，打开脚本输出的 `artifacts\scl\OB1.scl`，在 TIA Portal UI 中作为外部源手工导入并生成块，再编译。
- 若下载到 PLCSIM 失败，先在 TIA UI 中手工完整编译一次，再下载。
- 若监控表无法写 DB 符号变量，优先使用 `Sim_*` M 区变量执行仿真。

## 8. 建议证据

- `_mcp_reports\acceptance-summary.md`
- `_mcp_reports\acceptance-summary.json`
- `_mcp_logs\*.request.json`
- `_mcp_logs\*.response.json`
- `_mcp_exports\migration_bundle\manifest.json`
- PLCSIM CPU RUN 截图
- `WT_Simulation` 正常循环截图
- `WT_Simulation` 报警注入截图
- `GoodBottleCount >= 1` 截图
