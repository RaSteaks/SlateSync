# SlateSync 双模型架构与 UI Design System 重构总方案

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

单次 Luna 任务只能执行一个已经批准的 Implementation Package，不得跨越 Review Gate。

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

Gate 01：Sol 审核 ESM/CJS、构建产物、Electron entrypoint 和 fallback。

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

Gate 02：Sol 审核最小暴露、错误模型、订阅清理和数据所有权。通过后冻结 Shared Contract v1。

### IP-03：Design System Foundations

目标：建立 token、基础组件和 AppShell，不迁移复杂业务页面。

Luna 实现：

- foundations 和 semantic tokens
- primitives、controls、feedback、overlays、layout
- light/dark
- keyboard、focus、ARIA、reduced motion
- Storybook 组件状态
- AppShell 静态骨架

Gate 03：Sol 审核组件 API、材质、圆角、渐变、对比度和视觉一致性。通过后冻结 Primitive API。

### IP-04：低风险页面迁移

依次迁移：

- Project Library
- Global Settings
- Project Settings

Gate 04：Sol 审核路由、表单状态、Design System 复用和兼容适配边界。

### IP-05A：Slate 输入与预处理

迁移：

- 图片/PDF 选择
- preview
- preparing state
- 多页处理进度
- async `toBlob`
- PDF 页间 yielding

Gate 05A：Sol 确认 Renderer 未重新承担重计算，并检查取消和生命周期。

### IP-05B：Recognition Workflow

迁移：

- RecognitionSettings
- RecognitionProgress
- RecognitionResult
- RecognitionError
- IPC progress subscription
- recognition Zustand slice

不得修改识别算法、超时、重试、并发或 provider 调度。

Gate 05B：Sol 审核 timeout/retry、迟到响应、unmount 清理、progress selector 和分页错误。

### IP-05C：Metadata 与 Tasks

分别迁移 metadata 和 tasks，不得合并为全局 workflow store。

Gate 05C：Sol 审核状态所有权、恢复流程、持久化边界和 rerender 范围。

### IP-06A：Typed CSV Worker

迁移并类型化：

- decode
- merge
- normalize
- encode
- cancellation / error / lifecycle
- transferable `ArrayBuffer`

Gate 06A：Sol 审核数据复制、内存峰值和 Worker/Renderer ownership。

### IP-06B：Virtual Table

Luna 实现：

- TanStack Table
- TanStack Virtual
- 稳定 column definitions
- 行级更新和编辑状态隔离
- 10,000 行虚拟化

目标：DOM rows 不超过 100。

Gate 06B：Sol 审核全表 rerender、derived allocation、滚动和键盘交互。

### IP-06C：CSV Editing 与 Export Parity

迁移：

- cell editing
- merge/normalize UI
- export workflow
- save dialog
- 旧版输出等价测试

Gate 06C：Sol 审核 CSV 语义、二进制传输和编辑/导出兼容性。

### IP-07：集成与 E2E

完成：

- Feature routing
- project switching
- task restoration
- 从素材输入到导出的完整工作流
- Storybook 状态补齐
- Playwright Electron E2E

本阶段仍不得删除 legacy renderer。

Gate 07：Sol 做跨系统审核并输出唯一允许执行的 Cleanup Manifest。

### IP-08：Cleanup

Luna 只能删除 Cleanup Manifest 明确列出的内容：

- legacy renderer
- temporary adapters
- dead IPC
- unused dependencies
- stale styles
- stale comments

Gate 08：Sol 完成最终架构、兼容、性能、UI、可访问性和打包审核。

只有 Gate 08 输出 `APPROVED`，重构才算完成。

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
- 每个 Package 都有独立 diff、测试证据和 Review Gate

## 8. 完成规则

```text
Master Plan
  ↓
Sol 生成当前 Implementation Package
  ↓
Luna 限定范围实现
  ↓
Automated Validation
  ↓
Sol Review Gate
  ↓
Correction Package（如需要）
  ↓
APPROVED
  ↓
阶段提交
  ↓
下一 Package
```

原始总计划是战略；每个 Review Gate 后由 Sol 根据实际仓库状态生成的 Package 才是最新施工图。
