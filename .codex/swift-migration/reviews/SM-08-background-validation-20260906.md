# SM-08 后台验证记录（2026-09-06）

> 本文件是后台验证的证据索引，不是独立审查报告，也不是 Owner approval。由于本轮明确要求所有测试在后台进行，任何需要启动或操作前台应用的验收均保留为 `BLOCKED_ENV`，不得据此把 SM-08 标记为 `COMPLETE`。

## 结论

当前结论：`BLOCKED_ENV`。

后台可执行的代码、功能回归、真实 SQLite 规模加载和本地 Release/Archive 检查已完成；原生窗口交互、中文 IME、VoiceOver、明暗色、最小窗口布局、完整退出/重开生命周期和 clean Gate 仍没有满足阶段清单要求的证据。

## 收尾代码审查后复验

| 范围 | 结果 | 证据 |
| --- | --- | --- |
| SM08 owner 专项 | PASS | `/private/tmp/slatesync-sm08-owner-46.log`；46/46 通过，包含 CSV 缩表选区、Paddle 安装环境、识别取消 ticket、迟到 picker 准入、终止错误所有权和进度单调性回归 |
| 后台 Swift 整轮回归 | PASS | `/private/tmp/slatesync-sm08-progress-swift.log`；213/213 测试记录，退出码 0；跳过所有 `SM08NativeSurfaceTests` 与隐藏 List 规模用例 |
| 隐藏原生 List 规模 | PASS_WITH_FRAMEWORK_WARNING | `/private/tmp/slatesync-sm08-postreview-hidden-list.log`；500 projects / 1,000 tasks、1 warm-up + 5 samples，1 项通过；每个 List 挂载有一次 `NSTableView` delegate 重入预警（共 12 次） |
| 隐藏 List 最小对照 | REPRODUCED_FRAMEWORK_BEHAVIOR | `/private/tmp/slatesync-sm08-minimal-hidden-list.log`；不含 SlateSync 模型/绑定的纯 `List(0..<500)` 在未 ordered `NSWindow` 中 6 次挂载精确生成 6 条同样预警 |
| Xcode Debug build | PASS | `/private/tmp/slatesync-sm08-progress-xcode-debug`；当前代码 `xcodebuild` 退出码 0 |
| Xcode static analysis | PASS | `/private/tmp/slatesync-sm08-progress-xcode-analyze`；当前代码 `xcodebuild analyze` 退出码 0，无源码诊断 |
| Xcode Release build | PASS | `/private/tmp/slatesync-sm08-progress-xcode-release`；当前代码 `xcodebuild` 退出码 0 |
| Release Archive | PASS_LOCAL | `/private/tmp/slatesync-sm08-progress-signed.xcarchive`；当前代码 arm64/x86_64 universal、ad hoc、hardened runtime，`codesign --verify --deep --strict` 通过 |

收尾审查修复了 CSV 缩表时选区越界、Paddle 子进程继承用户 pip/HOME
配置、coordinator 构建窗口内的识别取消竞态、迟到的本地 CSV picker 回调绕过
生命周期准入门，以及并行测试中进度收集乱序造成的假失败。这是代码审查与后台
复验，不构成阶段要求的独立 review 或 Owner approval。

后续错误横幅审查又修复了终止错误的错误所有权：关闭/退出失败现在由
`TerminationCoordinator` 自行清除，导航所有者不再被误改；只有导航/自动保存
错误提供“重试保存”，IME 组字和 Library barrier 等终止错误只允许关闭提示。

进度投影审查进一步发现同步 service callback 经独立 MainActor task 投递后存在
乱序可能。Provider 探针现在同时拒绝 completed/percent 倒退，Paddle 安装拒绝
percent 倒退；反序回调测试固定验证较新的完成态不会被迟到早期样本覆盖。

## 历史 UI 失败静态分诊

`xcresulttool` 对 `/private/tmp/slatesync-sm08-ui-rerun-20260906.xcresult` 的活动树
确认 Help 用例通过；多窗口和 Settings 用例均在发送 ⌘W 后等待窗口
数下降时超时。失败期间的自动录像显示目标窗口持续可见，因此这两项是产品
命令缺口，不是 XCUI `windows.count` 滞后。

代码根因是 `SlateSyncCommands` 使用 `CommandGroup(replacing: .saveItem)` 后只放回
自定义 Save；macOS 的 `.saveItem` 系统组同时包含 Close，因而 ⌘W 被全局移除并
同时影响 WindowGroup 与 Settings。实现已改为 `CommandGroup(after: .saveItem)`，保留
系统 Close 并追加聚焦 Save。该根因有直接历史证据且可后台编译，但修复后
的真实 ⌘W 交互仍需在允许前台的专用 UI 环境中复验，暂不改记为 PASS。

## 已验证证据

| 范围 | 结果 | 证据 |
| --- | --- | --- |
| 识别选项保存/恢复 | PASS | `SM08OwnershipTests/testRecognitionOptionsPersistAndRestoreThroughTaskSnapshot` |
| metadata 缺失素材匹配 | PASS | `SM08OwnershipTests/testMetadataMatchingUsesCanonicalResolveMaterialKeys`；扫描使用 Workflow canonical material keys |
| CSV 键盘顺序与边界 | PASS | `SM08OwnershipTests/testCSVKeyboardNavigationUsesGridOrderAndBounds` |
| Resolve material key projection | PASS | `SM05WorkflowServiceTests/testResolveMaterialKeyProjectionMatchesMetadataScanContract` |
| 真实数据库规模加载 | PASS | `SM08OwnershipTests/testRealSQLiteProjectAndTaskScaleLoad`；500 projects / 1,000 tasks，1 warm-up + 5 samples |
| 后台 Swift 回归 | PASS | `/private/tmp/slatesync-sm08-swift-regression-final.log`；退出码 0，210 条测试记录；按约束跳过 native window surface 与五样本 native list 用例 |
| SwiftPM Debug 构建 | PASS | `swift build --configuration debug`，退出码 0 |
| Release 构建 | PASS | `/private/tmp/slatesync-sm08-release-derived-final`，`** BUILD SUCCEEDED **` |
| Release Archive | PASS | `/private/tmp/slatesync-sm08-release-20260906-final.xcarchive`，`** ARCHIVE SUCCEEDED **` |
| contract 静态负例 | PASS | `node script/tests/sm08_contract.mjs --self-test` |
| Gate helper 自测 | PASS | `/private/tmp/slatesync-sm08-phase-gate-selftest-final.log`；82 passed / 0 failed |
| Node compatibility | PASS | `/private/tmp/slatesync-sm08-node-compat-final.log`；324 passed / 0 failed |
| Modern compatibility | PASS | `/private/tmp/slatesync-sm08-modern-compat-final.log`；25 files / 118 tests passed |
| JavaScript static check | PASS | `/private/tmp/slatesync-sm08-static-check-final.log` |
| TypeScript typecheck | PASS | `/private/tmp/slatesync-sm08-typecheck-final.log` |
| Modern production build | PASS | `/private/tmp/slatesync-sm08-modern-build-final.log` |
| Node/Electron SQLite ABI | PASS | `/private/tmp/slatesync-sm08-native-abi-final.log`；Node 137 / Electron 148 modules，SQLite 3.53.2 |

真实 SQLite 指标文件：`/private/tmp/slatesync-sm08-metrics/real-sqlite-scale.json`。

| 指标 | 样本范围 | 阶段预算 |
| --- | ---: | ---: |
| project list load | 291.21–310.09 ms | ≤ 1,500 ms |
| task list load | 10.31–10.70 ms | ≤ 900 ms |

Archive 为 universal arm64/x86_64，包通过本地 codesign strict verification，签名为 ad hoc runtime 且没有 Developer ID Team ID；这只证明本地包完整性，不证明 notarization 或发行资格。

## UI 历史诊断

前台约束生效前的最新记录为 `/private/tmp/slatesync-sm08-ui-rerun-20260906.xcresult`：5 项中 3 项通过，Help 导航通过；以下两项因 `.saveItem` 替换误删系统 Close 而在 ⌘W 后的窗口计数等待中超时：

- `testIndependentWindowsAndNewWindowAfterClosingLastWindow`
- `testSettingsCanOpenAndCloseWithoutReplacingHelpRoute`

该记录不是本轮后台测试结果。历史活动树、录像和命令组定义现已将两项分类为同一产品缺陷，并已修复代码；但本轮不重新启动应用验证，因此两项仍不能改记为 PASS。

## BLOCKED_ENV 清单

- 多窗口创建、关闭最后窗口后重开、Settings 关闭后返回：需要前台 AppKit/XCUI 窗口状态，不能在本轮后台约束下复验。
- 中文拼音 marked text、纯键盘端到端操作、VoiceOver：需要真实编辑控件和辅助功能运行环境，不能用单元测试替代。
- 深色/浅色切换及 960×600 最小窗口布局：需要真实窗口渲染检查，未宣称通过。
- 完整窗口退出/重开、后台识别/metadata 操作取消、资源释放：已有部分模型/服务测试和真实数据库加载，但缺少阶段要求的完整原生生命周期证据。
- `PERF-01` 的隐藏列表规模测试已达标；其 AppKit delegate 预警已由纯 SwiftUI 最小对照复现，可归类为未 ordered 窗口中的框架/harness 行为，而非 SlateSync model 重入。可见窗口仍需在专用 UI 环境复验；`PERF-03` 生命周期释放仍缺完整原生证据。
- clean Gate、独立 `reviews/SM-08.md`、最终独立审查和 Owner approval：不能由本文件代替。

## 收尾状态

`CURRENT_STATE.json` 保持 SM-07 `COMPLETE`，没有写入 SM-08 `COMPLETE`，也没有启动 SM-09。本轮实现检查点提交不等于最终治理提交；完成 SM-08 仍需在允许的专用 macOS UI/辅助功能环境中补齐上述阻塞项，然后重新执行正式 Gate、独立审查、Owner approval 和最终治理提交。
