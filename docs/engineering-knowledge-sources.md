# 工程高质量信息源清单

这份清单整理适合工程设计、实现参考、bug 修复与 RAG 入库的高质量信息源。

这些源的共同特点是信噪比较高、结构相对稳定、适合被 agent 作为源头材料检索。后续可基于本清单建设 `engineering-source-router` skill，或作为工程知识库的入库目录。

## 分组清单

| 领域 | 信息源 | 适合用途 | 建议用法 |
| --- | --- | --- | --- |
| 语言/编译器设计 | Go proposals、Rust RFC / rustc dev guide、Python PEPs | 理解语言特性、编译器行为、语义权衡、演进背景 | 查询语言设计问题时优先检索，重点保留设计动机、弃选方案、兼容性讨论 |
| 大型系统设计 | Kubernetes KEPs、Chromium design docs、Linux kernel docs | 学习大型系统架构、模块边界、性能约束、稳定性策略 | 查询系统架构和工程取舍时优先检索，关注 proposal、design doc、实现约束 |
| 数据库大师课 | SQLite Architecture、How SQLite Works、PostgreSQL Developer FAQ、TigerBeetle docs | 学习数据库内核、事务、存储、复制、一致性与可靠性设计 | 查询数据库实现和高可靠系统时优先检索，关注核心算法、故障模型、测试策略 |
| 编译器/底层工程 | LLVM docs、Architecture of Open Source Applications | 学习编译器架构、优化管线、底层工程组织和开源系统拆解 | 查询编译器、运行时、底层工具链问题时优先检索，关注架构分层和实现模式 |
| 分布式/可靠性 | AWS Builders' Library、Google SRE books | 学习分布式系统、容量规划、容错、可观测性、事故处理和可靠性文化 | 查询可用性、扩展性、故障恢复问题时优先检索，关注真实约束和运维经验 |
| Web/标准 | IETF RFC / Datatracker、WHATWG HTML、TC39 proposals、MDN content | 查询网络协议、Web 标准、JavaScript 提案、浏览器行为和 API 细节 | 查询标准兼容性和 Web API 行为时优先检索，先看标准再看 MDN 实用说明 |
| 真实 bug | SWE-bench、Defects4J、BugsJS、ManyBugs | 学习真实缺陷、回归测试、修复路径、bug 模式和自动修复基准 | 查询 bug 修复策略时优先检索，关注失败用例、补丁、根因和回归测试 |

## 路由规则

- 遇到语言特性、编译器行为、语法语义、兼容性问题时，优先查 `Go proposals`、`Rust RFC / rustc dev guide`、`Python PEPs`。
- 遇到大型系统架构、控制面设计、浏览器架构、内核机制问题时，优先查 `Kubernetes KEPs`、`Chromium design docs`、`Linux kernel docs`。
- 遇到数据库、事务、存储引擎、复制、一致性和高可靠数据系统问题时，优先查 `SQLite Architecture`、`How SQLite Works`、`PostgreSQL Developer FAQ`、`TigerBeetle docs`。
- 遇到编译器、运行时、优化管线、底层工具链和大型开源系统拆解问题时，优先查 `LLVM docs`、`Architecture of Open Source Applications`。
- 遇到分布式系统、可靠性、容量规划、降级、容灾、事故复盘问题时，优先查 `AWS Builders' Library`、`Google SRE books`。
- 遇到协议、浏览器行为、Web API、JavaScript 提案、标准兼容性问题时，优先查 `IETF RFC / Datatracker`、`WHATWG HTML`、`TC39 proposals`、`MDN content`。
- 遇到真实 bug、回归测试、补丁模式、自动修复和缺陷定位问题时，优先查 `SWE-bench`、`Defects4J`、`BugsJS`、`ManyBugs`。

## RAG 入库建议

- 优先保留设计背景：问题是什么，约束是什么，为什么需要这个设计。
- 优先保留决策理由：选择了什么方案，放弃了什么方案，主要权衡是什么。
- 优先保留实现链路：设计文档、对应源码、关键接口、核心算法和边界条件。
- 优先保留工程证据：Issue、PR、commit、测试用例、benchmark、回归修复记录。
- 优先保留 bug 轨迹：失败现象、复现方式、根因分析、补丁 diff、回归测试。
- 对重要结论保留出处信息，避免只入库二手总结。

## 推荐知识库结构

```text
engineering-knowledge/
  language-compiler-design/
  large-system-design/
  database-engineering/
  compiler-low-level-engineering/
  distributed-reliability/
  web-standards/
  real-bug-cases/
```

每个主题库建议按“设计文档 -> 源码实现 -> Issue/PR -> 测试 -> 后续 bugfix”的链路组织。这样 agent 在遇到工程问题时，可以先检索设计约束，再参考真实实现，最后对照历史 bug 和回归测试。
