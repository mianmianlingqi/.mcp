using ModelContextProtocol.Server;
using System.ComponentModel;

namespace TiaMcpServer.ModelContextProtocol
{
    [McpServerToolType]
    public static class PlcSoftwareV17Phase2McpTools
    {
        [McpServerTool(Name = "CreateTechnologyObject"), Description("[L2][PLC-Software][Phase2-Beta] 创建 PLC Technology Object。V17 二期优先验证 1211C + PID_Compact。")]
        public static ResponseMessage CreateTechnologyObject(
            [Description("PLC softwarePath，例如 PLC_1。")] string softwarePath,
            [Description("TO 名称，例如 PID_Compact_MCP_001。")] string name,
            [Description("系统库元素，例如 PID_Compact。")] string systemLibElement,
            [Description("库版本，例如 2.3。")] string libVersion)
            => McpServer.CreateTechnologyObject(softwarePath, name, systemLibElement, libVersion);

        [McpServerTool(Name = "ExportTechnologyObjectsToDirectory"), Description("[L2][PLC-Software][Phase2-Beta] 批量导出 Technology Object XML 到目录。")]
        public static ResponseImportBatch ExportTechnologyObjectsToDirectory(
            [Description("PLC softwarePath，例如 PLC_1。")] string softwarePath,
            [Description("导出目录。")] string exportDir,
            [Description("TO 名称正则过滤，空字符串表示全部。")] string regexName = "")
            => McpServer.ExportTechnologyObjectsToDirectory(softwarePath, exportDir, regexName);

        [McpServerTool(Name = "EnsurePlcWatchTableEntry"), Description("[L2][PLC-Software][Phase2-Beta] 离线创建或确保 PLC 监控表地址条目。只改工程对象，不设置 ModifyValue/ForceValue，不在线写 PLC。")]
        public static ResponseMessage EnsurePlcWatchTableEntry(
            [Description("PLC softwarePath，例如 PLC_1。")] string softwarePath,
            [Description("监控表名称。")] string tableName,
            [Description("监控地址或符号变量，例如 %M10.0。")] string address)
            => McpServer.EnsurePlcWatchTableEntry(softwarePath, tableName, address);
    }
}
