param(
    [string]$BaseUrl = $(if ($env:TIA_MCP_BASE_URL) { $env:TIA_MCP_BASE_URL } else { 'http://127.0.0.1:8770/mcp' }),
    [string]$ApiKey = $(if ($env:TIA_MCP_HTTP_API_KEY) { $env:TIA_MCP_HTTP_API_KEY } else { 'codex-test-key' }),
    [string]$WorkspaceRoot = 'A:\project\TIA_MCP_PracticalValidation',
    [int]$ConnectTimeoutSec = 600,
    [int]$ProjectTimeoutSec = 600,
    [int]$BuildTimeoutSec = 420,
    [int]$CompileTimeoutSec = 600,
    [switch]$PrepareOnly,
    [switch]$SkipReplica,
    [switch]$KeepProjectOpen
)

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
chcp 65001 > $null
$ErrorActionPreference = 'Stop'

$ProtocolVersion = '2025-03-26'
$ProductRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ManifestPath = Join-Path $ProductRoot 'manifest\tools-list.phase2.json'
$RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$ValidationRoot = Join-Path $WorkspaceRoot 'MCP_CellLine_Sim_V17'
$RunRoot = Join-Path $ValidationRoot $RunStamp
$ProjectRoot = Join-Path $RunRoot 'projects'
$MainProjectName = 'MCP_CellLine_Sim_Main'
$ReplicaProjectName = 'MCP_CellLine_Sim_Replica'
$MainProjectDir = Join-Path $ProjectRoot $MainProjectName
$ReplicaProjectDir = Join-Path $ProjectRoot $ReplicaProjectName
$MainProjectPath = Join-Path $MainProjectDir "$MainProjectName.ap17"
$ReplicaProjectPath = Join-Path $ReplicaProjectDir "$ReplicaProjectName.ap17"
$ArtifactsRoot = Join-Path $RunRoot 'artifacts'
$SclDir = Join-Path $ArtifactsRoot 'scl'
$McpLogsDir = Join-Path $RunRoot '_mcp_logs'
$McpReportsDir = Join-Path $RunRoot '_mcp_reports'
$McpExportsDir = Join-Path $RunRoot '_mcp_exports'
$BlockExportDir = Join-Path $McpExportsDir 'blocks'
$TypeExportDir = Join-Path $McpExportsDir 'types'
$TagExportDir = Join-Path $McpExportsDir 'tagTables'
$WatchExportDir = Join-Path $McpExportsDir 'watchTables'
$MigrationDir = Join-Path $McpExportsDir 'migration_bundle'
$DocGateDir = Join-Path $McpExportsDir 'doc_gate'
$DeviceName = 'PLC_1'
$SoftwarePath = 'PLC_1'
$PreferredCpuMlfb = '6ES7211-1AE40-0XB0'
$PreferredCpuVersion = 'V4.7'
$WatchTableName = 'WT_Simulation'

$Names = [ordered]@{
    TagTables = @('TT_IO_Map', 'TT_SimControl', 'TT_Commissioning')
    Udts = @('UDT_DeviceState', 'UDT_AlarmState', 'UDT_Recipe')
    Dbs = @('DB_SimControl', 'DB_ProcessData', 'DB_Alarms', 'DB_Recipe')
    Blocks = @('FB_ModeManager', 'FB_Conveyor', 'FB_FillStation', 'FB_PlantSimulator', 'FB_AlarmManager', 'FC_IOMap', 'FC_ResetCounters', 'OB1')
}

New-Item -ItemType Directory -Force -Path @(
    $RunRoot,
    $ProjectRoot,
    $ArtifactsRoot,
    $SclDir,
    $McpLogsDir,
    $McpReportsDir,
    $McpExportsDir,
    $BlockExportDir,
    $TypeExportDir,
    $TagExportDir,
    $WatchExportDir,
    $MigrationDir,
    $DocGateDir
) | Out-Null

$script:SessionId = $null
$script:RequestId = 0
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:Context = [ordered]@{}

function Save-Text {
    param([string]$Name, [string]$Content)
    $path = Join-Path $McpLogsDir $Name
    Set-Content -LiteralPath $path -Value $Content -Encoding UTF8
    return $path
}

function Get-ToolText {
    param([object]$ToolCallJson)
    if ($null -eq $ToolCallJson) { return $null }
    try {
        $text = $ToolCallJson.result.content[0].text
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return [string]$text
    }
    catch {
        return $null
    }
}

function Convert-ToolTextToObject {
    param([string]$ToolText)
    if ([string]::IsNullOrWhiteSpace($ToolText)) { return $null }
    try { return $ToolText | ConvertFrom-Json -Depth 100 } catch { return $null }
}

function Invoke-McpRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [object]$Params = $null,
        [switch]$Notification,
        [int]$TimeoutSec = 180
    )

    $headers = @{
        'X-API-Key' = $ApiKey
        'Accept' = 'application/json'
        'Content-Type' = 'application/json'
        'MCP-Protocol-Version' = $ProtocolVersion
    }
    if ($script:SessionId) {
        $headers['Mcp-Session-Id'] = $script:SessionId
    }

    $payload = @{ jsonrpc = '2.0'; method = $Method }
    $displayId = 'notification'
    if (-not $Notification) {
        $script:RequestId++
        $payload.id = $script:RequestId
        $displayId = '{0:D3}' -f $script:RequestId
    }
    if ($null -ne $Params) { $payload.params = $Params }

    $json = $payload | ConvertTo-Json -Depth 100 -Compress
    $safeMethod = $Method -replace '[^A-Za-z0-9_.-]', '_'
    Save-Text -Name "${displayId}_${safeMethod}.request.json" -Content $json | Out-Null

    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $BaseUrl -Headers $headers -Body $json -TimeoutSec $TimeoutSec
    $responseSession = $response.Headers['Mcp-Session-Id']
    if ($responseSession) { $script:SessionId = $responseSession }
    Save-Text -Name "${displayId}_${safeMethod}.response.json" -Content $response.Content | Out-Null

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; SessionId = $responseSession; Content = ''; Json = $null }
    }
    return [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        SessionId = $responseSession
        Content = $response.Content
        Json = $response.Content | ConvertFrom-Json -Depth 100
    }
}

function Initialize-McpSession {
    $script:SessionId = $null
    $script:RequestId = 0
    $null = Invoke-McpRequest -Method 'initialize' -Params @{
        protocolVersion = $ProtocolVersion
        capabilities = @{}
        clientInfo = @{ name = 'mcp-cellline-sim-v17-validation'; version = '1.0' }
    } -TimeoutSec 120
    $null = Invoke-McpRequest -Method 'notifications/initialized' -Notification -TimeoutSec 120
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Arguments = @{},
        [int]$TimeoutSec = 180
    )

    $resp = Invoke-McpRequest -Method 'tools/call' -Params @{
        name = $Name
        arguments = $Arguments
    } -TimeoutSec $TimeoutSec

    $toolText = Get-ToolText -ToolCallJson $resp.Json
    $toolResult = Convert-ToolTextToObject -ToolText $toolText

    [pscustomobject]@{
        Name = $Name
        Arguments = $Arguments
        StatusCode = $resp.StatusCode
        SessionId = $resp.SessionId
        Raw = $resp.Json
        ToolText = $toolText
        ToolResult = $toolResult
    }
}

function Test-ToolSuccess {
    param([object]$ToolResponse)

    if ($null -eq $ToolResponse) { return $false }
    if ($ToolResponse.Raw.PSObject.Properties.Name -contains 'error' -and $null -ne $ToolResponse.Raw.error) { return $false }
    if ($ToolResponse.Raw.result.isError -eq $true) { return $false }

    $result = $ToolResponse.ToolResult
    $text = [string]$ToolResponse.ToolText
    if ($null -ne $result) {
        if ($result.PSObject.Properties.Name -contains 'meta' -and $null -ne $result.meta -and $result.meta.PSObject.Properties.Name -contains 'success') {
            if (-not [bool]$result.meta.success) { return $false }
        }
        elseif ($result.PSObject.Properties.Name -contains 'success') {
            if (-not [bool]$result.success) { return $false }
        }
        elseif ($result.PSObject.Properties.Name -contains 'ok') {
            if (-not [bool]$result.ok) { return $false }
        }

        if ($result.PSObject.Properties.Name -contains 'failed' -and @($result.failed).Count -gt 0) { return $false }
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return ($text -notmatch '(?i)\bfailed\b|\berror\b|not found')
}

function Add-Result {
    param(
        [string]$Step,
        [string]$Phase,
        [string]$Status,
        [string]$Detail = '',
        [hashtable]$Evidence = @{}
    )

    $script:Results.Add([pscustomobject]@{
        step = $Step
        phase = $Phase
        status = $Status
        detail = $Detail
        evidence = $Evidence
        timestamp = (Get-Date).ToString('s')
    }) | Out-Null
}

function Invoke-CheckedTool {
    param(
        [string]$ToolName,
        [hashtable]$Arguments = @{},
        [string]$Phase = '',
        [int]$TimeoutSec = 180,
        [scriptblock]$SuccessEvaluator = $null,
        [switch]$AllowFailure
    )

    try {
        $resp = Invoke-Tool -Name $ToolName -Arguments $Arguments -TimeoutSec $TimeoutSec
        $ok = if ($null -ne $SuccessEvaluator) { & $SuccessEvaluator $resp } else { Test-ToolSuccess $resp }
        $detail = if ($null -ne $resp.ToolResult) {
            ($resp.ToolResult | ConvertTo-Json -Depth 60 -Compress)
        } elseif (-not [string]::IsNullOrWhiteSpace($resp.ToolText)) {
            $resp.ToolText
        } else {
            ($resp.Raw | ConvertTo-Json -Depth 30 -Compress)
        }
        Add-Result -Step $ToolName -Phase $Phase -Status ($(if ($ok) { 'success' } else { 'failed' })) -Detail $detail
        if (-not $ok -and -not $AllowFailure) { throw "$ToolName failed in phase '$Phase': $detail" }
        return $resp
    }
    catch {
        Add-Result -Step $ToolName -Phase $Phase -Status 'failed' -Detail $_.Exception.Message
        if (-not $AllowFailure) { throw }
        return $null
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-PathHasNonEmptyFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        return @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 }).Count -gt 0
    }
    return $item.Length -gt 0
}

function Flatten-BlockHierarchy {
    param([object]$Group, [string]$Prefix = '')
    $items = @()
    if ($null -eq $Group) { return $items }
    foreach ($block in @($Group.blocks)) {
        $path = if ($block.path) { [string]$block.path } elseif ($Prefix) { "$Prefix/$($block.name)" } else { [string]$block.name }
        $items += [pscustomobject]@{ path = $path; name = [string]$block.name; typeName = [string]$block.typeName }
    }
    foreach ($child in @($Group.groups)) {
        $childPrefix = if ($Prefix) { "$Prefix/$($child.name)" } else { [string]$child.name }
        $items += Flatten-BlockHierarchy -Group $child -Prefix $childPrefix
    }
    return $items
}

function Get-ExactBlockPath {
    param([string]$Name, [object]$HierarchyResponse)
    $items = Flatten-BlockHierarchy -Group $HierarchyResponse.ToolResult.root
    $match = @($items | Where-Object { $_.name -eq $Name })
    Assert-True ($match.Count -eq 1) "块 '$Name' 精确路径解析失败，匹配数=$($match.Count)"
    return [string]$match[0].path
}

function Get-ExactTypePath {
    param([string]$Name, [object]$TypesResponse)
    $match = @($TypesResponse.ToolResult.items | Where-Object { $_.name -eq $Name })
    Assert-True ($match.Count -eq 1) "类型 '$Name' 精确路径解析失败，匹配数=$($match.Count)"
    return [string]$match[0].path
}

function Get-SimpleMember {
    param(
        [string]$Name,
        [string]$Datatype,
        [string]$StartValue = $null,
        [string]$Comment = ''
    )
    $h = [ordered]@{ name = $Name; datatype = $Datatype }
    if ($PSBoundParameters.ContainsKey('StartValue')) { $h.startValue = $StartValue }
    if (-not [string]::IsNullOrWhiteSpace($Comment)) { $h.commentZhCn = $Comment }
    return $h
}

function New-TagTableJson {
    param([string]$Name)

    $tags = switch ($Name) {
        'TT_IO_Map' {
            @(
                @{ name = 'DI_StartPB'; dataTypeName = 'Bool'; logicalAddress = '%I0.0' },
                @{ name = 'DI_StopPB'; dataTypeName = 'Bool'; logicalAddress = '%I0.1' },
                @{ name = 'DI_ResetPB'; dataTypeName = 'Bool'; logicalAddress = '%I0.2' },
                @{ name = 'DI_EStop'; dataTypeName = 'Bool'; logicalAddress = '%I0.3' },
                @{ name = 'DI_BottlePresent'; dataTypeName = 'Bool'; logicalAddress = '%I0.4' },
                @{ name = 'DI_LevelLow'; dataTypeName = 'Bool'; logicalAddress = '%I0.5' },
                @{ name = 'DO_ConveyorMotor'; dataTypeName = 'Bool'; logicalAddress = '%Q0.0' },
                @{ name = 'DO_FillValve'; dataTypeName = 'Bool'; logicalAddress = '%Q0.1' },
                @{ name = 'DO_AlarmHorn'; dataTypeName = 'Bool'; logicalAddress = '%Q0.2' }
            )
        }
        'TT_SimControl' {
            @(
                @{ name = 'Sim_Enable'; dataTypeName = 'Bool'; logicalAddress = '%M20.0' },
                @{ name = 'Sim_Start'; dataTypeName = 'Bool'; logicalAddress = '%M20.1' },
                @{ name = 'Sim_Stop'; dataTypeName = 'Bool'; logicalAddress = '%M20.2' },
                @{ name = 'Sim_Reset'; dataTypeName = 'Bool'; logicalAddress = '%M20.3' },
                @{ name = 'Sim_EStop'; dataTypeName = 'Bool'; logicalAddress = '%M20.4' },
                @{ name = 'Sim_BottlePresent'; dataTypeName = 'Bool'; logicalAddress = '%M20.5' },
                @{ name = 'Sim_LevelLow'; dataTypeName = 'Bool'; logicalAddress = '%M20.6' },
                @{ name = 'Sim_FillTimeoutFault'; dataTypeName = 'Bool'; logicalAddress = '%M20.7' }
            )
        }
        default {
            @(
                @{ name = 'Comm_SystemReady'; dataTypeName = 'Bool'; logicalAddress = '%M30.0' },
                @{ name = 'Comm_ConveyorRunning'; dataTypeName = 'Bool'; logicalAddress = '%M30.1' },
                @{ name = 'Comm_BottleAtFillStation'; dataTypeName = 'Bool'; logicalAddress = '%M30.2' },
                @{ name = 'Comm_FillValveOpen'; dataTypeName = 'Bool'; logicalAddress = '%M30.3' },
                @{ name = 'Comm_AlarmActive'; dataTypeName = 'Bool'; logicalAddress = '%M30.4' }
            )
        }
    }

    return (@{ tableName = $Name; tags = $tags } | ConvertTo-Json -Depth 30 -Compress)
}

function New-UdtJson {
    param([string]$Name)

    $members = switch ($Name) {
        'UDT_DeviceState' {
            @(
                Get-SimpleMember -Name 'AutoMode' -Datatype 'Bool'
                Get-SimpleMember -Name 'ManualMode' -Datatype 'Bool'
                Get-SimpleMember -Name 'Running' -Datatype 'Bool'
                Get-SimpleMember -Name 'Faulted' -Datatype 'Bool'
                Get-SimpleMember -Name 'StepNo' -Datatype 'Int'
                Get-SimpleMember -Name 'CycleCount' -Datatype 'DInt'
            )
        }
        'UDT_AlarmState' {
            @(
                Get-SimpleMember -Name 'Active' -Datatype 'Bool'
                Get-SimpleMember -Name 'Code' -Datatype 'Int'
                Get-SimpleMember -Name 'EStop' -Datatype 'Bool'
                Get-SimpleMember -Name 'LevelLow' -Datatype 'Bool'
                Get-SimpleMember -Name 'FillTimeout' -Datatype 'Bool'
            )
        }
        default {
            @(
                Get-SimpleMember -Name 'FillSetpoint' -Datatype 'Real'
                Get-SimpleMember -Name 'ConveyorDelayCycles' -Datatype 'Int'
                Get-SimpleMember -Name 'FillCycles' -Datatype 'Int'
                Get-SimpleMember -Name 'MaxRejects' -Datatype 'Int'
            )
        }
    }

    return (@{ name = $Name; members = $members } | ConvertTo-Json -Depth 30 -Compress)
}

function New-DbJson {
    param([string]$Name)

    $dbNumber = switch ($Name) {
        'DB_SimControl' { 410 }
        'DB_ProcessData' { 411 }
        'DB_Alarms' { 412 }
        'DB_Recipe' { 413 }
        default { 419 }
    }

    $members = switch ($Name) {
        'DB_SimControl' {
            @(
                Get-SimpleMember -Name 'EnableSim' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'StartCmd' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'StopCmd' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'ResetCmd' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'EStop' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'BottlePresentOverride' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'LevelLowOverride' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'FillTimeoutFaultInject' -Datatype 'Bool' -StartValue 'FALSE'
            )
        }
        'DB_ProcessData' {
            @(
                Get-SimpleMember -Name 'ConveyorRunning' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'BottleAtFillStation' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'FillValveOpen' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'TankLevel' -Datatype 'Real' -StartValue '20.0'
                Get-SimpleMember -Name 'CycleStep' -Datatype 'Int' -StartValue '0'
                Get-SimpleMember -Name 'GoodBottleCount' -Datatype 'DInt' -StartValue '0'
                Get-SimpleMember -Name 'RejectBottleCount' -Datatype 'DInt' -StartValue '0'
                Get-SimpleMember -Name 'ActiveAlarmCode' -Datatype 'Int' -StartValue '0'
                Get-SimpleMember -Name 'SystemReady' -Datatype 'Bool' -StartValue 'FALSE'
                Get-SimpleMember -Name 'StepTicks' -Datatype 'Int' -StartValue '0'
            )
        }
        'DB_Alarms' {
            @(
                Get-SimpleMember -Name 'State' -Datatype 'UDT_AlarmState'
                Get-SimpleMember -Name 'LastAlarmCode' -Datatype 'Int' -StartValue '0'
                Get-SimpleMember -Name 'AlarmLatch' -Datatype 'Bool' -StartValue 'FALSE'
            )
        }
        default {
            @(
                Get-SimpleMember -Name 'ActiveRecipe' -Datatype 'UDT_Recipe'
                Get-SimpleMember -Name 'FillSetpoint' -Datatype 'Real' -StartValue '80.0'
                Get-SimpleMember -Name 'ConveyorDelayCycles' -Datatype 'Int' -StartValue '15'
                Get-SimpleMember -Name 'FillCycles' -Datatype 'Int' -StartValue '30'
            )
        }
    }

    return (@{ dbName = $Name; dbNumber = $dbNumber; staticMembers = $members } | ConvertTo-Json -Depth 50 -Compress)
}

function New-FbJson {
    param([string]$Name, [int]$Number)
    return (@{
        blockName = $Name
        blockNumber = $Number
        inputs = @(@{ name = 'Enable'; datatype = 'Bool' })
        outputs = @(@{ name = 'Active'; datatype = 'Bool' })
        statics = @(@{ name = 'RunMemory'; datatype = 'Bool' })
        structuredText = @{
            operations = @(
                @{ op = 'assignment'; target = 'RunMemory'; source = 'Enable' },
                @{ op = 'assignment'; target = 'Active'; source = 'RunMemory' }
            )
        }
    } | ConvertTo-Json -Depth 40 -Compress)
}

function New-FcJson {
    param([string]$Name, [int]$Number)
    return (@{
        blockName = $Name
        blockNumber = $Number
        inputs = @(@{ name = 'InSignal'; datatype = 'Bool' })
        outputs = @(@{ name = 'OutSignal'; datatype = 'Bool' })
        structuredText = @{
            operations = @(
                @{ op = 'assignment'; target = 'OutSignal'; source = 'InSignal' }
            )
        }
    } | ConvertTo-Json -Depth 40 -Compress)
}

function New-FbScl {
    param([string]$Name)
    return @"
FUNCTION_BLOCK "$Name"
{ S7_Optimized_Access := 'TRUE' }
VERSION : 0.1
VAR_INPUT
    Enable : Bool;
END_VAR
VAR_OUTPUT
    Active : Bool;
END_VAR
VAR
    RunMemory : Bool;
END_VAR
BEGIN
    #RunMemory := #Enable;
    #Active := #RunMemory;
END_FUNCTION_BLOCK
"@
}

function New-FcScl {
    param([string]$Name)
    return @"
FUNCTION "$Name" : Void
{ S7_Optimized_Access := 'TRUE' }
VERSION : 0.1
VAR_INPUT
    InSignal : Bool;
END_VAR
VAR_OUTPUT
    OutSignal : Bool;
END_VAR
BEGIN
    #OutSignal := #InSignal;
END_FUNCTION
"@
}

function New-Ob1Scl {
    return @'
ORGANIZATION_BLOCK "OB1"
{ S7_Optimized_Access := 'TRUE' }
VERSION : 0.1
VAR_TEMP
    StartPulse : Bool;
    StopActive : Bool;
    ResetActive : Bool;
    FaultActive : Bool;
    BottlePresent : Bool;
    LevelLow : Bool;
END_VAR
BEGIN
    #StartPulse := "DB_SimControl".StartCmd OR "Sim_Start";
    #StopActive := "DB_SimControl".StopCmd OR "Sim_Stop";
    #ResetActive := "DB_SimControl".ResetCmd OR "Sim_Reset";
    #BottlePresent := "DB_SimControl".BottlePresentOverride OR "Sim_BottlePresent" OR "DI_BottlePresent";
    #LevelLow := "DB_SimControl".LevelLowOverride OR "Sim_LevelLow" OR "DI_LevelLow";
    #FaultActive := "DB_SimControl".EStop OR "Sim_EStop" OR "DI_EStop" OR #LevelLow OR "DB_SimControl".FillTimeoutFaultInject OR "Sim_FillTimeoutFault";

    "DB_ProcessData".SystemReady := "DB_SimControl".EnableSim OR "Sim_Enable";

    IF #ResetActive THEN
        "DB_ProcessData".CycleStep := 0;
        "DB_ProcessData".StepTicks := 0;
        "DB_ProcessData".ConveyorRunning := FALSE;
        "DB_ProcessData".BottleAtFillStation := FALSE;
        "DB_ProcessData".FillValveOpen := FALSE;
        "DB_ProcessData".ActiveAlarmCode := 0;
        "DB_Alarms".AlarmLatch := FALSE;
        "DB_Alarms".State.Active := FALSE;
        "DB_Alarms".State.Code := 0;
        "DB_Alarms".State.EStop := FALSE;
        "DB_Alarms".State.LevelLow := FALSE;
        "DB_Alarms".State.FillTimeout := FALSE;
    END_IF;

    IF NOT "DB_ProcessData".SystemReady THEN
        "DB_ProcessData".CycleStep := 0;
        "DB_ProcessData".ConveyorRunning := FALSE;
        "DB_ProcessData".FillValveOpen := FALSE;
    ELSIF #FaultActive THEN
        "DB_ProcessData".ConveyorRunning := FALSE;
        "DB_ProcessData".FillValveOpen := FALSE;
        "DB_ProcessData".ActiveAlarmCode := 100;
        "DB_Alarms".AlarmLatch := TRUE;
        "DB_Alarms".State.Active := TRUE;
        "DB_Alarms".State.Code := 100;
        "DB_Alarms".State.EStop := "DB_SimControl".EStop OR "Sim_EStop" OR "DI_EStop";
        "DB_Alarms".State.LevelLow := #LevelLow;
        "DB_Alarms".State.FillTimeout := "DB_SimControl".FillTimeoutFaultInject OR "Sim_FillTimeoutFault";
    ELSIF #StopActive THEN
        "DB_ProcessData".ConveyorRunning := FALSE;
        "DB_ProcessData".FillValveOpen := FALSE;
    ELSE
        "DB_ProcessData".ActiveAlarmCode := 0;
        "DB_Alarms".State.Active := FALSE;
        "DB_Alarms".State.Code := 0;

        CASE "DB_ProcessData".CycleStep OF
            0:
                "DB_ProcessData".ConveyorRunning := FALSE;
                "DB_ProcessData".FillValveOpen := FALSE;
                "DB_ProcessData".BottleAtFillStation := FALSE;
                "DB_ProcessData".StepTicks := 0;
                IF #StartPulse THEN
                    "DB_ProcessData".CycleStep := 10;
                END_IF;
            10:
                "DB_ProcessData".ConveyorRunning := TRUE;
                "DB_ProcessData".FillValveOpen := FALSE;
                "DB_ProcessData".StepTicks := "DB_ProcessData".StepTicks + 1;
                IF #BottlePresent OR ("DB_ProcessData".StepTicks >= "DB_Recipe".ConveyorDelayCycles) THEN
                    "DB_ProcessData".BottleAtFillStation := TRUE;
                    "DB_ProcessData".ConveyorRunning := FALSE;
                    "DB_ProcessData".StepTicks := 0;
                    "DB_ProcessData".CycleStep := 20;
                END_IF;
            20:
                "DB_ProcessData".FillValveOpen := TRUE;
                "DB_ProcessData".StepTicks := "DB_ProcessData".StepTicks + 1;
                IF "DB_ProcessData".TankLevel < "DB_Recipe".FillSetpoint THEN
                    "DB_ProcessData".TankLevel := "DB_ProcessData".TankLevel + 2.5;
                END_IF;
                IF ("DB_ProcessData".TankLevel >= "DB_Recipe".FillSetpoint) OR ("DB_ProcessData".StepTicks >= "DB_Recipe".FillCycles) THEN
                    "DB_ProcessData".FillValveOpen := FALSE;
                    "DB_ProcessData".StepTicks := 0;
                    "DB_ProcessData".CycleStep := 30;
                END_IF;
            30:
                "DB_ProcessData".GoodBottleCount := "DB_ProcessData".GoodBottleCount + 1;
                "DB_ProcessData".BottleAtFillStation := FALSE;
                "DB_ProcessData".TankLevel := 20.0;
                "DB_ProcessData".CycleStep := 0;
            ELSE
                "DB_ProcessData".CycleStep := 0;
        END_CASE;
    END_IF;

    "Comm_SystemReady" := "DB_ProcessData".SystemReady;
    "Comm_ConveyorRunning" := "DB_ProcessData".ConveyorRunning;
    "Comm_BottleAtFillStation" := "DB_ProcessData".BottleAtFillStation;
    "Comm_FillValveOpen" := "DB_ProcessData".FillValveOpen;
    "Comm_AlarmActive" := "DB_Alarms".State.Active;
    "DO_ConveyorMotor" := "DB_ProcessData".ConveyorRunning;
    "DO_FillValve" := "DB_ProcessData".FillValveOpen;
    "DO_AlarmHorn" := "DB_Alarms".State.Active;
END_ORGANIZATION_BLOCK
'@
}

function New-ManualGuide {
    param([string]$ProjectPath, [string]$ReportPath)

    return @"
# MCP_CellLine_Sim_V17 PLCSIM 手工仿真记录

## 工程

- 工程路径：`$ProjectPath`
- MCP 报告：`$ReportPath`
- PLC：`PLC_1`
- 监控表：`WT_Simulation`

## S7-PLCSIM V17 操作步骤

1. 用 TIA Portal V17 打开工程。
2. 启动 S7-PLCSIM V17。
3. 在 TIA Portal 中选择 `PLC_1`，下载到仿真 CPU。
4. 将仿真 CPU 切到 RUN。
5. 打开 `WT_Simulation`。
6. 设置 `Sim_Enable := TRUE`，或设置 `"DB_SimControl".EnableSim := TRUE`。
7. 设置 `Sim_Start := TRUE` 一个扫描周期后复位为 `FALSE`，或设置 `"DB_SimControl".StartCmd`。
8. 观察以下变量：
   - `"DB_ProcessData".SystemReady`
   - `"DB_ProcessData".CycleStep`
   - `"DB_ProcessData".ConveyorRunning`
   - `"DB_ProcessData".BottleAtFillStation`
   - `"DB_ProcessData".FillValveOpen`
   - `"DB_ProcessData".TankLevel`
   - `"DB_ProcessData".GoodBottleCount`
9. 注入报警：
   - `Sim_EStop := TRUE`
   - 或 `"DB_SimControl".EStop := TRUE`
10. 验证停机后执行复位：
   - `Sim_EStop := FALSE`
   - `Sim_Reset := TRUE` 一个扫描周期后复位为 `FALSE`

## 通过标准

- CPU 可进入 RUN。
- `SystemReady` 可置 TRUE。
- `CycleStep` 可按 `0 -> 10 -> 20 -> 30 -> 0` 推进。
- `GoodBottleCount` 至少增加 1。
- `Sim_EStop` 注入后 `ActiveAlarmCode=100` 且输出停机。
- 复位后系统可再次启动。

## 现场证据

- [ ] CPU RUN 截图
- [ ] 正常循环截图
- [ ] 报警注入截图
- [ ] `GoodBottleCount >= 1` 截图
"@
}

function Write-GeneratedSources {
    $ob1Path = Join-Path $SclDir 'OB1.scl'
    Set-Content -LiteralPath $ob1Path -Value (New-Ob1Scl) -Encoding UTF8
    $script:Context.ob1SclPath = $ob1Path
    return $ob1Path
}

function Import-SclBlock {
    param(
        [string]$BlockName,
        [string]$SclText,
        [string]$Phase
    )

    $path = Join-Path $SclDir "$BlockName.scl"
    Set-Content -LiteralPath $path -Value $SclText -Encoding UTF8
    $null = Invoke-CheckedTool -ToolName 'ImportPlcExternalSource' -Phase $Phase -Arguments @{
        softwarePath = $SoftwarePath
        groupPath = ''
        filePath = $path
    } -TimeoutSec 180
    $null = Invoke-CheckedTool -ToolName 'GenerateBlocksFromExternalSource' -Phase $Phase -Arguments @{
        softwarePath = $SoftwarePath
        externalSourceName = $BlockName
    } -TimeoutSec $BuildTimeoutSec
    return $path
}

function Assert-ToolSurface {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "未找到工具 manifest：$ManifestPath" }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $ManifestPath | ConvertFrom-Json -Depth 100
    $expected = @($manifest.tools | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
    Initialize-McpSession
    $listed = Invoke-McpRequest -Method 'tools/list' -TimeoutSec 120
    $actual = @($listed.Json.result.tools | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
    $missing = @($expected | Where-Object { $actual -notcontains $_ })
    $extra = @($actual | Where-Object { $expected -notcontains $_ })
    $banned = @('DownloadToPlc', 'GoOnline', 'GoOffline', 'SetWatchTableModifyValue', 'HMI', 'Unified', 'Reports', 'DescribeObject')
    $bannedActual = @($actual | Where-Object { $banned -contains $_ })
    $surface = [pscustomobject]@{
        status = if ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $bannedActual.Count -eq 0) { 'success' } else { 'failed' }
        expectedCount = $expected.Count
        actualCount = $actual.Count
        missing = $missing
        extra = $extra
        bannedActual = $bannedActual
        actualTools = $actual
    }
    $surface | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Join-Path $McpReportsDir 'tool-surface.json') -Encoding UTF8
    Add-Result -Step 'tools/list' -Phase 'precheck' -Status $surface.status -Detail "actual=$($surface.actualCount), expected=$($surface.expectedCount)"
    Assert-True ($surface.status -eq 'success') "工具面验证失败：missing=$($missing -join ','), extra=$($extra -join ','), banned=$($bannedActual -join ',')"
    return $surface
}

function Invoke-DocumentGateChecks {
    param([string]$AnyBlockPath)
    $cases = @(
        @{ name = 'ExportAsDocuments'; args = @{ softwarePath = $SoftwarePath; blockPath = $AnyBlockPath; exportPath = $DocGateDir }; expect = 'requires TIA Portal V20 or newer' },
        @{ name = 'ExportBlocksAsDocuments'; args = @{ softwarePath = $SoftwarePath; exportPath = $DocGateDir; regexName = '.*' }; expect = 'requires TIA Portal V20 or newer' },
        @{ name = 'ImportFromDocuments'; args = @{ softwarePath = $SoftwarePath; groupPath = ''; importPath = $DocGateDir; fileNameWithoutExtension = 'missing-doc'; importOption = 'Override' }; expect = 'requires TIA Portal V20 or newer' },
        @{ name = 'ImportBlocksFromDocuments'; args = @{ softwarePath = $SoftwarePath; groupPath = ''; importPath = $DocGateDir; regexName = '.*'; importOption = 'Override' }; expect = 'requires TIA Portal V20 or newer' }
    )

    $gateResults = foreach ($case in $cases) {
        try {
            $resp = Invoke-Tool -Name $case.name -Arguments $case.args -TimeoutSec 180
            $text = if ($resp.ToolText) { [string]$resp.ToolText } else { ($resp.Raw | ConvertTo-Json -Depth 20 -Compress) }
            $ok = $text -match [regex]::Escape($case.expect)
            Add-Result -Step $case.name -Phase 'doc-gate' -Status ($(if ($ok) { 'gated' } else { 'failed' })) -Detail $text
            [pscustomobject]@{ tool = $case.name; status = $(if ($ok) { 'gated' } else { 'failed' }); detail = $text }
        }
        catch {
            $text = $_.Exception.Message
            $ok = $text -match [regex]::Escape($case.expect)
            Add-Result -Step $case.name -Phase 'doc-gate' -Status ($(if ($ok) { 'gated' } else { 'failed' })) -Detail $text
            [pscustomobject]@{ tool = $case.name; status = $(if ($ok) { 'gated' } else { 'failed' }); detail = $text }
        }
    }

    $gateResults | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $McpReportsDir 'document-gates.json') -Encoding UTF8
    $failed = @($gateResults | Where-Object { $_.status -ne 'gated' })
    Assert-True ($failed.Count -eq 0) "Documents 门禁验证失败：$($failed.tool -join ', ')"
}

function New-AcceptanceReport {
    param([object]$Summary)

    $lines = @()
    $lines += '# MCP_CellLine_Sim_V17 验收摘要'
    $lines += ''
    $lines += ('运行时间：{0}' -f $RunStamp)
    $lines += ('工程路径：`{0}`' -f $MainProjectPath)
    $lines += ('副本工程：`{0}`' -f $ReplicaProjectPath)
    $lines += ('PLCSIM 指南：`{0}`' -f $Summary.plcsimGuidePath)
    $lines += ''
    $lines += '## MCP 结果'
    $lines += ''
    $lines += '| Step | Phase | Status |'
    $lines += '|---|---|---|'
    foreach ($item in $script:Results) {
        $lines += "| $($item.step) | $($item.phase) | $($item.status) |"
    }
    $lines += ''
    $lines += '## PLCSIM 手工验证'
    $lines += ''
    $lines += '- MCP 不执行下载、上线、监控写值。'
    $lines += '- 使用 TIA Portal V17 + S7-PLCSIM V17 打开主工程后，按 PLCSIM 指南完成 RUN、启动、循环、报警和复位验证。'
    $lines += '- 截图建议放在 `_mcp_reports\plcsim-screenshots`。'
    $lines += ''
    $lines += '## 关键产物'
    $lines += ''
    $lines += ('- MCP 请求/响应：`{0}`' -f $McpLogsDir)
    $lines += ('- MCP 导出：`{0}`' -f $McpExportsDir)
    $lines += ('- SCL 源文件：`{0}`' -f $SclDir)
    $lines += ('- JSON 摘要：`{0}`' -f (Join-Path $McpReportsDir 'acceptance-summary.json'))
    return $lines -join [Environment]::NewLine
}

$ob1SclPath = Write-GeneratedSources
$script:Context.runRoot = $RunRoot
$script:Context.mainProjectPath = $MainProjectPath
$script:Context.replicaProjectPath = $ReplicaProjectPath
$script:Context.exportsDir = $McpExportsDir
$script:Context.sclDir = $SclDir

if ($PrepareOnly) {
    $guidePath = Join-Path $McpReportsDir 'plcsim-manual-validation.md'
    New-ManualGuide -ProjectPath $MainProjectPath -ReportPath (Join-Path $McpReportsDir 'acceptance-summary.md') |
        Set-Content -LiteralPath $guidePath -Encoding UTF8
    $summary = [pscustomobject]@{
        mode = 'prepare-only'
        runStamp = $RunStamp
        runRoot = $RunRoot
        mainProjectPath = $MainProjectPath
        generatedSources = @($ob1SclPath)
        plcsimGuidePath = $guidePath
    }
    $summary | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Join-Path $McpReportsDir 'acceptance-summary.json') -Encoding UTF8
    Add-Result -Step 'PrepareOnly' -Phase 'prepare' -Status 'success' -Detail '已生成目录、OB1 SCL 和 PLCSIM 手工验证指南，未调用 MCP。'
    New-AcceptanceReport -Summary $summary | Set-Content -LiteralPath (Join-Path $McpReportsDir 'acceptance-summary.md') -Encoding UTF8
    Write-Host "prepare-only summary: $(Join-Path $McpReportsDir 'acceptance-summary.json')"
    return
}

try {
    $surface = Assert-ToolSurface
    Initialize-McpSession

    $null = Invoke-CheckedTool -ToolName 'Bootstrap' -Phase 'common' -TimeoutSec 120
    $null = Invoke-CheckedTool -ToolName 'Connect' -Phase 'common' -TimeoutSec $ConnectTimeoutSec
    $null = Invoke-CheckedTool -ToolName 'EnsureOpennessUserGroup' -Phase 'common' -TimeoutSec 120 -AllowFailure

    $null = Invoke-CheckedTool -ToolName 'CreateProject' -Phase 'main' -Arguments @{
        directoryPath = $ProjectRoot
        projectName = $MainProjectName
    } -TimeoutSec $ProjectTimeoutSec

    $null = Invoke-CheckedTool -ToolName 'SearchHardwareCatalog' -Phase 'main' -Arguments @{
        keyword = 'S7-1211C DC/DC/DC'
        limit = 10
    } -TimeoutSec 240 -AllowFailure

    $null = Invoke-CheckedTool -ToolName 'AddDeviceWithFallback' -Phase 'main' -Arguments @{
        preferredMlfb = $PreferredCpuMlfb
        preferredVersion = $PreferredCpuVersion
        deviceName = $DeviceName
        family = 'S7-1200'
    } -TimeoutSec $ProjectTimeoutSec

    $null = Invoke-CheckedTool -ToolName 'SaveProject' -Phase 'main' -TimeoutSec 180
    $null = Invoke-CheckedTool -ToolName 'GetProjectTree' -Phase 'main' -TimeoutSec 180
    $null = Invoke-CheckedTool -ToolName 'GetSoftwareInfo' -Phase 'main' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
    $null = Invoke-CheckedTool -ToolName 'GetSoftwareTree' -Phase 'main' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180

    foreach ($udt in $Names.Udts) {
        $null = Invoke-CheckedTool -ToolName 'PlcBuildAndImport' -Phase 'main-build-udt' -Arguments @{
            softwarePath = $SoftwarePath
            kind = 'udt'
            json = (New-UdtJson -Name $udt)
            dryRun = $false
            compileAfter = $true
        } -TimeoutSec $BuildTimeoutSec
    }

    foreach ($tagTable in $Names.TagTables) {
        $null = Invoke-CheckedTool -ToolName 'PlcBuildAndImport' -Phase 'main-build-tagtable' -Arguments @{
            softwarePath = $SoftwarePath
            kind = 'tagtable'
            json = (New-TagTableJson -Name $tagTable)
            dryRun = $false
            compileAfter = $true
        } -TimeoutSec $BuildTimeoutSec
    }

    foreach ($db in $Names.Dbs) {
        $null = Invoke-CheckedTool -ToolName 'PlcBuildAndImport' -Phase 'main-build-db' -Arguments @{
            softwarePath = $SoftwarePath
            kind = 'globaldb'
            json = (New-DbJson -Name $db)
            dryRun = $false
            compileAfter = $true
        } -TimeoutSec $BuildTimeoutSec
    }

    foreach ($fb in @('FB_ModeManager', 'FB_Conveyor', 'FB_FillStation', 'FB_PlantSimulator', 'FB_AlarmManager')) {
        $null = Import-SclBlock -BlockName $fb -SclText (New-FbScl -Name $fb) -Phase 'main-build-fb-scl'
    }

    foreach ($fc in @('FC_IOMap', 'FC_ResetCounters')) {
        $null = Import-SclBlock -BlockName $fc -SclText (New-FcScl -Name $fc) -Phase 'main-build-fc-scl'
    }

    $null = Invoke-CheckedTool -ToolName 'ImportPlcExternalSource' -Phase 'main-ob1' -Arguments @{
        softwarePath = $SoftwarePath
        groupPath = ''
        filePath = $ob1SclPath
    } -TimeoutSec 180 -AllowFailure

    $null = Invoke-CheckedTool -ToolName 'GenerateBlocksFromExternalSource' -Phase 'main-ob1' -Arguments @{
        softwarePath = $SoftwarePath
        externalSourceName = 'OB1'
    } -TimeoutSec $BuildTimeoutSec -AllowFailure

    $watchAddresses = @(
        'Sim_Enable',
        'Sim_Start',
        'Sim_Stop',
        'Sim_Reset',
        'Sim_EStop',
        'Sim_BottlePresent',
        'Sim_LevelLow',
        'Sim_FillTimeoutFault',
        'Comm_SystemReady',
        'Comm_ConveyorRunning',
        'Comm_BottleAtFillStation',
        'Comm_FillValveOpen',
        'Comm_AlarmActive'
    )
    foreach ($address in $watchAddresses) {
        $null = Invoke-CheckedTool -ToolName 'EnsurePlcWatchTableEntry' -Phase 'main-watch' -Arguments @{
            softwarePath = $SoftwarePath
            tableName = $WatchTableName
            address = $address
        } -TimeoutSec 180
    }

    $compile = Invoke-CheckedTool -ToolName 'CompileAndDiagnosePlc' -Phase 'main' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec $CompileTimeoutSec -SuccessEvaluator {
        param($resp)
        if (-not (Test-ToolSuccess $resp)) { return $false }
        return [int]$resp.ToolResult.errorCount -eq 0
    }

    $blockHierarchy = Invoke-CheckedTool -ToolName 'GetBlocksWithHierarchy' -Phase 'main-readback' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
    $types = Invoke-CheckedTool -ToolName 'GetTypes' -Phase 'main-readback' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
    $tagTables = Invoke-CheckedTool -ToolName 'GetPlcTagTables' -Phase 'main-readback' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
    $watchTables = Invoke-CheckedTool -ToolName 'GetPlcWatchTables' -Phase 'main-readback' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
    $blocks = Invoke-CheckedTool -ToolName 'GetBlocks' -Phase 'main-readback' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180

    $blockPaths = @{}
    foreach ($name in @('DB_SimControl', 'DB_ProcessData', 'DB_Alarms', 'DB_Recipe', 'FB_ModeManager', 'FB_Conveyor', 'FB_FillStation', 'FB_PlantSimulator', 'FB_AlarmManager', 'FC_IOMap', 'FC_ResetCounters')) {
        $blockPaths[$name] = Get-ExactBlockPath -Name $name -HierarchyResponse $blockHierarchy
    }
    $typePaths = @{}
    foreach ($name in $Names.Udts) {
        $typePaths[$name] = Get-ExactTypePath -Name $name -TypesResponse $types
    }
    $script:Context.blockPaths = $blockPaths
    $script:Context.typePaths = $typePaths

    $null = Invoke-CheckedTool -ToolName 'GetPlcDbMembers' -Phase 'main-readback' -Arguments @{
        softwarePath = $SoftwarePath
        blockPath = $blockPaths['DB_ProcessData']
    } -TimeoutSec 180 -SuccessEvaluator {
        param($resp)
        if (-not (Test-ToolSuccess $resp)) { return $false }
        $memberNames = @($resp.ToolResult.members | ForEach-Object { $_.name })
        return ($memberNames -contains 'ConveyorRunning') -and ($memberNames -contains 'GoodBottleCount') -and ($memberNames -contains 'SystemReady')
    }

    $null = Invoke-CheckedTool -ToolName 'GetCrossReferences' -Phase 'main-readback' -Arguments @{
        softwarePath = $SoftwarePath
        objectPath = $blockPaths['DB_ProcessData']
        objectKind = 'Block'
        filter = 'AllObjects'
    } -TimeoutSec 180 -AllowFailure

    foreach ($tagTable in $Names.TagTables) {
        $null = Invoke-CheckedTool -ToolName 'ExportPlcTagTable' -Phase 'main-export' -Arguments @{
            softwarePath = $SoftwarePath
            tagTableName = $tagTable
            exportPath = (Join-Path $TagExportDir "$tagTable.xml")
        } -TimeoutSec 180 -SuccessEvaluator { param($resp) (Test-ToolSuccess $resp) -and (Test-PathHasNonEmptyFile -Path (Join-Path $TagExportDir "$tagTable.xml")) }
    }

    $null = Invoke-CheckedTool -ToolName 'ExportPlcWatchTable' -Phase 'main-export' -Arguments @{
        softwarePath = $SoftwarePath
        watchTableName = $WatchTableName
        exportPath = (Join-Path $WatchExportDir "$WatchTableName.xml")
    } -TimeoutSec 180 -SuccessEvaluator { param($resp) (Test-ToolSuccess $resp) -and (Test-PathHasNonEmptyFile -Path (Join-Path $WatchExportDir "$WatchTableName.xml")) }

    $null = Invoke-CheckedTool -ToolName 'ExportPlcWatchTablesToDirectory' -Phase 'main-export' -Arguments @{
        softwarePath = $SoftwarePath
        dir = $WatchExportDir
        regexName = "^$WatchTableName$"
    } -TimeoutSec 180

    foreach ($typeName in $Names.Udts) {
        $null = Invoke-CheckedTool -ToolName 'ExportType' -Phase 'main-export' -Arguments @{
            softwarePath = $SoftwarePath
            exportPath = $TypeExportDir
            typePath = $typePaths[$typeName]
            preservePath = $false
        } -TimeoutSec 180
    }

    foreach ($blockName in $blockPaths.Keys) {
        $null = Invoke-CheckedTool -ToolName 'ExportBlock' -Phase 'main-export' -Arguments @{
            softwarePath = $SoftwarePath
            blockPath = $blockPaths[$blockName]
            exportPath = $BlockExportDir
        } -TimeoutSec 180 -AllowFailure
    }

    $null = Invoke-CheckedTool -ToolName 'ExportBlocks' -Phase 'main-export' -Arguments @{
        softwarePath = $SoftwarePath
        exportPath = $BlockExportDir
        regexName = '^(DB_SimControl|DB_ProcessData|DB_Alarms|DB_Recipe|FB_ModeManager|FB_Conveyor|FB_FillStation|FB_PlantSimulator|FB_AlarmManager|FC_IOMap|FC_ResetCounters|OB1)$'
        preservePath = $true
    } -TimeoutSec $BuildTimeoutSec -SuccessEvaluator {
        param($resp)
        if (-not (Test-ToolSuccess $resp)) { return $false }
        return @(Get-ChildItem -LiteralPath $BlockExportDir -Filter '*.xml' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 }).Count -ge 8
    }

    $null = Invoke-CheckedTool -ToolName 'ExportTypes' -Phase 'main-export' -Arguments @{
        softwarePath = $SoftwarePath
        exportPath = $TypeExportDir
        regexName = '^(UDT_DeviceState|UDT_AlarmState|UDT_Recipe)$'
        preservePath = $true
    } -TimeoutSec $BuildTimeoutSec

    $null = Invoke-CheckedTool -ToolName 'ExportPlcMigrationBundle' -Phase 'main-export' -Arguments @{
        softwarePath = $SoftwarePath
        outputDirectory = $MigrationDir
        blockRegex = '^(DB_SimControl|DB_ProcessData|DB_Alarms|DB_Recipe|FB_ModeManager|FB_Conveyor|FB_FillStation|FB_PlantSimulator|FB_AlarmManager|FC_IOMap|FC_ResetCounters|OB1)$'
        preserveBlockPath = $true
    } -TimeoutSec $BuildTimeoutSec -SuccessEvaluator {
        param($resp)
        if (-not (Test-ToolSuccess $resp)) { return $false }
        return (Test-PathHasNonEmptyFile -Path $MigrationDir)
    }

    Invoke-DocumentGateChecks -AnyBlockPath $blockPaths['DB_ProcessData']

    $null = Invoke-CheckedTool -ToolName 'SaveProject' -Phase 'main' -TimeoutSec 180
    $null = Invoke-CheckedTool -ToolName 'CloseProject' -Phase 'main' -TimeoutSec 180
    $null = Invoke-CheckedTool -ToolName 'OpenProject' -Phase 'main-reopen' -Arguments @{ path = $MainProjectPath } -TimeoutSec 300
    $null = Invoke-CheckedTool -ToolName 'GetSoftwareTree' -Phase 'main-reopen' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
    $null = Invoke-CheckedTool -ToolName 'GetBlocksWithHierarchy' -Phase 'main-reopen' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
    $null = Invoke-CheckedTool -ToolName 'GetTypes' -Phase 'main-reopen' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
    $null = Invoke-CheckedTool -ToolName 'GetPlcTagTables' -Phase 'main-reopen' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180

    if (-not $SkipReplica) {
        $null = Invoke-CheckedTool -ToolName 'CloseProject' -Phase 'replica' -TimeoutSec 180
        $null = Invoke-CheckedTool -ToolName 'CreateProject' -Phase 'replica' -Arguments @{
            directoryPath = $ProjectRoot
            projectName = $ReplicaProjectName
        } -TimeoutSec $ProjectTimeoutSec
        $null = Invoke-CheckedTool -ToolName 'AddDeviceWithFallback' -Phase 'replica' -Arguments @{
            preferredMlfb = $PreferredCpuMlfb
            preferredVersion = $PreferredCpuVersion
            deviceName = $DeviceName
            family = 'S7-1200'
        } -TimeoutSec $ProjectTimeoutSec
        $null = Invoke-CheckedTool -ToolName 'ImportPlcProgramFromDirectory' -Phase 'replica-import' -Arguments @{
            softwarePath = $SoftwarePath
            sourceDir = $MigrationDir
            typeGroupPath = ''
            tagFolderPath = ''
            technologyFolderPath = ''
            blockGroupPath = ''
            regexName = ''
            compileAfter = $true
            stopOnImportFailure = $false
            dryRun = $false
        } -TimeoutSec $BuildTimeoutSec -SuccessEvaluator {
            param($resp)
            if (-not (Test-ToolSuccess $resp)) { return $false }
            return @($resp.ToolResult.failed).Count -eq 0
        }
        $null = Invoke-CheckedTool -ToolName 'CompileAndDiagnosePlc' -Phase 'replica' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec $CompileTimeoutSec -SuccessEvaluator {
            param($resp)
            if (-not (Test-ToolSuccess $resp)) { return $false }
            return [int]$resp.ToolResult.errorCount -eq 0
        }
        $null = Invoke-CheckedTool -ToolName 'GetSoftwareTree' -Phase 'replica-readback' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
        $null = Invoke-CheckedTool -ToolName 'GetBlocks' -Phase 'replica-readback' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
        $null = Invoke-CheckedTool -ToolName 'GetTypes' -Phase 'replica-readback' -Arguments @{ softwarePath = $SoftwarePath } -TimeoutSec 180
        $null = Invoke-CheckedTool -ToolName 'SaveProject' -Phase 'replica' -TimeoutSec 180
    }

    if (-not $KeepProjectOpen) {
        $null = Invoke-CheckedTool -ToolName 'CloseProject' -Phase 'cleanup' -TimeoutSec 180 -AllowFailure
    }

    $guidePath = Join-Path $McpReportsDir 'plcsim-manual-validation.md'
    New-ManualGuide -ProjectPath $MainProjectPath -ReportPath (Join-Path $McpReportsDir 'acceptance-summary.md') |
        Set-Content -LiteralPath $guidePath -Encoding UTF8

    $failed = @($script:Results | Where-Object { $_.status -eq 'failed' })
    $summary = [pscustomobject]@{
        mode = 'full'
        runStamp = $RunStamp
        runRoot = $RunRoot
        mainProjectPath = $MainProjectPath
        replicaProjectPath = $ReplicaProjectPath
        plcsimGuidePath = $guidePath
        toolSurface = $surface
        compile = $compile.ToolResult
        blockPaths = $blockPaths
        typePaths = $typePaths
        expectedObjects = $Names
        exportsDir = $McpExportsDir
        logsDir = $McpLogsDir
        reportDir = $McpReportsDir
        results = $script:Results
        stats = [pscustomobject]@{
            success = @($script:Results | Where-Object { $_.status -eq 'success' }).Count
            gated = @($script:Results | Where-Object { $_.status -eq 'gated' }).Count
            failed = $failed.Count
        }
    }
    $summaryPath = Join-Path $McpReportsDir 'acceptance-summary.json'
    $summary | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    New-AcceptanceReport -Summary $summary | Set-Content -LiteralPath (Join-Path $McpReportsDir 'acceptance-summary.md') -Encoding UTF8

    if ($failed.Count -gt 0) {
        throw "MCP_CellLine_Sim_V17 验证存在失败项：$($failed.step -join ', ')。summary=$summaryPath"
    }

    Write-Host "acceptance summary: $summaryPath"
    Write-Host "PLCSIM guide: $guidePath"
    Write-Host "project path: $MainProjectPath"
}
catch {
    $guidePath = Join-Path $McpReportsDir 'plcsim-manual-validation.md'
    if (-not (Test-Path -LiteralPath $guidePath)) {
        New-ManualGuide -ProjectPath $MainProjectPath -ReportPath (Join-Path $McpReportsDir 'acceptance-summary.md') |
            Set-Content -LiteralPath $guidePath -Encoding UTF8
    }
    $failedSummary = [pscustomobject]@{
        mode = 'failed'
        runStamp = $RunStamp
        runRoot = $RunRoot
        mainProjectPath = $MainProjectPath
        error = $_.Exception.Message
        results = $script:Results
        logsDir = $McpLogsDir
        reportDir = $McpReportsDir
        plcsimGuidePath = $guidePath
    }
    $summaryPath = Join-Path $McpReportsDir 'acceptance-summary.json'
    $failedSummary | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    New-AcceptanceReport -Summary $failedSummary | Set-Content -LiteralPath (Join-Path $McpReportsDir 'acceptance-summary.md') -Encoding UTF8
    throw
}
