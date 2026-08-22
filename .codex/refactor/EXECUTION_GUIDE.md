# SlateSync 双模型重构执行手册

Authority status: **CURRENT**. Execute only
`packages/IP-03-08-CONTINUOUS.md` version `2026-08-21.2`; all older package
instructions are historical unless the current package explicitly incorporates
them. See `README.md` and `CURRENT_STATE.json`.

## 1. 基本原则

使用同一个仓库和同一个重构分支。IP-01/02 保留基础批次；Gate 01-02 通过后，后续重构改为一个连续 Luna 任务和一次 Sol Final Review：

```text
Sol High：批准 IP-01/02 基础批次
  ↓
Luna XHigh：完成 IP-01/02
  ↓
Sol High：Joint Gate 01-02
  ↓
Luna XHigh：一次执行 IP-03-08-CONTINUOUS
  ↓
模块 checkpoint/testing（不等待、不切模型）
  ↓
完整测试/构建/性能/迁移/视觉/清理验证
  ↓
Sol High：Final Review
  ↓
APPROVED / CHANGES REQUIRED
```

不要让两个模型同时修改同一工作区。IP-03～IP-08 的旧 Allowed Scope、Protected Scope、Gate 和停止等待不再分别生效；其有效技术要求已合并进统一包。统一包的全局 Protected Scope、Stop Conditions、证据和最终验收仍完整生效。

本地 Gate 只要求无签名目录构建：

```bash
CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir
```

Apple Development 签名、notarization 和发布凭据当前跳过；不得为了跳过而修改签名、entitlements 或发布配置。只有 Owner 明确启动发布准备审核时，签名才重新成为验收项。

视觉证据在现代 UI 完整集成后统一建立/验证，不阻塞前置架构工作；缺少真实、稳定、完整的视觉证据会阻止 Continuous Completion Report 进入 Final Review。

数据库驱动在连续包内保持 `better-sqlite3`。系统 Node 与 Electron 是两个
原生运行时，ABI 准备由 npm 生命周期自动完成；`npm run test:native:abi`
必须验证 Electron 加载、`finally` 恢复以及随后 Node 加载。不要手动复制
`.node` 文件，也不要把 ABI 数字解释为已经移除的 Web 服务。数据库替换只
能在 Final Review 之后按 `ADR-DATABASE-RUNTIME-ABI.md` 的独立验证 Gate 进行。

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
│   ├── IP-0102.md
│   ├── IP-03-08-CONTINUOUS.md
│   └── IP-01——IP-08.md  # historical requirement provenance
└── reviews/
    ├── GATE-00.md
    ├── GATE-01-02.md
    └── FINAL-IP-03-08.md
```

`MASTER_PLAN.md` 是战略；`packages/IP-0102.md` 是已经完成并审核的历史基础
施工图。Gate 01-02 之后只有 `packages/IP-03-08-CONTINUOUS.md` 版本
`2026-08-21.2` 授权后续施工，旧汇总文件只作历史参考。

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

Gate 00 后使用已批准的 `IP-0102.md`。Gate 01-02 通过后不再生成 IP-03～IP-08 的独立包或批次；Luna 直接执行统一连续包，并在结束后交给 Sol Final Review。

## 5. Luna：执行 IP-03-08 Continuous Package

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
- .codex/refactor/COMPATIBILITY_CONTRACT.md
- .codex/refactor/DECISION_QUEUE.md
- .codex/refactor/reviews/GATE-01-02.md
- .codex/refactor/packages/IP-03-08-CONTINUOUS.md

确认 Continuous Admission Conditions 后，一次性连续执行统一包。旧 IP 编号只是需求溯源，不是施工边界。

首先运行 `node .codex/refactor/verify-current-state.mjs`，确认当前 Gate、
活动包版本/SHA、历史包非执行状态和必需章节一致；失败时不得自行选择另一份
施工包。

执行规则：
1. 只能修改统一包的 Allowed Scope，不得修改全局 Protected Scope。
2. 允许后续集成回访前序模块，但必须记录原因、diff 和重新验证结果。
3. 不得自行改变跨模块接口、数据格式或架构边界。
4. 遇到 Stop Condition 时，将问题写入
   `.codex/refactor/DECISION_QUEUE.md`。只有真正的架构、兼容、数据安全、迁移、所有权或无法包内安全修复的问题才停止连续施工。
5. 修改代码后添加或更新必要注释，并删除失效注释。
6. 每个工作流完成后运行 focused checkpoint，保存 diff 与证据。Checkpoint 不触发模型切换或等待；原因明确的包内缺陷修复后重跑。
7. 不得通过删除、跳过或放宽测试获得通过。
8. UI 完整集成后统一生成视觉基线；清理前生成路径/符号精确的 `CONTINUOUS_CLEANUP_MANIFEST.md`，只删除清单项目。
9. 完成全部最终验证后输出统一包定义的 Continuous Completion Report。
10. 不执行 git commit、stage、push、branch switch 或 worktree clean；停止并等待 Sol Final Review。
```

完成报告使用 `IP-03-08-CONTINUOUS.md` 中的格式，必须包含每个工作流 checkpoint、完整文件清单、注释、测试、性能、视觉、迁移、数据安全、兼容和 Cleanup Manifest 证据。

IP-01/02 仍使用 `IP-0102.md` 自己的 Batch Completion Report；不要将本节规则追溯用于绕过当前阻塞或 Gate 01-02。

历史的单 IP 报告格式仅作旧记录参考：

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

旧多 IP Batch 报告尾部格式：

```text
BATCH: IP-XX + IP-YY
BATCH STATUS: READY FOR JOINT REVIEW | PARTIAL | BLOCKED
START SNAPSHOT:
- git status / baseline identifier
CUMULATIVE VALIDATION:
- command / result
NEXT BATCH ENTERED: NO
```

## 6. Sol：执行 Final Review

切回 Sol High，使用：

```text
你是 SlateSync 重构的 Architect / Reviewer。

请审核 SlateSync IP-03-08 Continuous Final Review。

必须读取：
- .codex/refactor/MASTER_PLAN.md
- .codex/refactor/ARCHITECTURE_INVARIANTS.md
- .codex/refactor/COMPATIBILITY_CONTRACT.md
- .codex/refactor/packages/IP-03-08-CONTINUOUS.md
- .codex/refactor/DECISION_QUEUE.md（如果存在）
- 当前 git status
- 相对 GATE-01-02 批准基线的完整 diff
- Luna 的 Continuous Completion Report、checkpoint ledger、测试、截图、性能、迁移和 Cleanup Manifest 证据

要求：
1. 审核完整累计 diff 和实际最终代码，不根据完成报告直接判断。
2. 检查统一 Allowed Scope、Protected Scope、Stop Conditions、Cleanup Manifest 及每项删除证据。
3. 逐项验证 Architecture Invariants。
4. 检查测试是否有效，禁止通过放宽测试掩盖回归。
5. 检查代码修改涉及的注释是否已同步更新。
6. 检查兼容、迁移/数据安全、视觉/可访问性、性能/内存、E2E、打包和回退路径。
7. 将结果写入 `.codex/refactor/reviews/FINAL-IP-03-08.md`。

只能输出：
- APPROVED
- CHANGES REQUIRED

如果 CHANGES REQUIRED：
- 生成边界明确的 Correction Package。
- 不直接实施修复。
- 不批准下一阶段。

如果 APPROVED：解决 Decision Queue，更新必要 ADR/兼容文档，并明确整个后 IP-02 重构完成。
```

Review 文件格式：

```text
REVIEW: FINAL-IP-03-08
VERDICT: APPROVED | CHANGES REQUIRED

BLOCKERS:
MAJOR:
MINOR:
OPTIONAL:

INVARIANT VIOLATIONS:
DECISION QUEUE RESOLUTIONS:
ACCEPTED TECHNICAL DEBT:
ADR UPDATES:
CLEANUP MANIFEST ASSESSMENT:
MIGRATION / DATA SAFETY:
FINAL DISPOSITION:
```

## 7. Correction Package

Final Review 不通过时，不要让 Luna“根据 review 自由修复”。Sol 必须生成边界明确的连续修正包：

```text
.codex/refactor/packages/IP-03-08-CONTINUOUS-C01.md
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
只执行 FINAL-IP-03-08 明确授权的 Correction Package。
不得处理包外建议。完成全部必要验证并输出修正报告后停止，等待 Final Review 重新审核。
```

同一 Final Review 可以循环多次：

```text
IP-03-08-CONTINUOUS
→ FINAL-IP-03-08
→ IP-03-08-CONTINUOUS-C01
→ FINAL-IP-03-08
→ IP-03-08-CONTINUOUS-C02（如需要）
→ FINAL-IP-03-08
→ APPROVED
```

## 8. 批次提交

IP-01/02 仍按其 Joint Gate 形成基础批次提交。连续包仅在 Final Review APPROVED 后形成一个后续重构提交，例如：

```text
refactor(ip-00): freeze migration baseline
refactor(ip-01-02): add build skeleton and typed preload contracts
refactor(ip-03-08): complete continuous architecture and UI migration
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

现行审核边界：

```text
IP-01 + IP-02       → GATE-01-02
IP-03 through IP-08 → FINAL-IP-03-08（无中间 Gate）
```

Final Review 必须覆盖旧 Gate 03～08 的全部有效检查项。取消的是独立授权、模型切换和等待，不是验收内容、架构/兼容约束、清理证据或 Stop Conditions。

## 10. 开始方式

`GATE-01-02` 已于 2026-08-21 输出 `APPROVED`，无 Correction Package。
现在直接把 `IP-03-08-CONTINUOUS.md` 交给 Luna XHigh 一次性连续施工；
历史 IP 编号只用于 checkpoint/evidence 溯源，不要求模型切换或等待。
Luna 完成全部工作流、全量验证和统一报告后，再切换 Sol High 做唯一
Final Review。
