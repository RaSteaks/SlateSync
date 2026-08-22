# SlateSync 双模型架构与 UI Design System 重构总方案

Authority status: **CURRENT**. The only executable downstream package is
`packages/IP-03-08-CONTINUOUS.md` version `2026-08-21.2`; see `README.md` and
`CURRENT_STATE.json` before using historical IP sections.

## 1. 目标

在不破坏现有识别、CSV、SQLite、Project Library 和任务持久化行为的前提下，将 SlateSync 重构为：

- Electron Main / Preload / Renderer 清晰分层
- React + TypeScript strict 的 Feature 模块化 Renderer
- 按领域划分的 Zustand 状态
- Typed IPC 和统一错误模型
- Worker 承担 CPU-heavy 数据处理
- Apple 精致感与专业影视工具信息密度结合的 Design System
- 可通过单元、组件、E2E、性能和视觉测试验证的渐进式迁移

本计划采用双模型执行：

- **GPT-5.6 Sol High**：Architect / Reviewer
- **GPT-5.6 Luna XHigh**：Implementer

当前状态（2026-08-21）：`GATE-01-02` 已由 Sol High 复审为
`APPROVED`，Shared Contract v1 和唯一 `window.slateSync` 边界已冻结。
`packages/IP-03-08-CONTINUOUS.md` 现已授权，可由 Luna XHigh 在单一任务
中连续完成，结束后才切换给 Sol High 做一次联合 Final Review。

IP-01 与 IP-02 已作为基础设施批次完成并通过 `GATE-01-02` 联合审核。
原 IP-03～IP-08 的独立施工边界现已全部取消，由 Luna 在一个任务中执行
统一施工包 `packages/IP-03-08-CONTINUOUS.md`，最后由 Sol 对完整累计 diff
和全部证据做一次 Final Review。

现行施工边界：

```text
Batch 01-02                  IP-01 + IP-02 → Joint Gate 01-02
Continuous Implementation   旧 IP-03～IP-08 全部需求 → Sol Final Review
```

连续施工仍按 Design System、低风险页面、Slate、Recognition、Metadata/Tasks、CSV Worker、Virtual Table/Export、集成切换、清理的依赖顺序推进。模块 checkpoint/testing 用于记录证据和尽早定位问题，但不是授权边界，也不要求切换模型或等待 Sol。Luna 可以在统一 Allowed Scope 内回访前序模块并修复集成问题。

只有真正涉及架构不变量、兼容契约、Shared Contract、数据安全、持久化/迁移、所有权、未授权依赖或无法在包内安全修复的失败才触发 Stop Condition。普通的、原因明确且可在包内修复的 checkpoint 失败应修复并重跑，而不是创建中间 Gate。

旧 `packages/IP-01——IP-08.md` 中 IP-03～IP-08 的内容仅保留为历史需求来源；其中的独立 Allowed/Protected Scope、阶段前置条件、Gate、临时冻结和停止等待表述不再授权施工。唯一后续施工图是 `packages/IP-03-08-CONTINUOUS.md`。

数据库在本轮保持 Main-owned `better-sqlite3` 和全部既有 SQLite 格式。
Node/Electron ABI 差异由命名生命周期及 CI 自动验证，不通过更换数据库、
恢复 Web 服务或引入双驱动抽象解决。`node:sqlite` 只作为重构完成后的独立
兼容性/性能验证候选，详见 `adr/ADR-DATABASE-RUNTIME-ABI.md`。

当前重构 Gate 的本地打包验收使用无签名目录构建：`CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir`。Apple Development 签名、notarization 和发布凭据不属于当前重构 Gate 的通过条件；现有签名/发布配置仍是 Protected Scope，除非 Owner 另行启动发布准备审核。

视觉基线改为在现代 UI 完整集成后统一建立和验证。缺失视觉证据不阻塞连续包中的前置非 UI 架构施工，但完整、真实、稳定的视觉/可访问性证据是 Continuous Completion Report 和 Sol Final Review 的必备条件。

## 2. 目标架构

```text
Electron
├── Main
│   ├── app / windows
│   ├── IPC handlers
│   ├── filesystem / dialogs
│   ├── SQLite / Project Library
│   ├── recognition orchestration
│   └── provider configuration / secrets
│
├── Preload
│   └── typed window.slateSync gateway
│
├── Shared
│   ├── contracts
│   ├── domain types
│   ├── errors
│   └── schemas
│
└── Renderer
    ├── React + TypeScript strict
    ├── Feature modules
    ├── Zustand domain slices
    ├── Design System
    ├── TanStack Table / Virtual
    └── typed Web Workers
```

技术基线：

- Electron + Vite
- React + TypeScript strict
- Zustand
- CSS Modules
- TanStack Table + TanStack Virtual
- Lucide 图标
- Vitest + React Testing Library
- Storybook
- Playwright Electron E2E

具体边界见 [ARCHITECTURE_INVARIANTS.md](./ARCHITECTURE_INVARIANTS.md)。

## 3. UI Design System

视觉方向：

```text
Apple 精致感
+
影视后期工具的信息密度
+
克制的深色工业质感
```

### 3.1 Foundations

- 石墨灰语义色阶
- 蓝到靛蓝的低饱和强调渐变
- `6 / 8 / 12 / 16 / 20px` 层级圆角
- 嵌套 Surface 使用同心圆角关系
- 表面允许极弱亮度渐变，但禁止明显装饰性渐变
- `120 / 180 / 240ms` 动效等级
- 支持 `prefers-reduced-motion`
- light/dark 共享语义 token

### 3.2 组件层级

```text
foundations
  ↓
primitives
  ↓
controls / feedback / overlays
  ↓
layout
  ↓
feature components
```

必须建立：

- Primitive：Surface、Stack、Text、Icon、Separator
- Control：Button、IconButton、Input、Textarea、Select、Checkbox、SegmentedControl
- Feedback：Badge、StatusIndicator、Spinner、Progress、Toast、InlineError、EmptyState
- Overlay：Dialog、Popover、Tooltip、ContextMenu
- Layout：AppShell、Sidebar、Toolbar、Panel、SplitPane

Feature 不得自行创建基础控件、品牌色、圆角等级、阴影体系或任意渐变。

Design System API 必须保持业务无关：

```tsx
<Button loading />
```

禁止将业务状态放进基础组件：

```tsx
<Button recognitionRunning />
```

## 4. Architecture Decision Boundary

### 4.1 Luna 可以自行决定

- 文件内部函数拆分
- 私有 helper 和局部命名
- 测试 fixture 组织
- CSS Module class 名
- 不改变 public API 的局部重构
- 不改变行为的类型收窄
- 单组件内部 memoization
- 当前 Package 范围内的测试实现方式

### 4.2 必须进入 Decision Queue

- 新增 runtime dependency
- 修改 shared contract 或 IPC public API
- 修改 Zustand 状态归属
- 修改 SQLite schema 或持久化格式
- 修改 Project Library 或 CSV 输出语义
- 修改识别超时、重试、并发、取消或 provider 调度规则
- 改变 Main / Preload / Renderer / Worker ownership
- 新建全局 abstraction 或 compatibility layer
- 删除 legacy 实现
- 出现方案未定义的跨 Feature 依赖
- 放宽、删除或跳过测试
- 无法达到既定性能指标

Decision Queue 条目格式：

```text
Decision ID:
Context:
Observed conflict:
Current contract:
Option A:
Option B:
Recommendation:
Affected modules:
Blocking: yes/no
```

不阻塞的问题继续完成 Package 的其他独立任务；阻塞时只停止受影响子任务。

## 5. Implementation Package 标准

每个 Package 必须包含：

```text
Objective
Allowed Scope
Protected Scope
Required Changes
Existing Behavior That Must Remain
Public Interfaces
Acceptance Tests
Performance Constraints
Stop Conditions
Deliverables
```

Luna 完成后必须输出：

```text
PACKAGE:
STATUS:

IMPLEMENTED:
CHANGED FILES:
COMMENTS UPDATED:
TESTS ADDED OR UPDATED:
VALIDATION:
COMPATIBILITY:
DECISION QUEUE:
ARCHITECTURE DEVIATIONS:
KNOWN LIMITATIONS:
```

`ARCHITECTURE DEVIATIONS` 默认必须为 `NONE`。

## 6. 分阶段执行

### IP-00：Baseline Freeze

目标：建立迁移前的可验证安全基线，不改变生产行为。

Luna 实现：

- 固化当前测试基线
- 固化 recognition、CSV 和任务持久化 fixtures
- 记录 SQLite schema、Project Library 格式和环境变量
- 记录 electron-builder 输入和关键页面视觉基线
- 识别并保护迁移开始前已有的未提交修改

保护范围：

- recognition algorithm
- timeout / retry / cancellation semantics
- CSV algorithm
- persistence format
- Electron runtime behavior

Gate 00：Sol 检查兼容边界、测试有效性和 dirty working tree 保护。

### IP-01：TypeScript、Vite 与目录骨架

目标：引入新的编译和目录结构，但不迁移业务逻辑。

Luna 实现：

- `src/main`
- `src/preload`
- `src/shared`
- `src/renderer`
- TypeScript strict
- Renderer Vite build
- Main NodeNext build
- Preload 独立构建
- 开发、测试和打包命令
- legacy renderer fallback

禁止迁移 recognition、修改 IPC 行为、修改持久化格式或删除 legacy renderer。

Local Checkpoint 01：Luna 审核 ESM/CJS、构建产物、Electron entrypoint 和 fallback，保留证据后在同一批次继续 IP-02；不在这里切换模型或批准阶段。

### IP-02：Shared Contracts 与 Typed Preload

目标：收敛现有 IPC，不改变业务行为。

目标命名空间：

```text
window.slateSync.app
window.slateSync.projects
window.slateSync.tasks
window.slateSync.recognition
window.slateSync.files
window.slateSync.settings
```

必须保留：

- 现有单页超时语义
- timeout retry
- AbortError 兼容
- `MODEL_REQUEST_MAX_RETRIES`
- `MODEL_PAGE_CONCURRENCY`
- PDF 多页识别
- CSV 二进制传输
- 原生文件对话框

Joint Gate 01-02：Sol 一次审核 IP-01 与 IP-02 的累计 diff、各自范围、构建证据、最小暴露、错误模型、订阅清理和数据所有权。通过后冻结 Shared Contract v1。

### 连续工作流：Design System Foundations（历史 IP-03）

目标：建立 token、基础组件和 AppShell，不迁移复杂业务页面。

Luna 实现：

- foundations 和 semantic tokens
- primitives、controls、feedback、overlays、layout
- light/dark
- keyboard、focus、ARIA、reduced motion
- Storybook 组件状态
- AppShell 静态骨架

Continuous Checkpoint：验证组件 API、材质、圆角、渐变、对比度、交互和可访问性并记录证据；允许在后续集成中回访修正，保持业务无关即可，不形成中间 Gate。

### 连续工作流：低风险页面迁移（历史 IP-04）

依次迁移：

- Project Library
- Global Settings
- Project Settings

Continuous Checkpoint：验证 Design System 复用、路由、表单状态、数据所有权和兼容适配边界后继续，不等待 Sol。

### 连续工作流：Slate 输入与预处理（历史 IP-05A）

迁移：

- 图片/PDF 选择
- preview
- preparing state
- 多页处理进度
- async `toBlob`
- PDF 页间 yielding

Continuous Checkpoint：确认 Renderer 未重新承担重计算并记录取消、资源释放和生命周期证据后继续。

### 连续工作流：Recognition Workflow（历史 IP-05B）

迁移：

- RecognitionSettings
- RecognitionProgress
- RecognitionResult
- RecognitionError
- IPC progress subscription
- recognition Zustand slice

不得修改识别算法、超时、重试、并发或 provider 调度。

Continuous Checkpoint：验证 timeout/retry、迟到响应、unmount 清理、progress selector 和分页错误后继续。

### 连续工作流：Metadata 与 Tasks（历史 IP-05C）

分别迁移 metadata 和 tasks，不得合并为全局 workflow store。

Continuous Checkpoint：验证计算所有权、识别生命周期、状态恢复、持久化边界和 rerender 范围后继续，不等待 Sol。

### 连续工作流：Typed CSV Worker（历史 IP-06A）

迁移并类型化：

- decode
- merge
- normalize
- encode
- cancellation / error / lifecycle
- transferable `ArrayBuffer`

Continuous Checkpoint：验证数据复制、内存峰值和 Worker/Renderer ownership。现代模式的 fallback 必须保持 Worker-owned；如果需要改变 Main ownership、Shared Contract 或用户可见语义，触发真正的 Stop Condition。

### 连续工作流：Virtual Table（历史 IP-06B）

Luna 实现：

- TanStack Table
- TanStack Virtual
- 稳定 column definitions
- 行级更新和编辑状态隔离
- 10,000 行虚拟化

目标：DOM rows 不超过 100。

Continuous Checkpoint：验证全表 rerender、derived allocation、滚动和键盘交互并保留证据后继续。

### 连续工作流：CSV Editing 与 Export Parity（历史 IP-06C）

迁移：

- cell editing
- merge/normalize UI
- export workflow
- save dialog
- 旧版输出等价测试

Continuous Checkpoint：验证虚拟化性能、CSV 语义、二进制传输和编辑/导出兼容性后继续，不等待 Sol。

### 连续工作流：集成与 E2E（历史 IP-07）

完成：

- Feature routing
- project switching
- task restoration
- 从素材输入到导出的完整工作流
- Storybook 状态补齐
- Playwright Electron E2E

本阶段仍不得删除 legacy renderer。

Continuous Checkpoint：运行完整跨系统 E2E、迁移、性能、打包和统一视觉验证，然后由 Luna 生成路径/符号精确的 `CONTINUOUS_CLEANUP_MANIFEST.md`。该清单是同一连续包内清理的唯一范围；不需要中间 Sol Gate。

### 连续工作流：Cleanup（历史 IP-08）

Luna 只能删除 Continuous Cleanup Manifest 明确列出的内容：

- legacy renderer
- temporary adapters
- dead IPC
- unused dependencies
- stale styles
- stale comments

清理完成后必须重跑全部验证。Sol 在唯一的 `FINAL-IP-03-08` 中完成最终架构、兼容、迁移、数据安全、性能、UI、可访问性、清理清单和打包审核。只有 Final Review 输出 `APPROVED`，重构才算完成。

## 7. 统一验收指标

### 7.1 回归

- 迁移开始前的既有测试持续通过
- SQLite、Project Library 和任务数据可直接读取
- recognition timeout、retry、cancellation 和分页错误不退化
- CSV 输入输出与旧版本等价
- 新旧界面并行期间不存在数据双写冲突

### 7.2 性能

- 用户操作在一个 animation frame 内得到视觉反馈
- CSV 处理期间 Renderer 不出现超过 50ms 的计算型 long task
- 10,000 行表格 DOM rows 不超过 100
- PDF preparing 和 recognition progress 保持响应
- 大型 ArrayBuffer 不产生不必要复制

### 7.3 UI

- Feature 不重复实现基础控件
- 色彩、圆角、间距、阴影只来自 token
- light/dark 使用同一套 semantic token
- 覆盖 empty、loading、error、disabled、focus 状态
- 支持 keyboard、ARIA 和 reduced motion

### 7.4 工程质量

- 代码修改后同步添加或更新必要注释
- 删除与实际实现不一致的注释
- 不通过跳过、删除或放宽测试获得通过
- IP-01/02 保留独立可审计边界和联合 Gate；连续包保留模块 checkpoint/evidence ledger，并在末尾接受一次 Sol Final Review

## 8. 完成规则

```text
Master Plan
  ↓
Sol 批准 IP-01/02 基础批次
  ↓
Luna 完成 IP-01/02
  ↓
Sol Joint Gate 01-02
  ↓
Luna 一次连续实施 IP-03～IP-08 全部工作流
  ↓
模块 Checkpoint + 最终全量验证（无中间 Gate）
  ↓
Sol Final Review
  ↓
APPROVED / CHANGES REQUIRED
  ↓
Correction Package（如需要）/ 完成
```

原始 IP-03～IP-08 计划仍提供需求溯源，但不再提供施工授权。`IP-03-08-CONTINUOUS.md` 是 Gate 01-02 之后的唯一施工图；取消的是阶段授权、独立 Gate 和等待，不是 Architecture Invariants、Compatibility Contract、Decision Queue、测试/构建/性能/迁移/数据安全约束或最终 Sol 审核。
