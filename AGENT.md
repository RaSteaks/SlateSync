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
  SQLite 权威、八个 Zustand slice 和单 Renderer 选择。
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

## 2026-08-23 Storybook 10 配置维护

- 自动文档由 story meta 的 `autodocs` tag 启用，不再使用已移除的
  `docs.autodocs` 主配置。
- Storybook preview 显式引用 `vite/client` 类型，使位于 renderer
  TypeScript 项目之外的全局 CSS 导入仍能被编辑器正确解析。

## 2026-08-23 Renderer 输入与界面收敛

- 文件选择统一由组件持有的 `ref` 触发；场记单、场记 CSV 和 Resolve CSV
  共享 Renderer 内纯函数校验与拖放 hook，不修改 IPC、CSV 字节语义或 Main。
- 识别设置使用单一草稿对象与脏状态；补回识别/设置快捷键、待保存关闭保护、
  文件和结果区域焦点引导，并将表格单元格改为失焦或 Enter 后提交。
- 主题和密度使用带版本的 Renderer `localStorage` 偏好，不扩展 Shared
  Contract；compact token、面板内边距、控件状态、字符计数和动效均在现有
  design-system/styles 内实现。
- 删除工作台宣传式副标题和多余技术标签，统一中文短文案；保留 Provider、
  Resolve CSV 等任务所需产品名，任务状态和页数改为明确的中文显示。
- 日常验证只运行沙盒内 TypeScript、Vitest、Node 和构建任务。Electron、
  E2E、视觉截图等会创建 macOS 前台窗口的测试不再自动运行，只在 Owner
  明确要求最终 GUI 验收时使用隔离的临时 `userData` 与 `libraryPath`。

## 2026-08-23 项目删除、系统主题与识别结果功能包

- 项目设置新增危险操作区。默认项目禁止删除；普通项目必须先通过不可撤销
  警告，再精确输入项目名，才会永久删除项目目录与 Library 索引。Main 在
  删除前关闭该项目的 SQLite runtime，并用重命名暂存与补偿恢复保护一致性。
- 本功能包是早期“不得改 IPC”边界的显式例外，仅新增 `delete-project` 与
  `cancel-recognition` 两个类型化通道；唯一 `window.slateSync` 网关、Result
  envelope、SQLite/CSV 格式及识别算法语义保持不变。
- 识别取消由 Renderer、Preload、Main 到模型 HTTP 请求贯通，外部 AbortSignal
  不参与重试；停止状态会冻结迟到进度，完成/失败响应由 operation token 隔离。
- 主题默认跟随 `prefers-color-scheme`，系统运行时变化会立即更新；用户仍可在
  全局设置中明确选择浅色或深色，版本化本地偏好继续持久化。
- 场记单载入区只显示文件摘要，完整图像仅在专用预览区出现；识别记录改为
  带表头、横向滚动、搜索、行增删和单元格编辑的语义化表格。
- 验证继续遵守无前台测试约束：Node、Vitest、TypeScript、Vite、Storybook
  和静态语法检查均在沙盒完成；本次结果为 Node 242/242、Vitest 35/35，
  production Renderer/Preload/Main 与 Storybook 静态构建通过，并已恢复
  `better-sqlite3` 的 Electron ABI。不自动启动 Electron GUI 冒烟测试。

## 2026-08-24 审查修复：取消、删除与表格草稿的生命周期

- 停止识别不再把 `AbortController.abort()` 当作完成：Main 持有每个项目的
  active recognition，并在 OCR 子进程/模型请求、SQLite 写租约和 limiter 全部
  释放后才确认取消；OCR 与外部模型共用同一个 AbortSignal，取消不会落入
  optional OCR 的远端降级路径。
- 项目硬删除采用“先改名为 tombstone、再删索引、最后物理清理”的两阶段顺序。
  目录清理失败后项目仍保持逻辑删除，初始化会重试命名 tombstone，绝不从已
  部分删除的目录恢复索引。
- 删除开始时立即禁止同项目新读写，并等待已获读租约的 IPC 调用完成后才关闭
  SQLite runtime。这使 `projectRuntime.get()` 无法在 close 与 delete 之间重新
  打开数据库。
- CSV 虚拟表格与识别结果表把未提交单元格值提升到表级队列：失焦、Enter、
  虚拟行卸载、组件卸载和窗口关闭前都会刷新。输入法组合期间不会把 Enter/Escape
  误认为提交或取消，保持中文等 CJK 输入完整。
- 历史 IPC baseline fixture 固定在 `c7dafa4` 的库存；`delete-project` 和
  `cancel-recognition` 仅记录于 additive fixture，并由测试以两者并集校验
  当前 Main/Preload 表面，避免历史快照被当前实现反向改写。
- 本轮 premium UI 静态审计读取 `premium-ui.json`、`DESIGN.md` 与
  `UX-CONTRACT.md`，严格模式 0 findings；`npm run check`、`npm run test:node`
  （242/242）、`npm run test:modern`（35/35）、`npm run typecheck`、
  `npm run build:modern` 与 `npm run build:storybook` 均在沙盒完成。Storybook
  仅提示无法写入用户目录的全局 settings，不影响静态构建产物；未启动 Electron。

## 2026-08-24 工作台可选输入布局

- 将素材元数据回填与场记 CSV、Resolve CSV 的选择统一收纳到识别设置之前的
  “可选输入”区域；右侧“回填预览”只保留 CSV 预览、编辑和清除动作。
- 仅调整 Modern Renderer 的布局与说明文案，继续复用现有文件校验、拖放、
  Worker、metadata scan 和 autosave 生命周期，不改变 CSV 或识别数据语义。

## 2026-08-24 Renderer 开发热更新

- `npm start` / `npm run dev` 通过 `scripts/electron-dev.mjs` 同时启动 Vite
  Renderer dev server 和 Electron；Electron 开发态使用 `loadURL`，生产态与
  Vite 不可用时继续使用已构建的 `out/renderer/index.html`。
- HMR 仅开放本机 Renderer 端口的 websocket 与开发样式能力，生产 file:// shell
  保持原有严格 CSP；Main/Preload 仍由现有 predev 构建并在修改后重启应用。

## 2026-08-24 修复开发环境白屏

- Electron dev 编排器必须显式向 Vite 传入 `vite.renderer.config.ts`；仓库没有
  根级 `vite.config.ts`，省略 `--config` 会让 Vite 服务仓库根目录，Electron
  虽然能完成 `loadURL`，但拿不到 Renderer 入口，最终表现为空白窗口。
- Vite React Refresh 的开发 HTML 会注入内联启动模块；开发态 CSP 额外允许
  `unsafe-inline`，否则 Electron 会拦截该模块并阻止 Renderer 挂载。
- 该放宽只发生在 Vite dev server 的 HTML 转换中，生产构建和 file:// Renderer
  继续使用严格的脚本策略。
- Modern 回归测试固定 dev 编排器的目标配置参数与共享子进程环境，避免再次出现
  “Vite ready 但应用未加载”的假成功。

## 2026-08-24 UI 交互一致性优化

- 项目库卡片使用覆盖整卡的原生按钮作为进入项目入口，设置与归档继续作为
  独立控件；项目名称、描述、任务摘要及空白区域均可打开项目，并保留键盘焦点。
- 项目库统计和列表标题改为“可用项目”与“项目列表”，不再使用“当前项目”。
- 工作台的场记 CSV 与 Resolve CSV 统一使用有边框的次级按钮样式。
- 浅色/深色主题只在实际切换时过渡颜色、边框和阴影，首次渲染不播放，且遵循
  `prefers-reduced-motion`。
- 验证结果：premium strict audit 为 0 findings；Modern Vitest 13 个文件、39 项
  通过，`npm run check`、`npm run typecheck`、`npm run build:modern` 与
  `npm run build:storybook` 通过。官方 DESIGN.md lint 为 0 errors；10 条既有
  frontmatter token 映射 warning 未在本次小范围任务中扩张修复。

## 2026-08-24 固定侧栏底部控件

- 桌面端共享 `Sidebar` 固定为视口高度，右侧工作区继续使用文档滚动；收起侧栏与
  主题切换控件固定在侧栏底部，不再随工作区长内容上下移动。
- 极短桌面窗口只允许侧栏中部导航区滚动，品牌区和底部控件保持可见；小于
  640px 的顶部导航显式恢复自然高度和可见溢出，避免继承桌面约束后裁切内容。
- 验证结果：premium strict audit 为 0 findings；Modern Vitest 14 个文件、41 项
  通过，`npm run check`、`npm run typecheck`、`npm run build:modern` 与
  `npm run build:storybook` 通过；未自动启动 Electron 前台窗口。

## 2026-08-24 Electron 开发契约与本机边界

- Renderer 开发脚本的有意迁移记录在 build contract 的 transition inventory，
  历史 baseline 保持不变，标准 Node 套件可继续检测未登记的命令漂移。
- HMR Renderer URL 只接受无认证信息的 loopback HTTP 地址；普通导航和服务端
  重定向均须保持在配置的同一来源，远程页面无法继承 SlateSync typed Preload。
- URL 边界使用独立纯函数覆盖 localhost、IPv4、IPv6、协议、认证信息、端口和
  远程域名场景，Electron Main 继续只负责窗口生命周期与事件接线。
- 验证结果：`npm run test:node` 242/242、Modern Vitest 14 个文件 44/44 与
  `npm run typecheck` 通过；未启动 Electron 前台窗口。

## 2026-08-24 应用内品牌图标统一

- Modern Renderer 左上角品牌标记改为直接导入 `build/icon.png`，与 Electron
  窗口和 macOS 安装包共用同一 App Icon，不再维护独立的字母 `S` 图块。
- 图标保持原侧栏 34px 布局占位和原始宽高比，折叠侧栏与窄屏导航不发生位移；
  品牌图片为装饰内容，功能性图标仍遵循 Lucide 与可访问名称规范。
- 验证结果：Modern Vitest 14 个文件 45/45、`npm run typecheck`、Renderer
  production build 与 `git diff --check` 通过；premium strict audit 为 0 findings，
  DESIGN.md lint 为 0 errors，10 条既有 token 映射 warning 未扩张处理。

## 2026-08-24 草稿任务原位完成

- Renderer 在草稿自动保存完成后，将当前项目内的稳定任务 ID 随识别请求传给
  Main；Main 以该 ID 更新任务状态和识别结果，不再为完成态生成第二条任务。
- 更新通过项目作用域的 `taskStore.updateTask` 合并，因此草稿阶段保存的原始输入、
  CSV 与编辑数据继续保留；没有草稿 ID 的独立识别仍允许创建新任务。
- Preload 继续透明转发唯一 typed request，新字段为向后兼容的可选 contract；
  回归测试覆盖 Renderer 请求接线、Preload payload 与 Main 的 update-not-create。
- 验证结果：`npm run test:node` 243/243、Modern Vitest 15 个文件 46/46、
  `npm run typecheck`、`npm run build:modern` 与 `git diff --check` 通过；未启动
  Electron 前台窗口。
