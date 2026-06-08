# SCL V17 外部导入说明

TIA Portal V17 对 `SW.Blocks.FC` / `SW.Blocks.FB` 的 SimaticML XML 更严格。

一期工程约定：

- FC/FB 不再把 `StructuredText/v4` 或 `FlgNet/v5` 块 XML 作为主写入路径。
- FC/FB 固定使用外部 SCL 文件导入。
- 写入链路为 `PlcBuildAndImport(kind=fc/fb, dryRun=false)`。
- 内部实际执行 `ImportPlcExternalSource` 后再执行 `GenerateBlocksFromExternalSource`。

推荐流程：

1. 先调用 `PlcBuildAndImport(..., dryRun=true)` 生成 SCL 草稿和导入计划。
2. 检查 `writtenFiles` 中的 `.scl`。
3. 确认后调用 `PlcBuildAndImport(..., dryRun=false, compileAfter=true)`。
4. 调用 `CompileAndDiagnosePlc` 验证无错误。
5. 调用 `SaveProject` 显式保存工程。

GlobalDB、UDT、TagTable 仍使用 XML 导入路径。

外部 SCL 适合 V17，因为它绕开了块 XML 中 `Namespace`、`StructuredText` 版本和编译单元属性差异导致的导入失败。
