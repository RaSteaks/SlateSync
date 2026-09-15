# 场记工作台 UI 重设计验收

> 历史资料归档（2026-09-16）：以下描述原 UI 工作期间的实现和验证记录，
> 不代表当前分支已经实现或重新通过这些检查。所引用的临时日志、结果包及
> `ui-refresh/` 证据未随本文入库；本次仅核对资料内容，未复跑历史 UI 验收。


## 范围

2026-09-12 在已有未提交代码上增量调整项目库、侧栏、任务栏、工作区页首，以及公共标题/数量组件。
保持原生 SwiftUI、macOS 15 基线、现有语义配色、两个密度档、保存屏障与模型边界。

| 设计约定 | 实现证据 | 结论 |
| --- | --- | --- |
| 原生导航、选择、编辑 | List / NavigationSplitView / segmented Picker 保留 | 一致 |
| 语义颜色统一 | 新增界面复用 SlateSyncTheme，无页面 RGB 常量 | 一致 |
| 页首与面板分层 | SlatePageHeading 承载页面身份，SlatePanelHeading 保留面板职责 | 新规则同步 DESIGN.md |
| 状态不依赖颜色 | TaskRailRow 使用状态文字与 SF Symbols | 一致 |
| 异步/危险操作 | 未修改模型、保存或确认逻辑 | 一致 |

## 已完成验证

- `swift test --filter SlateSyncUIUnitTests`：85 项，1 跳过，0 失败。
- Xcode Debug 应用与 UI 测试目标编译通过。
- Premium strict 静态审查：0 findings。
- `git diff --check`：通过。
- `swift build -Xswiftc -warnings-as-errors`：未通过，现有 KeychainCredentialStore.swift:96 的
  kSecUseAuthenticationUIFail 弃用告警被升级为错误。本轮未改动该文件。
- DESIGN.md 官方 lint 离线尝试未执行成功：本机未缓存 @google/design.md；未添加依赖。

## UI 回归

首次两项 UI 测试未通过：项目行辅助文本由原生列表暴露为 value，旧测试只匹配 label；
矩阵验收时前台其他窗口遮挡测试窗口。保留首次失败，不将其计为通过。
测试已兼容 label/value 两种原生投影，并在矩阵调整窗口后显式激活目标应用；
断言和实际尺寸要求保留。最终重跑结果另记于下方。

测试使用临时项目库和合成场记图，不访问真实项目、API Key 或模型服务。
原始构建/测试日志与 xcresult 位于 `/tmp/slatesync-ui-redesign/`，属于临时验收产物。

### 最终重跑结果

- `testCreatesProjectAndOpensWorkspaceInIsolatedLibrary`：通过，包含创建、进入工作台、返回项目库与原生双击重开。
- `testWorkspaceAppearanceDensityAndComparisonMatrix`：仍在首个 1440×900 配置按钮的 isHittable 断言失败。
  重跑附件继续显示 Codex 窗口覆盖大部分目标画面；未证明完整深浅色/密度/最小尺寸矩阵通过。
- 已通过 CUA 获取并目视检查实际深色工作区，标题、任务列表、预览和配置面板可见。
  项目库实际截图保存在 `docs/ui-redesign-assets/project-library.png`。
- 未运行完整端到端识别、模型请求和发布验证，未提交或推送。
