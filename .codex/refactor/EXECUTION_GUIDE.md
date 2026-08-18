# SlateSync 双模型重构执行手册

## 1. 基本原则

使用同一个仓库、同一个重构分支和同一个 Codex 任务，按阶段切换模型：

```text
Sol High：生成施工包
  ↓
Luna XHigh：限定范围实现
  ↓
Sol High：审核实际 diff
  ↓
Correction Package 或 APPROVED
  ↓
阶段提交
  ↓
下一施工包
```

不要让两个模型同时修改同一工作区。不要把全部重构阶段一次性交给 Luna。

## 2. 首次准备

1. 检查 `git status` 和当前 diff。
2. 验证迁移开始前的全部测试。
3. 将已有功能修改形成独立 commit 或可恢复 checkpoint。
4. 创建重构分支，例如 `codex/react-architecture-refactor`。
5. 由 Sol High 生成 `IP-00`。

禁止通过 `git reset --hard`、覆盖文件或清理未跟踪文件获得干净工作区。

## 3. 目录约定

```text
.codex/refactor/
├── MASTER_PLAN.md
├── ARCHITECTURE_INVARIANTS.md
├── EXECUTION_GUIDE.md
├── COMPATIBILITY_CONTRACT.md
├── MIGRATION_MATRIX.md
├── DECISION_QUEUE.md
├── packages/
│   ├── IP-00.md
│   ├── IP-00-C01.md
│   ├── IP-01.md
│   └── ...
└── reviews/
    ├── GATE-00.md
    ├── GATE-01.md
    └── ...
```

`MASTER_PLAN.md` 是战略，`packages/IP-XX.md` 是当前施工图。

## 4. Sol：生成 Implementation Package

模型配置：

```text
Model: GPT-5.6 Sol
Reasoning: High
```

首个提示词：

```text
你是 SlateSync 重构的 Architect / Reviewer。

请读取：
- AGENTS.md
- .codex/refactor/MASTER_PLAN.md
- .codex/refactor/ARCHITECTURE_INVARIANTS.md
- package.json
- 当前 git status 和 git diff
- 现有测试、Electron 入口、preload、renderer、SQLite、Project Library、
  recognition 和 CSV Worker 实现

本次只生成 Implementation Package IP-00：Baseline Freeze。

要求：
1. 不修改生产业务行为。
2. 识别当前工作区已有修改，禁止覆盖或清理用户改动。
3. 记录现有兼容边界、测试基线、持久化格式、环境变量和构建输入。
4. 明确 Objective、Allowed Scope、Protected Scope、Required Changes、
   Existing Behavior That Must Remain、Acceptance Tests、Performance Constraints、
   Stop Conditions 和 Deliverables。
5. 将施工包写入 .codex/refactor/packages/IP-00.md。
6. 不执行 IP-00。
7. 最后说明是否可以交给 Luna XHigh。
```

后续阶段将 `IP-00` 替换为已批准的下一阶段编号，并要求 Sol 根据当前实际代码生成，不得直接复制旧计划。

## 5. Luna：执行当前 Package

模型配置：

```text
Model: GPT-5.6 Luna
Reasoning: XHigh
```

提示词模板：

```text
你是 SlateSync 重构的 Implementer。

请读取：
- AGENTS.md
- .codex/refactor/MASTER_PLAN.md
- .codex/refactor/ARCHITECTURE_INVARIANTS.md
- .codex/refactor/packages/IP-XX.md

只执行 IP-XX，不得提前进入下一 Package。

执行规则：
1. 只能修改 Allowed Scope。
2. 不得修改 Protected Scope。
3. 不得自行改变跨模块接口、数据格式或架构边界。
4. 遇到 Stop Condition 时，将问题写入
   .codex/refactor/DECISION_QUEUE.md；停止受影响子任务，但继续其他独立任务。
5. 修改代码后添加或更新必要注释，并删除失效注释。
6. 运行 Package 定义的全部测试和验证命令。
7. 不得通过删除、跳过或放宽测试获得通过。
8. 完成后输出标准 Completion Report。
9. 不执行 git commit，不进入下一 Package。
```

完成报告格式：

```text
PACKAGE: IP-XX
STATUS: COMPLETED | PARTIAL | BLOCKED

IMPLEMENTED:
- ...

CHANGED FILES:
- ...

COMMENTS UPDATED:
- ...

TESTS ADDED OR UPDATED:
- ...

VALIDATION:
- command
- result

COMPATIBILITY:
- preserved behavior

DECISION QUEUE:
- NONE | entries

ARCHITECTURE DEVIATIONS:
- NONE | entries

KNOWN LIMITATIONS:
- NONE | entries
```

## 6. Sol：执行 Review Gate

切回 Sol High，使用：

```text
你是 SlateSync 重构的 Architect / Reviewer。

请审核 Gate XX。

必须读取：
- .codex/refactor/MASTER_PLAN.md
- .codex/refactor/ARCHITECTURE_INVARIANTS.md
- .codex/refactor/packages/IP-XX.md
- .codex/refactor/DECISION_QUEUE.md（如果存在）
- 当前 git status
- 相对 Package 开始状态的完整 diff
- Luna 的测试、截图和性能证据

要求：
1. 审核实际实现，不根据完成报告直接判断。
2. 检查 Allowed Scope 和 Protected Scope。
3. 逐项验证 Architecture Invariants。
4. 检查测试是否有效，禁止通过放宽测试掩盖回归。
5. 检查代码修改涉及的注释是否已同步更新。
6. 将结果写入 .codex/refactor/reviews/GATE-XX.md。

只能输出：
- APPROVED
- CHANGES REQUIRED

如果 CHANGES REQUIRED：
- 生成边界明确的 Correction Package。
- 不直接实施修复。
- 不批准下一阶段。

如果 APPROVED：
- 解决 Decision Queue。
- 更新必要 ADR 或兼容文档。
- 生成下一 Implementation Package。
- 不实施下一 Package。
```

Review 文件格式：

```text
GATE:
VERDICT: APPROVED | CHANGES REQUIRED

BLOCKERS:
MAJOR:
MINOR:
OPTIONAL:

INVARIANT VIOLATIONS:
DECISION QUEUE RESOLUTIONS:
ACCEPTED TECHNICAL DEBT:
ADR UPDATES:
NEXT PACKAGE AUTHORIZATION:
```

## 7. Correction Package

审核不通过时，不要让 Luna“根据 review 自由修复”。Sol 必须生成：

```text
.codex/refactor/packages/IP-XX-C01.md
```

内容必须包括：

```text
Exact issue
Expected architecture
Allowed files
Protected files
Required change
Forbidden workaround
Acceptance test
```

Luna 提示词：

```text
只执行 .codex/refactor/packages/IP-XX-C01.md。
不得处理其他 review 建议，不得进入下一阶段。
完成全部验证并输出 Completion Report 后停止，等待 Gate XX 重新审核。
```

同一 Gate 可以循环多次：

```text
IP-XX
→ Gate XX
→ IP-XX-C01
→ Gate XX
→ IP-XX-C02
→ Gate XX
→ APPROVED
```

## 8. 阶段提交

仅在 Gate APPROVED 后形成阶段提交，例如：

```text
refactor(ip-00): freeze migration baseline
refactor(ip-01): add typescript build skeleton
refactor(ip-02): introduce typed preload contracts
```

提交前至少检查：

```text
git status
git diff
npm test
npm run check
```

引入 TypeScript 和新测试设施后追加：

```text
npm run typecheck
npm run test:component
npm run test:e2e
```

实际命令以对应 Package 和 `package.json` 为准。

## 9. 推荐执行顺序

```text
IP-00  Baseline Freeze
IP-01  TypeScript + Vite Skeleton
IP-02  Shared Contracts + Typed Preload
IP-03  Design System Foundations
IP-04  Project Library / Settings
IP-05A Slate Input / PDF Preparation
IP-05B Recognition Workflow
IP-05C Metadata / Tasks
IP-06A Typed CSV Worker
IP-06B Virtual Table
IP-06C Editing / Export
IP-07  Integration / E2E
IP-08  Cleanup
```

IP-02、IP-03、IP-05B、IP-06A、IP-06B 和 IP-07 必须执行完整 Sol Review，不得合并 Gate。

## 10. 开始方式

首次执行时不要直接开始 React 重构。先使用 Sol High 运行本文件第 4 节提示词，生成并落盘 `IP-00`；确认 Package 边界后，再切换 Luna XHigh 实施。
