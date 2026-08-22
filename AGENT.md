# SlateSync 当前项目方案

## 当前任务

执行 `.codex/refactor/packages/IP-03-08-C02.md`，关闭
`reviews/FINAL-IP-03-08.md` 的全部阻塞项，并完成整个 post-IP-02 架构
变更。当前工作不是新阶段；它只修正现代 Renderer 的兼容性、生命周期、
Worker 边界、验收证据和最终治理交接。

## 实施顺序

1. 修复 task 恢复/切换、Worker prime/clear、不可变自动保存、迟到响应、
   新建/删除/重试和状态反馈。
2. 恢复 slate CSV 加载、替换、清除、provider-free 合并和识别合并，CSV
   语义只在保留的 Worker 单一实现中运行。
3. 让现代 preparation Worker 复用冻结的裁剪/分段算法，恢复图片/PDF
   profile、页数/密码错误、请求大小和 direct-PDF 选择。
4. 补齐现代单元、组件、E2E、迁移、性能、内存、资源清理、视觉和无障碍
   验证；不得通过放宽断言或自动接受 golden 获得通过。
5. 独立复跑所有 Electron 模式、无签名目录包、包内容、安全导航、密钥
   隔离和 Node/Electron ABI 自动恢复。
6. 仅在全部证据真实通过后更新 Decision Queue、Compatibility/Migration、
   Completion Report 和 authority handoff，并停止等待 Sol 复审。

## 架构边界

- 保持 Shared Contract v1、唯一 `window.slateSync`、Result/AppError、Main
  SQLite 权威、七个 Zustand slice 和单 Renderer 选择。
- 不修改 recognition/provider/OCR 算法、CSV 字节语义、SQLite/Library/task
  格式、version-1 迁移、Electron IPC、包身份或签名发布设置。
- 不增加第二网关、第二 Renderer、第二持久化写入者、mega-store 或临时
  兼容真相。
- 复杂 CSV 与准备计算由 Worker 持有；Renderer 只协调状态与用户交互。
- 对非显然的所有权、并发、恢复和资源生命周期代码同步维护注释。

## 数据与 Git 安全

- 所有 Electron/E2E/视觉/迁移运行都使用新建临时 `userData` 和显式临时
  `libraryPath`。
- 被隔离的默认 macOS Project Library 不得由工具打开、复制、哈希、查询、
  迁移、恢复、删除或改写；最终只记录 Owner 的明确处置。
- 不执行 `git add`、`commit`、`push`、`reset`、`clean` 或切换分支。

## 完成条件

只有 C02 的代码、回归测试、完整性能/内存矩阵、双轮完整视觉证据、迁移、
打包、安全、ABI、scope 和数据安全处置全部完成，且新的 Completion Report
可真实写明 `READY FOR SOL FINAL REVIEW: YES`，才进入最终交接。

## 2026-08-22 C02 执行结果

- 技术修正已完成：task 原子恢复/切换、单写者 autosave、slate CSV 与
  canonical key Worker 所有权、完整图片/PDF preparation、资源释放、项目/
  任务切换性能和精确 scope 归因均已实现。
- 最终验证：Node 232/232、modern 19/19、Electron E2E 10/10、视觉
  14/14 双轮字节一致、500 项目/1,000 任务与 10k CSV 阈值通过、无签名
  目录包/packaged smoke/安全资源/ABI 自动恢复通过。
- `.gitignore` 的未授权改动已回退；cleanup 删除集仍为空；未暂存、提交、
  推送、重置、清理或切换分支。
- 唯一剩余阻塞不是代码缺陷：历史隔离事故对默认 macOS Library 的行级
  影响不可证明。该路径继续隔离且本次未访问。C03 只等待 Owner 明确接受
  该不可证明影响、确认路径可丢弃，或另行授权精确内容审计。
