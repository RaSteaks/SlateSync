# SlateSync Architecture Invariants

Authority status: **CURRENT AND BINDING FOR
`IP-03-08-CONTINUOUS` VERSION 2026-08-21.2**. Start from `README.md` and
`CURRENT_STATE.json`; historical package boundaries cannot override this file.

本文件定义整个重构过程中不可由 Implementer 自行修改的架构边界。发现实际代码与不变量冲突时，必须写入 `DECISION_QUEUE.md` 并交由 Sol High 决策。

## Renderer

Renderer 只负责：

- React rendering
- 用户交互
- Feature orchestration
- Zustand state
- 轻量 derived state

Renderer 禁止执行：

- OCR 或 AI provider request orchestration
- SQLite
- 原生文件系统访问
- API key 管理
- CSV decode、merge、normalize 或 encode
- 大规模图像或数组计算
- 直接使用 `ipcRenderer`
- 直接依赖 IPC channel 名

## Main

Main 负责：

- Electron lifecycle
- BrowserWindow
- Native dialogs
- File system
- SQLite
- Project Library
- Task persistence
- Secrets
- OCR / AI orchestration
- Provider configuration
- Recognition timeout、retry、cancellation 和 concurrency

## Preload

Preload 是唯一的 Renderer 到 Main gateway。

只允许暴露按领域划分的 `window.slateSync` API。禁止暴露：

- `ipcRenderer`
- raw filesystem API
- SQLite connection
- API key
- 任意可调用 IPC channel 的通用函数

## Worker

Worker 负责 Renderer 侧 CPU-heavy workload：

- CSV decode
- CSV merge
- CSV normalize
- CSV encode
- large-array transformation
- 适用时的图像预处理

二进制数据使用 `ArrayBuffer` 和 transferable。禁止退化为：

- JavaScript number array
- JSON serialized binary
- 大对象重复 structured clone

## IPC Contract

所有 request/response API 使用统一结果类型：

```ts
type Result<T> =
  | { ok: true; data: T }
  | { ok: false; error: AppError }

interface AppError {
  code: string
  message: string
  retryable: boolean
}
```

事件订阅必须返回 unsubscribe，并确保 React unmount 后不再更新状态。

## State Ownership

Zustand 按领域切片：

```text
project
task
slate
recognition
metadata
export
ui
```

要求：

- 高频 progress 使用独立 selector
- persisted state 和 ephemeral UI state 分离
- derived state 不重复持久化
- 禁止单个巨大 application store
- 禁止同一业务数据出现多个 source of truth

## UI System

Feature 不得自行实现：

- Button
- IconButton
- Input
- Select
- Checkbox
- Dialog
- Tooltip
- Toast
- Surface
- Badge
- Spinner
- Progress

Design System 组件必须 domain-neutral，不接受 recognition、CSV、project 等业务语义属性。

## Compatibility

未经 Sol Review，不得修改：

- recognition timeout 和 retry semantics
- `AbortError` compatibility
- provider request behavior
- PDF multi-page behavior
- CSV output semantics
- task persistence format
- SQLite schema
- Project Library format
- environment variable semantics
- file dialog behavior

## Comments and Documentation

代码修改后必须：

- 为非显然的架构边界、数据所有权、并发和兼容逻辑补充注释
- 更新受实现变化影响的原有注释
- 删除失效或误导性注释
- 避免注释复述代码表面行为

## Enforcement

任何不变量变更必须满足：

1. 写入 Decision Queue。
2. 由 Sol High 评估。
3. 形成或更新 ADR。
4. 生成新的 Implementation Package 或 Correction Package。
5. 通过对应 Review Gate。
