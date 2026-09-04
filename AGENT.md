# SlateSync 当前项目方案

## 2026-09-03 原生 Swift 重写

- 当前权威方案迁移到 `.codex/swift-migration/README.md`；
  `.codex/refactor/` 只作为 Electron 兼容行为与历史证据。
- 目标为 macOS 15.0+ 原生应用，SwiftPM 管理五个业务模块，
  `SlateSync.xcodeproj` 提供 App、Unit Test、UI Test、Run、Debug、Profile
  与 Archive。
- Windows 支持终止；新 CI、打包、文档和运行时代码只面向 macOS。
- SQLite/Project Library v1、任务 JSON、CSV 字节语义、OCR-first、Provider
  请求与识别取消/重试/并发行为在迁移 Gate 前保持兼容。
- 所有自动测试使用显式临时 Application Support 与 Project Library，禁止
  访问用户默认 Library。
- `SM-01`、`SM-02` 已完成 Owner 批准；SM-03 的实现和审查修复已完成，正在
  进入 dedicated review commit、clean Gate 与 Owner 批准流程。
- 阶段状态、环境替代证据与不可豁免项以
  `.codex/swift-migration/PHASE_GATES.md` 为准；本地统一入口为
  `./script/phase_gate.sh SM-XX`，禁止用 dirty diagnostic 结果声明完成。

## 2026-09-03 SM-01 独立审查修复

- 正式 Gate 的真实 App 启动必须由 Gate 创建并注入临时
  `SLATESYNC_TEST_ROOT`，验证隔离 Library 数据库后精确停止进程；任何普通
  Gate 调用都不得回退到用户默认 Application Support。
- 运行脚本按本仓库构建产物的完整 executable path 查找、停止和验证进程，
  不再用共享进程名影响其他 SlateSync 安装。
- Gate 显式校验五个 SwiftPM 模块、macOS 15、Swift 6、Xcode 三目标、共享
  Scheme/Test Plan、SM-02 未开始、历史基线存续和生成物未被跟踪；Release 与
  Archive 另外验证签名确为 ad-hoc。
- SwiftPM Project Library 测试在 SQLite 生命周期结束后清理完整临时目录。
  修复提交必须重新通过干净正式 Gate，随后才允许 Owner 用仅含状态和审查报告
  的治理提交将 SM-01 标记为 `COMPLETE`。

## 2026-09-03 SM-02 macOS-only platform contract

- 当前产品入口固定面向 macOS：原生 `build_and_run.sh`、Electron 开发/打包、
  Vision OCR 与 PaddleOCR 安装入口均在执行构建或安装前拒绝非 macOS 主机。
- `electron-builder.yml` 只保留 macOS DMG/ZIP 的 arm64 与 x86_64 目标；宿主包装
  脚本会拒绝非 macOS builder 参数，过渡包最低系统固定为 macOS 15.0，不再保留
  Windows/Linux 当前产物配置。
- GitHub CI 与 Release build/publish jobs 统一使用 macOS runner，并调用同一份
  `./script/phase_gate.sh SM-02`；不使用 `--allow-dirty` 伪造正式 Gate 结果。
- SM-02 Gate 继续实际运行 SM-01 建立的隔离 App 启动、Universal Release、Xcode
  Archive 与 ad-hoc 签名检查；自动 App 验证使用 `open -g` 后台启动，平台收敛不得
  把产物验证降级为静态配置扫描，也不得让 Gate 抢占前台。
- 阶段状态检查同时覆盖批准前的“上一阶段 COMPLETE → 当前包”和批准后的“当前阶段
  COMPLETE → 下一包”，避免合法治理提交因硬编码上一阶段状态而被 Gate 误判。
- Electron、React、Node 与跨平台历史 helper 仍保留在仓库，作为 SM-09 前的兼容
  基线；本阶段只切断其当前非 macOS 产品入口，不修改 SQLite、CSV、OCR、Provider
  或任务数据契约。
- SM-02 代码与测试已进入正式审查，`CURRENT_STATE.json` 在 clean Gate、审查报告
  和 Owner 批准全部完成前继续保留 SM-01 COMPLETE。

以下内容保留为已完成 Electron 重构的历史记录，不再授权新的实施边界。

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

## 2026-08-24 Dev CSV Worker 路径隔离

- Vite serve 为仓库根目录的兼容 CSV Worker 注入 `/@fs/` 本机模块 URL，点击
  “新建任务”清理 Worker 状态时不再请求不存在的 `/public/csv-worker.js`。
- Production build 注入空的 dev marker，继续从 Renderer HTML 相对解析已打包的
  `public/csv-worker.js`；不改变 file:// 加载路径、Worker 协议或 CSV 算法来源。
- 回归测试分别锁定 Vite dev 模块转换、HTTP Worker URL 和 production file URL，
  防止开发修复反向改变生产加载契约。
- 验证结果：Modern Vitest 15 个文件 47/47、Node 243/243、`npm run typecheck`
  与 production Renderer build 通过；产物无 `/@fs/` 运行时代码和额外 CSV
  Worker 副本，仍只引用 `../../public/csv-worker.js`。

## 2026-08-24 默认项目库短名称

- 部署后的本机默认目录改为 Application Support 下的 `Local SlateSync Library`，
  不再把便携包扩展名用于应用内部数据目录。
- 启动时只对两个已知旧默认位置执行原位重命名；若目录不可写则继续使用旧位置，
  用户导入或迁移的 `.slatesync-library` 路径不参与自动改名。
- 导入、导出和更改存储位置仍使用 `.slatesync-library` 便携包契约，不改变现有
  验证、安全边界或跨设备文件识别方式。
- 验证结果：Node 244/244、Modern Vitest 15 个文件 47/47、`npm run typecheck`、
  `npm run build:modern` 与 `git diff --check` 通过；未启动 Electron 前台窗口。

## 2026-08-24 项目库改名与导航交互

- 左侧导航栏“项目库”右键菜单新增“改名项目库”，主进程通过
  `renameLibrary` 同步更新 `library.json` 清单名称并原位重命名磁盘目录，
  随后持久化新 `libraryPath` 并重启应用（沿用导入 / 更换位置的契约）。
- 内置库目录无扩展名保持不加后缀，便携包改名保留 `.slatesync-library`
  后缀；SQLite 连接在 POSIX 目录改名后继续指向同一 inode，store 根路径同步
  切换以保持项目相对路径解析一致。
- 新增 `rename-library` IPC 通道并纳入 additive IPC 契约清单；Preload 暴露
  `projects.renameLibrary`，Renderer 提供改名对话框与名称校验（不允许路径
  分隔符等特殊字符）。
- 顶部栏副标题仅在工作台 / 项目设置 / 全局设置展示当前项目名；项目库页只
  显示“项目库”，当前项目名只由左侧导航栏“当前项目”区段维护。
- 项目库统计标题从“可用项目”改为“在线项目”。
- 验证结果：Node 246/246、Modern Vitest 15 个文件 47/47、`npm run typecheck`
  与 `npm run build:modern` 通过；未启动 Electron 前台窗口。

## 2026-08-25 侧栏项目上下文排布

- 补齐 Modern 侧栏分组标题的局部样式映射，使用既有间距、字体和颜色 token
  拉开“分组标题—导航项”的垂直节奏，避免标题紧贴选中卡片。
- “当前项目”与项目名改为上下两行：前者维持分组标签层级，后者回到正文字体；
  长项目名保持单行省略，并通过 `title` 提供完整值。
- 导航图标与文字间距由 12px token 提升到 16px token，折叠侧栏仍隐藏文字并
  居中图标，不改变路由、点击区域或窄屏导航行为。
- 验证结果：侧栏布局测试 4/4、Modern Vitest 15 个文件 48/48、
  `npm run typecheck`、`npm run build:modern`、`npm run build:storybook` 与
  `git diff --check` 通过；premium strict audit 为 0 findings，未启动 Electron
  前台窗口。

## 2026-08-25 项目库审查问题修复

- 已配置旧默认库与短名称目录同时存在时，继续使用设置中明确记录的旧库；只有
  目标无冲突时才原位迁移，避免启动后静默切换到另一份数据。
- 项目库改名先移动目录，再原子写入清单；目录移动失败时不再提前修改名称，清单
  写入失败会尝试恢复原目录，公开的 Library、Projects 与 SQLite 路径字段也随
  成功改名同步更新。
- 项目库页新增可见“项目库设置”按钮，通过共享 Dialog 提供导入、导出、更换
  位置和改名的完整键盘/触控路径；侧栏右键菜单继续作为专家快捷入口。
- 新增迁移冲突、目录改名失败和可见设置入口回归覆盖；改名表单错误由共享 Field
  关联到输入控件，保留 `aria-invalid` 与错误描述关系。
- 验证结果：Node 248/248、Modern Vitest 15 个文件 48/48、`npm run typecheck`、
  `npm run build:modern`、`npm run build:storybook` 与 `git diff --check` 通过；
  premium strict audit 为 0 findings，未启动 Electron 前台窗口。

## 2026-08-25 统一 PDF OCR-first 识别管线

- PDF 原始字节只在 Preparation Worker 内用于逐页栅格化；Renderer、Main 和
  RecognitionRequest 只传递有序 `imageDataGroups`，模型端不再接收原始 PDF。
- 每次视觉模型请求前必须等待本地 Vision OCR 或 PaddleOCR；OCR evidence 统一
  携带引擎、页码、模式、视图、文字顺序、置信度和归一化坐标，并与页面图片一起
  发送。可选 OCR 故障或零文字块降级为页面图片识别并显示“本地 OCR 不可用，已
  改用页面图片直接识别；识别精度可能下降。”；警告同时保留在实时进度、结果、任务
  OCR 摘要和诊断会话中，显式 required 模式仍阻止识别。
- 旧客户端提交 `pdfDataUrl` 时由 Main 在模型调用前返回 400；该拒绝路径仅用于
  防止历史请求绕过 OCR，不是新的模型输入能力。历史 baseline 文件保持不变。

## 2026-08-25 OCR-first 审查修复

- 识别横幅继续由语义 progressbar 暴露百分比，只有持久 OCR 降级警告使用 polite
  live region，避免多页任务把每次消息、百分比与页数更新排入屏幕阅读器播报队列。
- 诊断 stage 以顶层 `ocrEvidence` 作为唯一持久字段，request 快照不再保存同一份
  evidence；标准与高精度 primary/audit/review 路径遵循相同去重边界。
- 验证结果：Node 250/250、Modern Vitest 15 个文件 50/50、`npm run check`、
  `npm run typecheck`、`npm run build:modern`、`npm run build:storybook` 与
  `git diff --check` 通过；premium strict audit 为 0 findings，未启动 Electron
  前台窗口。

## 2026-08-26 JSON Schema 探针与 OpenRouter 模型目录分组

- 新增 Main 侧 OpenAI 兼容接口能力探针：只发送无图片的最小文本请求，按当前
  `OPENAI_COMPATIBLE_API_MODE` 支持 Chat Completions / Responses 两种 JSON Schema
  请求形态，并区分“接口拒绝参数”“返回内容不可解析”“探针结构匹配”三类结果；
  API Key、Base URL 与项目图片不进入 Renderer 请求体或项目持久化数据。
- 通过 `check-compatible-json-schema` IPC、Shared Contract、Preload 和全局设置页
  暴露“测试 JSON Schema”入口，保留旧版 Renderer 兼容适配器；探针响应不替代正式
  识别的 `records` 校验，只用于在本地模型调用前确认端点能力。
- OpenRouter 模型目录保留原有固定推荐模型，并将首组选到最多 10 个；剩余视觉模型
  以 API `owned_by` 或模型 ID 前缀提取供应商，统一渲染为供应商 `optgroup`，现代
  与 legacy Renderer 共用同一排序语义。项目设置与工作台均在切换 Provider 后加载
  实时目录，初次打开项目设置也会加载已保存的 Provider。
- 验证结果：JSON Schema / IPC / 模型发现 Node 定向测试 40/40、Modern Vitest
  16 个文件 52/52、`npm run typecheck`、`npm run check`、`npm run build:modern`
  与 `git diff --check` 通过；未启动 Electron 前台窗口。完整 baseline SQLite
  检查仍受当前环境 `better-sqlite3` Node ABI 不匹配影响，未将其记为通过项。

## 2026-08-26 Main 日志与应用内日志查看器

- 新增 `lib/app-logger.mjs`：Main 进程以纯文本按日写入
  `<userData>/logs/slatesync-YYYY-MM-DD.log`，文件 0600、目录 0700，保留最近
  7 天；追加写入串行化，日志目录不可写时只告警并吞错，不影响识别与应用退出。
- `electron/main.mjs` 记录启动、项目库路径、Renderer 加载/回退、初始化失败、窗口
  关闭和退出；`electron/ipc-handlers.mjs` 在 `recognize` 的单一进度汇聚点把每条
  进度 tee 到 `recognition` 分类日志，并记录开始、完成、取消、失败。销毁的 Renderer
  只跳过 UI IPC，不跳过本地日志。新增 `logs-read` additive 请求通道，Preload 通过
  `window.slateSync.logs.read` 读取结构化日志 DTO。
- Modern Renderer 新增“系统 / 日志”路由和 `LogViewerPage`：实时复用全局 recognition
  store 与 design-system Progress，日志列表支持级别/分类筛选、内联进度条、空态与
  3 秒轮询；从工作台切到日志页时保留正在进行的 recognition store，完成/失败状态仍
  可在日志页实时观察。未记录 API Key 或完整请求载荷，也未新增进度事件通道。
- 新增 `test/app-logger.test.mjs`、`test/recognition-logging.test.mjs` 与
  `test/refactor/ip-03-08/log-viewer.test.tsx`，更新 Electron IPC 与 Shared Contract
  契约测试；不执行 git 提交，不启动 Electron 前台窗口。
- 验证结果：`npm run check`、`npm run typecheck`、`npm run test:node`（267/267，含
  native SQLite 重建）、`npm run test:modern`（17 个文件 54/54）、`npm run build:modern`
  与 `git diff --check` 全部通过。

## 2026-08-27 回填预览列对齐修复

- 修复 Modern Renderer 回填预览的表头与虚拟行部分错位：由于虚拟表格的
  `<tbody>` 使用块级布局，列宽不再交给表头和表体分别自动推断；由同一组
  TanStack 列宽统一驱动 `<colgroup>`、表头、虚拟行和单元格，并将表格设为
  fixed layout。继续保留横向滚动、原生 table 语义、CSV 数据和虚拟行预算。
- `virtual-table.test.tsx` 新增表头、`colgroup` 与虚拟行共享列宽的回归覆盖；
  本次未改变 CSV 合并、编辑提交、Worker 或持久化契约。
- 验证结果：Modern Vitest 18 个文件、56/56 通过，`npm run typecheck`、
  `npm run build:modern`、`npm run check` 与 `git diff --check` 通过；按既有
  GUI 测试边界未自动启动 Electron 前台窗口。

## 2026-08-27 回填预览横向滚动恢复

- 修复固定布局后的回填预览只能纵向滚动问题：在滚动容器内增加承载列总宽度的
  `tableCanvas`，使宽表的固定元数据列真实参与横向溢出计算；`tableScroll` 明确
  使用 `overflow-x/y: auto`，短表仍可填满区域，长表可在原区域左右查看剩余列。
- 虚拟 `<tbody>`、表头与列宽契约保持不变；未改变 CSV 数据、编辑提交、Worker
  或持久化语义。组件回归覆盖同步检查 canvas 总宽度和所有列宽。
- 验证结果：Modern Vitest 18 个文件、56/56 通过，`npm run typecheck`、
  `npm run build:modern` 与 `npm run check` 通过；按既有 GUI 测试边界未自动
  启动 Electron 前台窗口。

## 2026-08-27 回填预览区域边界约束

- 修复宽表承载层的最小内容宽度向外层网格传播：工作区网格、主区、面板和表格
  框均显式允许收缩并限制在父区域内，避免回填预览面板超过用户屏幕边界。
- 保留 `tableCanvas` 的固定列总宽度，并将它放在宽度受限的 `tableScroll` 内；因此
  只有回填预览内部负责上下、横向滚动，外层面板不会被宽表撑开。
- 验证结果：`npm run check`、`npm run typecheck`、`npm run test:modern`
  （18 个文件、56/56）、`npm run build:modern` 与 `git diff --check` 通过；按既有
  GUI 测试边界未自动启动 Electron 前台窗口。

## 2026-08-27 侧栏主题控件与全局设置同步

- 左侧导航栏主题图标现在表示全局设置保存的偏好值：自动使用 Monitor，深色使用
  Moon，浅色使用 Sun；自动模式下 macOS 外观变化仍只改变实际渲染主题，不会把图标
  误显示成固定的浅色或深色设置。
- 侧栏主题控件按全局设置相同顺序循环 `system → dark → light → system`，并通过
  清晰的可访问名称说明当前偏好与下一步动作；全局设置同步将自动选项明确标为“自动 ·
  跟随系统”。
- 新增循环与标签单元测试，更新视觉基线脚本为直接选择显式主题，避免三态快捷控件受
  运行环境系统外观影响；不改变主题持久化键、CSS token 或项目数据契约。

## 2026-08-27 侧栏主题名称与折叠动效

- 侧栏展开时在主题图标旁显示当前偏好名称（自动、深色或浅色），折叠及窄屏时保留
  图标；控件的 aria-label/title 同时说明当前偏好和下一步动作。
- 展开/折叠使用共享 `--ss-motion-slow` 与 `--ss-ease-in-out` 过渡侧栏列宽、品牌文字、
  导航文字和主题名称；`prefers-reduced-motion` 下关闭这些过渡，不改变主题解析或持久化。
- 增加侧栏布局与动效静态回归断言；与本次无关的 Main/OCR/Preload 工作区改动保持原样。

## 2026-08-27 字体与背景层级优化

- 全局字体改用 macOS 原生优先的 SF Pro / PingFang 回退栈，并启用抗锯齿与可读性渲染，
  同时将共享按钮字重从 650 调整为 600，减少主题名称在侧栏中的视觉压迫。
- 深色模式采用石墨画布、侧栏、控件三层背景；浅色模式同步提供冷灰画布与控件层，
  主题快捷控件改用语义 control token，避免出现突兀的中性灰填充。
- 增加字体栈与明暗控件背景 token 的静态回归断言；保留自动主题解析和已有工作区改动。

## 2026-08-27 全局 OCR 能力可观测性

- 全局设置新增 Main 进程驱动的 OCR 路由卡：同时展示 Apple Vision OCR 与
  PaddleOCR 的启用、可用、运行模式和配置，并明确显示下一次识别实际优先使用的
  引擎及选择原因。
- 识别启动和公开配置共用 `lib/ocr/selection.mjs` 的优先级策略，避免设置页与实际
  识别分叉；默认自动模式在 macOS 工具链可用时优先 Vision，显式开启/必需模式按
  环境变量优先级处理。
- 新增类型化 `check-vision-ocr` IPC，直接运行与识别相同的 Swift Vision bridge 的
  `--check` 探针；不读取图片、不调用远端 Provider。PaddleOCR 继续使用现有 Python
  `--check` 验证并保存环境路径。本次是用户明确要求的最小、只读 IPC 扩展。
- 新增 Vision 路由、bridge 检查、IPC 和 public config 回归覆盖；未改变 OCR 证据格式、
  Provider 请求、项目数据格式或持久化语义。

## 2026-08-27 组件层级精简

- 共享 Surface 使用更低对比度的 `surface-line` 语义 token，减少面板与侧栏分隔线的存在感；
  accent/danger 表面保留轻量状态边界，不影响信息层级和可读性。
- 主题快捷按钮默认回到无边框、透明背景，仅在悬停/按下时显示冷色控件层；键盘焦点环
  继续由共享设计系统提供，保证发现性与无障碍导航。
- 增加 surface token 与静默主题控件样式的静态回归断言；保持自动主题、字体栈及并行 OCR
  工作区改动不变。

## 2026-08-27 导航图标与文字对齐

- 导航图标统一为 18px 的固定 flex 项，并显式使用 `display: block`；导航文字与主题
  快捷项共用 `1.35` 行高，避免 inline SVG 基线和字体行盒造成视觉高低差。
- 主题图标维持 16px，和名称文字使用同一垂直居中规则；不改变折叠宽度、主题状态或
  已有 hover/focus 交互。
- 增加图标尺寸、行高和导航 JSX 尺寸的静态回归断言；其他并行工作区改动保持原样。

## 2026-08-27 审查意见修复

- 将新增 `lib/ocr/selection.mjs` 的语法检查同步登记到
  `.codex/refactor/baseline/contracts/build.json`，恢复 baseline 与实时
  `package.json` 的一致性。
- 共享 Button 现在组合调用方 `className` 与基础样式，保留统一的尺寸、布局、焦点、
  disabled 和 busy 状态；新增注释说明该共享组件边界。
- `DESIGN.md` 已镜像运行时 `tokens.css` 的暗色字体、背景层级、控件状态和语义边界，
  并明确浅色主题继续由同名 token 映射维护。
- 验证结果：`npm run check`、`npm run typecheck`、`npm run test:node`
  （270/270）、`npm run test:modern`（18 个文件、60/60）、`npm run build:modern`、
  `npm run build:storybook`、premium strict audit 与 `git diff --check` 通过；
  `designmd lint` 因沙盒无法解析 registry.npmjs.org 未执行。

## 2026-08-27 全局设置覆盖 `.env.example`

- 全局设置页覆盖 `.env.example` 中全部非敏感配置：服务商 Base URL、OpenAI
  兼容接口参数、模型请求限制、Vision OCR、PaddleOCR、缓存路径与工作流路径；
  五个 Provider 的 API Key 继续通过同一页面的独立凭据入口配置，兼容 API 不再要求
  用户手动编辑 `.env`。
- 新增 `electron/global-settings.mjs` 的显式键白名单、枚举/URL/数值校验与默认值，
  通过 `get-global-settings` / `save-global-settings` 类型化 IPC 连接 Main、Preload、
  Modern Renderer 与 Legacy 回退页。保存请求只携带用户实际修改的脏字段，清空字段删除
  覆盖；这样不会把 `.env` 或内置默认值误写成持久化覆盖。
- 普通全局配置存储在 `<userData>/global-config.json`，带版本号，只写入已校验的非敏感
  覆盖项，采用临时文件 + 原子重命名 + `0600` 权限；API Key 保持在独立的
  `<userData>/provider-keys.json`，不进入全局配置、Project Library、任务数据或普通
  配置 DTO。全局配置按机器用户共享，不随项目库导入/导出；恢复默认只清除全局覆盖。
- 启动顺序为普通配置“全局设置 > 进程环境 > `.env` > 内置默认”，凭据为“独立本机
  密钥 > 进程环境 > `.env`”；运行中可刷新请求、OCR 和并发参数，工作流路径变化提示
  下次启动生效。旧 OCR 首次设置与新全局 `PADDLEOCR_PYTHON` 保持双向兼容。
- 更新 `.env.example`，补齐代码实际支持的 `PADDLEOCR_PROFILE` 与
  `VISIONOCR_TIMEOUT_MS`，并用回归测试锁定模板覆盖率、敏感项隔离、校验、文件权限、
  损坏恢复、IPC/Preload 契约和 API Key 配置行为。

## 2026-08-27 Renderer/Preload 版本兼容提示

- 全局设置入口在调用新增 IPC 前检查 Preload 方法是否存在；开发环境的 Renderer HMR
  若与旧窗口的 Preload 配对，会显示完整退出并重新启动的恢复指引，而不是暴露裸的
  `api.settings.getGlobalSettings is not a function`。
- Legacy 兼容桥同步执行同一类检查，并用回归测试锁定旧 Preload 的可诊断错误；README
  明确说明 Main/Preload 修改需要完整重启，避免只刷新 Renderer。

## 2026-08-27 工作台导出动作固定到顶部工作行

- 将“导出 Resolve CSV”从工作台内容标题行移动到应用壳层已有的 sticky 顶部
  `Toolbar`，只在工作台路由显示；按钮仍由共享 `Button` 提供禁用、处理中、焦点和
  键盘交互状态。
- `WorkspacePage` 继续独占导出业务闭包、当前识别设置、CSV Worker、表格编辑和
  错误处理，仅向顶部工作行注册稳定回调及实时 `canExport` / `processing` 状态，避免
  为移动按钮而复制 Resolve CSV 语义或改变持久化契约。
- 顶部动作容器允许在窄窗口换行，保持 sticky header 的自然高度，避免导出动作造成
  横向溢出或遮挡工作区内容；新增任务生命周期静态回归断言锁定按钮不回到页面标题行。
- 验证结果：Modern Vitest 18 个文件、61/61 通过，`npm run typecheck`、
  `npm run build:modern`、`npm run build:storybook`、`npm run check` 与
  `git diff --check` 通过；Storybook 仅报告沙盒无法写入用户目录的既存提示，未启动
  Electron 前台窗口。

## 2026-08-27 识别结果同步到回填预览

- Modern Renderer 将原始 Resolve CSV 与 Worker 生成的 `previewTable` 分开管理；识别
  完成、场记 CSV 合并、素材元数据更新及识别记录编辑后，均通过同一 CSV Worker 重新
  计算合成表并立即展示，导出和任务持久化仍以原始表为基准，手工稀疏编辑继续覆盖预览。
- 新增 `merge-preview` Worker 任务及过期响应保护，避免任务切换、清表或连续编辑时旧的
  合成结果回写；追加 Worker、合并算法和 Workspace wiring 回归覆盖。
- 验证结果：`npm run check`、`npm run typecheck`、`npm run test:node`（277/277）、
  `npm run test:modern`（18 个文件、63/63）与 `npm run build:modern` 通过；未启动
  Electron 前台窗口。

## 2026-08-28 全局设置布局、侧栏动效与 OCR 手动选路

- 全局设置将“访问密钥与接口”和“工作台外观”放入独立双列首行；条件式兼容接口与
  运行参数继续跨越整行，窄窗口恢复单列，不依赖动态卡片顺序维持布局。
- 侧栏收展收敛为一条共享列宽过渡；标签只做透明度与轻微位移，品牌 App Icon 保持
  固定轴线，导航图标用 transform 平滑归入折叠轨道。所有相关动效继续遵循
  `prefers-reduced-motion`。
- 本地 OCR 增加首选引擎选择，可在自动、Apple Vision OCR、PaddleOCR 与关闭之间
  切换。手动选择同步写入两套 `*_ENABLED` 并清除冲突的 `*_REQUIRED`，继续复用 Main
  的唯一 `lib/ocr/selection.mjs` 选路，不增加 Renderer 独立策略。
- OCR 引擎卡网格改为顶部对齐；展开 Vision OCR 参数只改变 Vision 卡自身高度，
  PaddleOCR 卡不再被同一网格行拉伸。
- 验证结果：premium strict audit 为 0 findings，官方 `designmd lint` 为 0 errors
  （保留 26 条既有 token/primary 映射 warning）；`npm run check`、`npm run typecheck`、
  `npm run test:node`（278/278）、`npm run test:modern`（19 个文件、67/67）、
  `npm run build:modern`、`npm run build:storybook` 与 `git diff --check` 通过。
  Storybook 仅报告沙盒无法写入用户目录的全局 settings；按项目约束未启动 Electron
  前台窗口。

## 2026-08-28 折叠侧栏图标统一中轴

- 侧栏品牌、主导航、收展按钮与外观按钮复用 `--ss-sidebar-icon-track` 网格轨道；
  桌面折叠态、响应式窄轨和移动顶栏分别按可用内容宽度调整轨道，图标均由首列自然居中。
- 移除导航和外观图标的局部 `translateX` 补偿，标签透明度变化不再参与图标定位；
  收展过程中品牌与各导航图标保持固定中轴，选中态底板仍使用完整可点击宽度。
- `DESIGN.md` 同步记录共享图标中轴和禁止局部位移补偿的持久设计规则；壳层静态回归测试
  锁定品牌、导航和底部控件消费同一轨道。
- 浏览器实测桌面展开、桌面折叠与 880px 窄轨：品牌、主导航、收展和外观图标中心均为
  `x = 38px`；320px 移动顶栏图标统一为 `y = 28px`，两种窄布局横向溢出均为 0。
  `npm run check`、`npm run typecheck`、
  `npm run test:modern`（19 个文件、67/67）、`npm run build:modern`、
  `npm run build:storybook`、premium strict audit 与 `git diff --check` 通过；
  `designmd lint` 为 0 errors，保留 26 条既有 token/primary 映射 warning。

## 2026-08-28 侧栏收展稳定项目排布与品牌返回入口

- 项目库卡片不再使用随主区域宽度实时换列的 `auto-fill`；改为 4 / 3 / 2 / 1 列窗口断点。
  同一窗口内收展侧栏时，项目保持原行列顺序，仅卡片轨道宽度随壳层平滑变化。
- 左上角官方 App Icon 改为原生按钮，提供“返回项目库”可访问名称、hover / active /
  `focus-visible` 状态，并复用侧栏“项目库”的 `leaveProject` 行为；识别进行中仍阻止切换并
  显示既有警告，不绕过工作区清理或并发保护。
- `DESIGN.md` 与 `UX-CONTRACT.md` 同步记录稳定列数及品牌返回契约；壳层测试锁定断点、
  语义按钮、键盘焦点和受保护路由复用。
- 浏览器实测 1280px 窗口：侧栏由 248px 收至 76px 时主区域由 1032px 平滑扩至
  1204px，前后均无横向溢出；从日志页点击品牌图标可返回项目库。`npm run check`、
  `npm run validate:modern`（19 个文件、68/68）与 `git diff --check` 通过。
- `global-settings.test.tsx` 显式引用 Node 类型，使 jsdom/Renderer 推断项目能够识别
  `node:fs/promises`，无需把 Node 全局类型引入 Renderer 生产配置；单文件 TypeScript
  检查与 Vitest 3/3 通过。

## 2026-08-29 识别任务跨日志页恢复与场记 OCR 增强

- 识别会话状态增加 `taskId` 与一次性 `resumeOnWorkspace` 交接标记；进度监听提升到
  `App` 生命周期，避免 Workspace 卸载后停止接收 Main 的进度事件。Workspace 离开到
  日志页时保留正在运行的识别、任务快照、图片输入、CSV Worker 和元数据；回到工作台后
  运行中的任务直接显示原进度，任务结束后按任务 ID 从 Main 重新载入权威结果并刷新任务列表。
  非日志路由仍释放大体积工作区数据；自动保存 / 请求准备的短暂 in-flight 窗口也纳入交接保护。
- 图片上传与 PDF 统一使用整页图 + 两张重复表头的核心字段局部放大图；快速模式仍只提交
  整页，精确模式复用全部视图进行 OCR、主识别和核心查漏。标识归一化只对无歧义的卡号/视频码
  补齐固定数字位宽，范围或畸形值保留原样；序列校正结果降级为需人工复核，避免静默猜测。
- 已新增状态交接、全局进度监听、图片多视图准备及标识归一化回归断言。
- 验证结果：`npm run typecheck`、`npm run check`、`npm run test:modern`（19 个文件、70/70）、
  `npm run build:modern`、定向 OCR/识别测试（58/58）和 `git diff --check` 通过；完整
  `npm run test:node` 为 279 项通过 278 项，唯一失败是既有 baseline 清单的
  `package.version` 漂移（实时 `0.2.0`、清单 `0.1.0`），本次未改动该配置。

## 2026-08-29 场记单预览放大查看与多页触控板切换

- 工作台场记单预览的每一页改为原生 `<button>`，点击、Enter 和 Space 均打开同一张大图；
  按钮名称包含文件名和页码，保留页码角标、可见 hover/pressed/focus 状态，并在预览标题下
  提示“点击页面可放大查看”。
- 大图复用共享 `Dialog`，新增 `wide` 尺寸以给文档保留更大的阅读宽度；关闭按钮、点击遮罩
  和 Escape 均可返回，Dialog 原有的焦点陷阱与关闭后恢复到触发缩略图的行为保持不变。
- 大图底部提供上一页/下一页按钮，Dialog 接收左右方向键；预览区域消费触控板的水平
  `wheel.deltaX`，以“整段 wheel burst 锁定 + 320ms 空闲解锁”合并一次连续手势，避免惯性
  尾部再次触发而跳过多页。垂直滚动与 Ctrl + wheel 的捏合缩放不拦截。
- 预览选中项同时记录页码和图片来源；任务切换、替换或清空场记单时若来源不再匹配，自动
  关闭放大层，避免显示已离开当前任务的旧图片。大图使用窗口高度上限和 `object-fit: contain`，
  并沿用现有浅色/深色语义 token 与 reduced-motion 规则。
- 已新增工作台预览静态回归与共享 Dialog `wide` / 局部键盘处理测试。`npm run typecheck`、
  `npm run test:modern`（19 个文件、73/73）、`npm run build:modern`、`npm run build:storybook`、
  `npm run check` 与 `git diff --check` 通过；未启动前台 Electron。

## 2026-08-29 项目进入自动加载历史任务与任务搜索

- 工作台在项目 ID 进入或切换时自动刷新任务摘要；首屏已有任务时保留旧列表并以
  `aria-busy` 表示同步中，首屏为空时显示“正在加载历史任务”，避免用户必须点击刷新才能
  看见历史记录。刷新开始时清理任务列表错误，失败时保留旧列表并提供重试入口。
- 任务栏增加原生搜索框，按文件名、任务 ID 或本地化状态实时过滤历史任务；筛选后重新计算
  TanStack Virtual 的行数并回到首行，零结果显示明确说明和“清除搜索”操作。搜索字段保留
  Escape 清除、可见焦点和键盘可操作性，沿用现有设计系统控件与页面 token。
- 新增 TaskRail jsdom 交互回归及工作台/任务生命周期静态断言，后续验证记录在本节。
- 验证结果：`npm run typecheck`、`npm run test:modern`（20 个文件、76/76）、
  `npm run build:modern`、`npm run build:storybook`、`npm run check` 与
  `git diff --check` 通过；Storybook 仅报告沙盒无法写入用户目录的既有提示，未启动
  Electron 前台窗口。

## 2026-08-29 四项任务生命周期审查修复

- 自动保存回传 Main 分配的任务 ID，并由识别请求优先使用；工作台即使在日志页交接期间卸载，
  也会继续更新同一草稿，不再因 `activeId` 尚未回写而创建重复完成任务。
- 任务状态记录 `loadedProjectId`：项目打开时的首个历史列表读取会被工作台复用，日志页或其他
  路由返回时仍会触发权威刷新；日志交接恢复完成后再次刷新任务栏摘要，避免停留在草稿/零进度。
- `normalizeVideoCode` 与 Resolve 的 `C0XX` 约束保持一致，`C115`、`C0115` 等超出范围的
  数字编号不再进入可匹配素材键；新增自动保存 ID、项目列表归属和编号边界回归测试。
- 验证结果：`npm run typecheck`、`npm run test:modern`（20 个文件、79/79）、`npm run check`、
  定向 Node 回归（83/83）、`npm run build:modern` 与 `git diff --check` 均通过；未启动
  Electron 前台窗口。

## 2026-08-29 PaddleOCR 全局路由一致性修复

- 修复全局设置中直接开启 PaddleOCR 时，旧的 Vision `enabled/required` 配置仍可能抢占
  识别路由的问题。Main 保存全局配置时把显式开启某个 OCR 引擎归一化为互斥路由，同时
  清除另一引擎的必需标记；Modern Renderer 的引擎卡片开关复用顶部首选引擎逻辑，保存前
  即同步两套开关。自动模式仍保留 macOS 上优先 Vision OCR 的原有行为。
- 新增全局配置、IPC 保存和 Modern 设置组件回归测试，覆盖“Paddle 开启后下一次识别不再
  选择 Vision”的配置链路；未修改 OCR 推理算法、模型请求或 Project Library 数据格式。
- 验证结果：`npm run check`、`npm run typecheck`、`npm run build:modern`、`npm run test:modern`
  （20 个文件、80/80）与定向 OCR/全局设置回归均通过。`npm run test:node` 为 281 项中
  280 项通过，唯一失败是既有 baseline `package.version` 漂移（实时 `0.2.0`、基线
  `0.1.0`），本次未改动该配置。

## 2026-08-29 日志目录快捷打开与工作台路由驻留

- 日志查看器的“本地日志”卡片新增文件夹图标；Renderer 只通过
  logs-open-directory 类型化 IPC 请求，Main 按需创建 0700 日志目录并交给系统
  文件管理器打开，不向沙盒 Renderer 暴露本地路径。
- 工作台实例在日志、项目设置和全局设置路由间保持挂载并隐藏，保留草稿、图片输入、
  CSV Worker、编辑数据和识别进度；离开项目库时仍清理工作区。返回工作台时先等待同一
  自动保存队列，再从 Main 读取活动任务详情并刷新任务列表，防止展示旧快照。
- 根据复审补齐隐藏路由边界：进行中的图片准备/压缩请求继续完成，准备服务在 Worker
  空闲后释放资源，回到工作台会取消延迟释放；图像裁剪取所有有效内容带的外包围范围，
  不因标题与表格间的留白丢失识别内容；日志目录按钮在旧 Preload 缺少新方法时显示
  完整重启指引，而不是暴露裸 TypeError。
- 新增日志目录 IPC、Preload/Shared Contract、日志页交互和工作台返回刷新回归覆盖。
- 本轮验证：npm run typecheck、npm run check、npm run test:modern（20 个文件、
  85/85）、图像预处理回归（5/5）、npm run build:modern、npm run build:storybook、
  Electron IPC 定向测试和 git diff --check 均通过。Storybook 仅报告沙盒无法写入
  用户目录的既有提示；未启动 Electron 前台窗口。

## 2026-08-30 PaddleOCR 参数预设、v6 模型与后台预加载

- 新增 `PADDLEOCR_PRESET=custom|performance|balanced|fast`。命名预设完整接管
  PP-OCRv6 模型、检测最长边、识别 batch、最低置信度和文字块上限；性能档使用
  medium/1280/4/0.05/不限，平衡档使用 small/960/8/0.10/256，快速档使用
  tiny/736/16/0.25/64。`custom` 或缺省预设逐字段保留既有手动设置，因此原有
  PP-OCRv5 只需选择自定义并保留 `PADDLEOCR_MODEL_VERSION=PP-OCRv5`。
- `PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN` 已加入全局配置白名单与 Shared Contract，校验
  范围为 320–4096；有效预设参数进入 OCR 状态、请求 payload、缓存键和 Worker 配置键。
  文字块/置信度仍是输出证据过滤，快速档截断继续使用均匀页面覆盖，避免只留下页面顶部。
- Python bridge 新增 `--server` 常驻模式、requestId 逐行协议和合成图片 warmup；同一
  模型配置只创建一个 CPU Worker。Main 在启动完成、OCR 设置保存或模型/预设变化后后台
  预热；识别等待同一 Worker promise，配置切换先排空活动任务再释放旧进程，退出时强制关闭。
  预加载失败不阻塞保存，One-shot runner 仍作为兼容回退；未新增 Renderer IPC 或改变
  OCR evidence、任务存储和 Provider 请求格式。
- Modern 全局设置使用现有 Graphite/indigo token、Field/Select 和焦点样式；命名预设下
  的受控字段只读，切换自定义会物化当前预设值，快速档显示复杂手写/低置信度文字可能
  减少的提示。Legacy 回退设置表同步登记两个新字段。
- 官方 Apple M4 端到端基准（PP-OCRv6 页面给出的 200 张图）为 medium 8.82 秒/张、
  small 3.07 秒/张、tiny 0.96 秒/张；该页面同时提示 v5/v6 评测集不同，准确率不作
  直接横向结论。本机现有缓存的 v5 balanced 单视图基线为：模型 ready 约 1.9 秒、
  识别约 3.851 秒、runner 约 4.457 秒、端到端墙钟约 5.949 秒；v6 权重未在本轮
  预下载，避免为三个档位重复下载，需在目标机器首次选择预设后记录冷/热启动与
  1/4/12 视图实测。
- `paddleocr_runner.py --check` 实测 Paddle 3.3.1 / PaddleOCR 3.7.0；新增预设解析、
  Worker warmup/配置切换/取消和设置页物化回归。最终验证结果记录在本节末尾，后续若
  改动 Worker 生命周期或参数优先级，必须同步更新本节与对应测试。
- 最终验证：`npm run check`、`npm run typecheck`、`npm run test:modern`（20 个文件、
  86/86）、`npm run build:modern`、OCR/全局设置定向回归与 `git diff --check` 通过；
  `npm run test:node` 为 286 项通过 285 项，唯一失败仍是既有 baseline 的
  `package.version` 漂移（实时 `0.2.0`、清单 `0.1.0`），本次未修改该无关基线。

## 2026-08-30 PaddleOCR 模型版本下拉与版本切换

- Modern 与 Legacy 设置均将 `PADDLEOCR_MODEL_VERSION` 改为 `PP-OCRv6（推荐）` /
  `PP-OCRv5（兼容）` 下拉选项；命名参数预设仍锁定其自身的 PP-OCRv6 版本，只有自定义
  模式允许手动选择版本。
- 自定义模式切换版本时自动清空旧版本的检测/识别模型覆盖，改用所选版本与性能档的默认
  管线；Main 与 Python runner 还会过滤已知的跨版本模型名，同时保留手填的自定义模型 ID，
  避免构造混合 v5/v6 管线。批量、置信度、文字块上限和检测边长不因版本切换被重置。
- 版本字符串在 Main/Python 边界统一为规范的 `PP-OCRv5` / `PP-OCRv6`；未来或本地版本
  字符串仍保留兼容能力，但设置界面只暴露已有默认模型映射的两个版本。
- 新增模型版本下拉交互、跨版本模型覆盖清理与 Main 配置解析回归；后续验证结果记录在
  本节末尾，若调整版本映射或下拉选项需同步更新设置页、runner 和测试。
- 最终验证：Modern 设置定向测试 6/6、OCR/全局设置定向 Node 测试 20/20，`npm run
  test:modern` 20 个文件 87/87、`npm run check`、`npm run typecheck`、`npm run
  build:modern`、Python AST/字节码检查和 `git diff --check` 均通过；完整
  `npm run test:node` 为 287 项通过 286 项，唯一失败是 baseline 的
  `package.version` 漂移（实时 `0.2.0`、清单 `0.1.0`）。

## 2026-08-30 系统说明页

- 在左侧“系统”分组新增“说明”入口和 `help` Renderer 路由；说明页不依赖项目上下文，
  从项目库、工作台导入/识别/校对/导出，到全局 Provider、模型和本地 OCR 配置均可直接
  查看。保留 Workspace 的隐藏挂载逻辑，不新增 Renderer IPC、任务存储或 Provider 请求格式。
- 说明页使用现有 Graphite/indigo 设计 token、`Surface`、`Field`、`Input`、`Badge` 和
  `Text`；左侧目录采用原生锚点，搜索只过滤本地章节。搜索、锚点、键盘焦点和窄窗口布局
  均在页面内完成，并为快速 PaddleOCR 预设明确提示 tiny/高门槛可能减少手写和低置信度文字。
- 内容与当前实现保持同步：Provider 列表及 OpenAI 兼容接口选项、Vision 路由优先级和参数、
  PP-OCRv5/v6、自定义/性能/平衡/快速预设、检测最长边、识别 batch、置信度、文字块上限、
  缓存、常驻 Worker 以及全局并行/超时/重试参数均有说明。后续增加设置字段或调整路由时，
  必须同步更新 `HelpPage.tsx` 与本节记录。
- 新增说明页渲染/关键词筛选回归和系统导航静态契约测试。
- 最终验证：`npm run check`、`npm run typecheck`、`npm run test:modern`（21 个文件、
  90/90）、`npm run build:modern` 和 `git diff --check` 均通过。

## 2026-08-30 复审意见修复

- PaddleOCR 数值配置将空白 `.env` 值视为未配置，`PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN=`
  因而保留自定义模式的 960 默认值，不再被错误夹到 320；新增对应配置回归测试。
- OCR 识别为排队、Worker 预热、识别和兼容性 one-shot 回退共用一个绝对截止时间；队列在
  调用方超时后仍保持串行占用，已开始的 Worker 超时会清理进程，排队尚未开始的任务不会
  误杀其他识别任务。回退只使用剩余预算，超时不再重新获得一轮完整 timeout。
- 说明页目录改为渲染当前可见章节；搜索或无匹配结果时不会保留指向已卸载 DOM 的失效锚点，
  并补充目录目标与筛选联动测试。说明正文移除额外的“安全提醒”提示，保持内容聚焦配置
  控件与使用方法。桌面端目录固定在正文左侧并在视口过矮时启用独立滚动；窄窗口回退为
  正常流式布局，避免遮挡正文。
- 本轮验证：`node --test test/ocr.test.mjs`（17/17）、说明页定向 Vitest（2/2）、
  `npm run check`、`npm run typecheck`、`npm run test:modern`（21 个文件、90/90）、
  `npm run build:modern` 与 `git diff --check` 均通过。

## 2026-08-30 PP-OCRv6 检测与识别模型下拉

- 当 `PADDLEOCR_MODEL_VERSION` 为 PP-OCRv6 时，Modern 设置页的检测模型和识别模型
  使用下拉列表提供 `medium`、`small`、`tiny` 三档，并保留“使用当前版本默认模型”选项；
  下拉旁仍提供可编辑的自定义模型 ID 输入，命名预设仍以只读方式显示其实际模型值。
- 自定义 PP-OCRv5 继续使用可编辑文本输入，避免破坏已有自定义模型 ID；PP-OCRv6 中
  已保存但不在内置列表的模型 ID 会作为“当前自定义”选项保留，也可以直接编辑为新的
  本地 ID。Legacy 回退设置表同步提供同样的下拉与自定义输入，并按规范化的模型版本切换
  控件；重绘设置组时保留用户当前展开状态。
- 选择下拉项会保存精确的检测/识别模型名称，Main 与 Python runner 的版本过滤和
  配置缓存会据此创建匹配的 PP-OCRv6 管线；说明页同步记录三档模型选择含义。
- 修改模型版本、模型列表或设置页交互时，必须同步更新 Modern、Legacy、说明页和
  `test/refactor/ip-03-08/global-settings.test.tsx`，并重新执行设置页与构建检查。
- 最终验证：Modern 全局设置测试 8/8、`npm run check`、`npm run typecheck`、
  `npm run test:modern`（21 个文件、92/92）、`npm run build:modern` 和
  `git diff --check` 均通过；Node 定向测试中的 OCR 相关 21/21 通过，另有既有
  `package.version` 基线漂移与本机 `better-sqlite3` Node ABI 不匹配未处理。

## 2026-08-30 全局设置标题文案

- 移除“全局设置”页标题下的冗长副标题，让标题区域保持简洁；配置说明统一放在
  左侧“系统 → 说明”页面中，未改变任何设置字段、保存逻辑或运行行为。

## 2026-08-31 多自定义 OpenAI 兼容接口

- 新增 Main 侧 v2 `global-config.json` 自定义 Provider 注册表；记录只包含名称、
  安全 Base URL、传输/JSON/图片模式、手动模型 ID、修订号和非敏感能力缓存。
  API Key 仍由 `provider-keys.json` 单独以 0600 原子写入保存，动态连接不会写入
  环境变量、项目库、日志或 Renderer DTO。
- 自定义连接使用 `openai-compatible:<uuid>` 稳定 ID，支持可选 Key 与任意数量模型。
  `/models` 结果分为可用、待验证和失败/不支持；待验证模型只能通过 Main 侧并发 2、
  30 秒带标记合成图片探针后进入项目选择器。修改连接或 Key 会递增修订并失效旧缓存。
- Modern 与 Legacy 全局设置均提供新增/编辑/删除、名称/URL 校验、模型发现、供应商
  分组、搜索、探针进度和取消；删除不改写项目数据库，旧引用保留并阻止识别直到重选。
- 评级只显示带依据和更新时间的维护模型族/实时价格参考，未知精度显示“暂无数据”、
  未知价格显示“价格未知”，不使用伪造默认分数。`OPENAI_COMPATIBLE_*` 与
  `openai-compatible/custom` 继续作为旧连接兼容别名。
- 最终沙盒验证：`npm run check`、`npm run typecheck`、`npm run test:modern`
  （21 个文件、92/92）、`npm run build:modern`、`npm run build:storybook`、
  premium strict audit（0 findings）和 `git diff --check` 均通过；Storybook 仅报告
  无法写入沙盒外的用户级 `/Users/rasteaks/.storybook/settings.json`，静态产物构建
  成功，未启动 Electron 前台窗口。
- `npm run test:node` 共 288 项，287 项通过；唯一失败是既有 baseline 的
  `package.version` 漂移（实时 `0.2.0`、清单 `0.1.0`），与本次自定义接口实现无关。
  自定义模型/能力/识别链路定向回归 55/55 通过；未为通过无关基线回退 v2 契约或
  新增安全边界。

## 2026-08-31 复审问题修复

- 旧版 `openai-compatible` 配置在物化前统一归一化传输协议和 JSON 模式；Responses
  与 `json_object` 继续映射为 `json_schema`，运行时注册表也会兼容修复历史快照。
  “恢复环境默认”会移除该迁移记录并清理对应模型注册，保留 UUID 自定义接口。
- Modern/Legacy 自定义接口发现使用最新请求令牌；切换、编辑或删除时丢弃旧模型发现、
  能力缓存和探针进度，晚到 IPC 响应不能覆盖当前 Provider。探针完成或失败后显式清理
  进度，并要求模型读取合成图片中未出现在提示词里的标记，避免文本接口伪造 Vision
  能力通过。
- Field 不再把 ID 克隆到原生布局 wrapper；PP-OCRv6 复合选择器保留唯一 ID 并保持
  `htmlFor` 指向实际 select。未知精度模型恢复排在已评分模型之后，避免“暂无数据”
  被误作推荐排序。
- 新增兼容配置、重置迁移、图像探针、未知评分和 PP-OCRv6 ID 唯一性回归；后续修改
  Provider 迁移、能力探针或 Field 复合控件时需同步更新上述测试和本节记录。

## 2026-08-31 DeepSeek v4flash Review 修复方案

- Responses 的 `json_object` 请求在 system prompt 中携带完整 `SLATE_SCHEMA`；凭据更新
  区分非空替换、空值保留和显式清除，Modern/Legacy 设置页清除 Key 时同步清理过期的
  `replaceApiKey` 状态。
- 自定义 Provider 和 legacy materialize 使用候选配置、Key 快照和 copy-on-write 提交；
  配置或 Key 保存失败时回滚磁盘、内存和 Key 状态，不留下 phantom Provider、孤儿 Key，
  也不阻塞同名重试。
- `discoveredRevisions` 保留 null 哨兵并严格匹配 revision；探针成功后刷新 discovery
  与 registered-model 缓存。`manualModelIds` 只保存用户输入，能力缓存保存当前 revision
  下实际探测过的 verified/failed/canceled 模型；取消项继续待验证但默认不选中。
- legacy alias 与真实模型按物理 `apiId` 合并并保留 `CUSTOM_MODEL_ID` 兼容引用；已
  materialize 的 Provider 只使用持久化模型 ID，不再回退过期环境变量。Legacy Renderer
  探针切换和晚到响应均基于当前 Provider 状态处理，不恢复旧搜索、选择或 probing 状态。
- 新增请求格式、Key 保留/清除、保存回滚、revision、探针缓存、legacy 去重/持久化和
  Renderer 状态回归测试；未新增 IPC channel 或凭据字段。修改上述链路时需同步更新
  `src/shared/contracts/index.ts`、Main/Renderer 测试及本节记录。
- 最终验证：`npm run check`、`npm run typecheck`、`npm run test:modern`（22 个文件、
  94/94）、`npm run build:modern`、`npm run build:storybook` 和 `git diff --check` 均
  通过。Storybook 仅报告沙盒无法创建用户级 `/Users/rasteaks/.storybook/settings.json`，
  静态构建成功。
- `npm run test:node` 共 302 项，302 项通过；历史 baseline 继续保留其发布时的
  `0.1.0`，测试改为校验当前 `package.json` 与 `package-lock.json` 的 `0.2.0` 发布版本
  一致性，本轮新增的回归测试均通过。

## 2026-08-31 按宿主系统选择打包目标

- 本地 `electron:build` 与 `electron:build:dir` 统一经过
  `scripts/electron-build-host.mjs`：macOS 主机显式传入 `--mac`，Windows 主机显式
  传入 `--win --x64`；Linux 主机和跨平台目标参数立即失败。
- `electron-builder.yml` 保留 macOS arm64/x64 的 DMG 与 ZIP，并新增 Windows NSIS x64
  目标；macOS 的 `bin/vision-ocr` 资源只进入 macOS 包，不进入 Windows 包。
- Windows ia32/x86/armv7l 不属于支持目标；GitHub Release 工作流仍使用 macOS runner，
  因而继续只发布 macOS。
- 最终验证：`npm run check`、`npm run typecheck`、`npm test`（Node 302/302，Modern
  23 个文件、97/97）、`npm run build:modern`、baseline 打包契约和 `git diff --check`
  均通过；宿主目标选择、Windows x64 固定和跨平台参数拒绝均有回归覆盖，未启动
  Electron 前台窗口，也未访问本地 `data/`。

## 2026-08-31 项目独立导出与项目库导入

- 项目包采用固定的 `.slatesync-project` 目录格式，包含
  `slatesync-project.json`、原格式 `project.json`、在线备份生成的 `project.sqlite`、
  `tasks/*.json` 和 `diagnostics/*.json`；v1 不生成 ZIP，不提升现有项目格式版本。
- `slatesync-project.json` 记录包版本、项目名称/描述、原项目 ID、创建/更新时间和
  `archivedAt`。导出允许活动、归档和默认项目；默认保存路径为 Downloads 下清理后的
  `<项目名>.slatesync-project`，目标已存在、同路径、嵌套路径或符号链接均拒绝。
- `lib/project-library-transfer.mjs` 负责包根目录、未来版本、JSON 快照、SQLite 完整性、
  所有权字段和符号链接校验，使用临时目录 + SQLite online backup + 原子重命名。在线备份
  副本切换为 DELETE journal，避免开放源连接产生的 WAL/SHM 临时文件进入固定包结构；导入
  在临时副本中重绑定新 `project-*` ID、当前 `libraryId`、项目元数据、任务/诊断数据库行和
  快照，保留设置、场记结构、时间戳、诊断与归档状态。
- 导入始终插入新项目库索引行，允许同名项目，不覆盖源数据；全局配置、Provider API Key、
  OCR 环境/路径、日志和项目库索引不进入包。索引写入失败时清理未登记目录，无法立即删除
  的目录改为启动时重试的 tombstone。
- 新增 `import-project` / `export-project` IPC、Shared Contract 的
  `ProjectImportResult` / `ProjectExportResult`、Preload typed gateway 与 Legacy bridge。
  两个操作与项目库整体传输共用独占锁，识别、自动保存、创建、归档、删除或其他项目写入
  期间返回 `LIBRARY_BUSY`。
- Modern 与 Legacy 项目库页面均提供顶部“导入项目”及活动/归档/默认卡片“导出项目”；
  成功后留在项目库刷新并 Toast，归档导入副本继续显示在归档区。离开工作台或开始项目库
  传输前等待 autosave flush；保存失败或识别进行中不会进入文件选择器，取消不改变状态。
- 更新 `UX-CONTRACT.md`、Modern Help、README 和本方案记录；新增 Node 传输、IPC、Preload/
  bridge、Modern 项目库回归，并补充 Legacy HTML/脚本静态契约。GUI Electron E2E 仍按既有
  约定仅在 Owner 明确要求时运行。
- 最终验证：`npm run typecheck`、`npm run test:modern`（24 个文件、102/102）、
  `npm run test:node`（305/305）、`npm run check`、`npm run build:modern`、
  `npm run build:storybook` 与 `git diff --check` 均通过。Storybook 仅报告沙盒无法写入
  用户级 `/Users/rasteaks/.storybook/settings.json`，静态产物构建成功；未启动 Electron
  GUI E2E，按既有 Owner 明确要求约定保留为后续验证。

## 2026-09-01 自定义接口注册表 UI 优化

- Modern Renderer 的自定义接口设置改为稳定的“注册列表 + 详情工作区”组合：左侧只负责
  选择接口，右侧按接口身份、连接能力、检测/探针动作、可用模型、待验证模型和失败项
  的顺序展示，继续复用 `Surface`、`Button`、`Badge`、`Field`、`EmptyState`、`Progress`
  和 `Spinner`，不新增业务状态或 IPC 通道。
- 移除该组件的内联布局样式，所有间距、选中态、键盘焦点态、警告提示、模型分组、搜索
  和窄窗口堆叠规则集中到 `src/renderer/app/app.module.css`，仅使用现有 `--ss-*` 语义
  令牌；加载态、无接口态、未选择态和探针进行态均有明确的可读反馈。
- 详情区新增协议/JSON/图片细节摘要、HTTPS 警告、能力状态 Badge、模型搜索清除动作、
  分供应商全选以及失败项独立重试；保存表单改为真实 `<form>`，API Key 显示切换补齐
  accessible label。共享 `EmptyState` 支持 feature-level className，但保留统一图标、标题、
  描述和 action 语义。
- 补充自定义接口注册表结构与 `aria-pressed` 状态回归断言；附带的图片仅作为视觉参考，
  不作为实现指令。Legacy Renderer 保持原有实现，Modern 仍是默认入口。
- 本轮验证：定向组件测试 2/2、`npm run typecheck`、`npm run check`、`npm run build:modern`、
  `npm run build:storybook`、premium strict audit（0 findings）和 `git diff --check` 通过。
  Storybook 仅因沙盒无法写入用户级 `/Users/rasteaks/.storybook/settings.json` 发出提示，
  静态产物构建成功。`npm run test:modern` 共 24 个文件、98/99 通过；唯一失败为工作区已有
  的 `legacy-project-library.test.ts` 静态契约仍查找不存在的 `import-project-button`，与本次
  Modern 自定义接口改动无关。

## 2026-09-01 项目包入口调整

- Modern 与 Legacy 的项目库首页不再直接显示项目包“导入项目”或卡片“导出项目”；卡片仍保留
  项目设置入口以及活动/归档状态操作。项目包操作统一收纳到当前项目的“项目设置”区域，继续
  复用现有 Button、Surface、Toast/状态文本和自动保存闸门。
- 从项目设置导入后刷新项目索引并返回项目库，不自动打开新副本；导出仍可用于活动、归档和
  默认项目，取消选择不改变状态。Legacy 同步移除项目库头部与卡片导出入口，并加入设置页
  的项目包状态反馈。
- 更新 Modern 组件测试、Legacy 静态契约、README、Help 与 UX-CONTRACT；项目包 Main/IPC/
  Preload 能力和目录格式保持不变。GUI Electron E2E 仍按 Owner 明确要求约定不自动启动。
- 最终验证：`npm run typecheck`、`npm run test:modern`（24 个文件、102/102）、
  `npm run test:node`（305/305）、`npm run check`、`npm run build:modern`、
  `npm run build:storybook`、premium `audit_project.py --mode strict --no-write`（0 findings）
  与 `git diff --check` 均通过。Storybook 仅报告沙盒无法写入用户级
  `/Users/rasteaks/.storybook/settings.json`，静态产物构建成功；未启动 Electron GUI E2E，
  按既有 Owner 明确要求约定保留为后续验证。

## 2026-09-01 DeepSeek Review comments 修复

- Modern/Legacy 的项目库导航和项目加载都加入递增意图令牌；异步 autosave、项目加载或导入
  完成后，只能提交仍属于当前路由/项目的结果。识别进行中、保存失败和跨路由完成的项目包结果
  统一写入可见共享提示区，不再把反馈写到隐藏页面。
- 项目包导入在索引刷新失败时保留 Main 已提交的项目行并提示稍后刷新，避免用户因看不到成功
  结果而重复导入；Modern/Legacy 的传输按钮、项目设置保存和整体项目库传输均正确释放忙碌态。
  Modern 项目设置检测未保存表单并阻止项目包操作，要求先保存，避免设置随成功跳转静默丢失。
- 传输层允许旧版损坏 JSON 快照作为不透明证据继续导出/导入，忽略中断留下的 `.tmp` 文件，
  同时继续拒绝符号链接和数据库行级损坏；导出只在暂存目录校验后原子提交，不再在提交后校验
  失败时删除用户目标，并复用已完成的导入校验结果。项目包扩展名比较改为不区分大小写，
  Windows 保留设备名改为安全前缀。
- 新增导航、刷新回退、未保存设置、旧快照/.tmp、混合大小写扩展名和 Windows 保留名回归；
  遵循项目注释约定补充了相关实现注释。最终验证：`npm test`（Node 306/306、Modern
  104/104）、`npm run typecheck`、`npm run check`、`npm run build:modern`、
  `npm run build:storybook`、premium strict audit（0 findings）和 `git diff --check` 均通过；
  Storybook 仍仅报告沙盒无法写入用户级 `/Users/rasteaks/.storybook/settings.json`，未启动
  Electron GUI E2E。

## 2026-09-01 打包版本地 OCR 引擎路径修复

- Vision OCR 与 PaddleOCR 都改为在实际调用时解析 Main 注入的 `SLATESYNC_PROJECT_DIR`，
  解决 Electron 静态 import 早于运行时环境初始化导致的路径失效；打包后分别对应
  `Resources/app/bin/vision-ocr` 与 `Resources/app/scripts/paddleocr_runner.py`。
- Vision 在打包环境只使用 `extraResources` 中的预编译 bridge，缺失时给出安装/重新打包提示，
  不会尝试向只读 App bundle 编译；PaddleOCR 仍可通过设置中的外部 Python/虚拟环境启用，
  不再被误认为只能使用 Vision OCR。OCR 选路、证据格式和 Renderer IPC 协议保持不变。
- 新增 Vision 打包 bridge 存在/缺失回归测试，以及 PaddleOCR 打包 runner 路径回归测试；
  增加 `SLATESYNC_PACKAGED` 生命周期标记，并同步更新设置页的 bridge 路径说明。

## 2026-09-01 打包版 PaddleOCR 一键安装

- 打包资源包含 `scripts/paddleocr_runner.py` 与 `requirements-ocr.txt`，不包含 Python
  解释器、PaddlePaddle 或 PaddleOCR wheel；用户只需准备 Python 3.10+，不需要手动创建
  虚拟环境。全局设置“本地 OCR”标题旁的安装按钮由 Main 进程完成环境创建、依赖安装和
  runner 验证，安装结果自动写入 OCR 设置与全局 `PADDLEOCR_PYTHON`。
- 安装目录固定为 Electron `<userData>/paddleocr-venv`，不写入只读/签名的
  `Resources/app`。安装器复用运行时资源路径，固定读取打包随附的依赖清单；支持 Python
  探测、venv 创建、pip 安装、验证、进度事件、取消（SIGTERM 后强制终止）、超时和失败重试。
- 新增 `install-paddleocr`、`cancel-paddleocr-install` 及 typed progress 事件，Modern 与
  Legacy 均复用同一 Preload gateway。安装未验证成功前不持久化路径，避免半成品环境把 OCR
  路由标记为可用；两套设置页都保留忙碌、成功、取消和错误重试反馈。
- 更新 `UX-CONTRACT.md`、README、打包清单和安装器/IPC/bridge/Modern 组件测试；不改变
  Vision/PaddleOCR 识别算法或 OCR 选路语义。验证需覆盖不下载依赖的安装器状态机、IPC
  持久化、双 Renderer 入口、类型检查、静态语法和 Modern 构建。

## 2026-09-02 Review comment 修复

- PaddleOCR 安装器与验证器的 Python 子进程只接收显式白名单环境变量；provider API Key
  等 Main 进程凭据不会再传入 venv、pip 或 `--check` 子进程，必要的 pip index/proxy
  与运行时路径仍会保留。
- 安装目录使用 `lstat` 并拒绝符号链接，继续把 venv/pip 写入范围限制在 Electron
  `userData`；验证阶段同时支持 AbortSignal 和外层取消兜底，取消不会被 120 秒健康检查
  超时拖住。
- Legacy 项目设置表单增加未保存脏状态：所有输入/选择和默认值重置都会标记草稿，项目
  包与项目库传输在保存前被阻止，传输收尾渲染不会覆盖未保存的 DOM 值；成功保存后才
  清除标记。
- 为环境隔离、符号链接边界、验证取消和 Legacy 脏表单契约补充回归覆盖；未提交、提交、
  推送、重置、清理或切换分支。

## 2026-09-02 修复 PaddleOCR 设置草稿与退出生命周期 Review comments

- Legacy 与 Modern 设置页都以 Main 的命名预设生效值渲染，并锁定预设拥有的模型版本、模型
  ID、批量和过滤参数；切换到自定义时物化当前预设，避免界面显示值与实际 OCR 管道不一致。
- PP-OCRv5/v6 的检测、识别模型覆盖按版本保存未提交草稿；切换版本时隔离不同代模型，切回
  时恢复原自定义 ID。两端均覆盖预设切换、版本往返和 Legacy 静态契约回归。
- PaddleOCR Worker 增加生命周期代数和应用关闭标记。强制关闭会立即终止当前 Python Worker、
  使排队 preload 失效，并在有限期限内等待队列收敛；Electron `before-quit` 先完成这次清理，
  `will-quit` 保留幂等兜底，避免退出后重新拉起孤儿进程。
- 最终验证：`npm test`（Node 316/316、Modern 109/109）、`npm run typecheck`、
  `npm run check`、`npm run build:modern` 与 `git diff --check` 均通过；未启动 Electron GUI E2E。

## 2026-09-02 分支审查问题修复

- 项目库改名现在与导入、导出和切换位置共用 Renderer 的识别拦截、autosave
  准备闸门和 busy 锁；Main 为项目库索引、信息和项目/任务/Profile 读取增加
  共享读租约。传输先禁止新读写，再等待已有读取排空；异常路径统一释放租约，
  保留项目删除既有的项目级读写排空。
- 新增 OCR 子进程环境白名单。PaddleOCR 检查、常驻 Worker、单次 Worker、
  安装器和 Vision bridge 均不再继承 Provider API Key 或任意 Main 环境变量；
  运行时只保留系统路径、临时目录、语言/locale、项目/缓存路径与必要代理，
  pip 安装才额外保留包源配置。关闭引擎会清除对应 `*_REQUIRED`，显式启用
  仍会互斥清除另一引擎路由，Renderer 与 Main 行为一致。
- AI 请求与模型发现将响应体读取纳入同一 AbortController deadline；响应体超时
  复用现有重试策略，最终统一为可读的 HTTP 504，并保留外部取消语义。新增
  路由标题映射、`document.title` 同步和中文初始 HTML 标题，项目名继续由顶部
  栏显示，避免项目库页面残留过期名称。
- 新增 `scripts/build-vision-ocr.mjs`，支持 `--arch arm64|x64|universal`，
  macOS 默认构建 universal，thin 构建后检查文件权限、架构和
  `vision-ocr --check` JSON 响应；electron-build-host、macOS release 脚本和
  GitHub Actions 均接入，Windows 保持 Swift 编译 no-op。同步更新 check 与
  build contract inventory。
- 回归覆盖读锁排空/异常释放、改名保存闸门、OCR 环境隔离与路由互斥、响应体
  超时重试/504、路由标题以及 Windows no-op/universal 构建验证。Node 测试
  323/323、Modern Vitest 118/118、`npm run check`、`npm run typecheck`、
  `npm run build:modern`、`npm run build:storybook`、`npm run test:native:abi`
  和 premium strict audit 均通过；Storybook 仅提示沙盒不能写入用户级
  `/Users/rasteaks/.storybook/settings.json`，静态构建成功。
- 本机真实 `node scripts/build-vision-ocr.mjs --arch universal` 已执行，但当前
  CommandLineTools 的 SwiftBridging module map 重复定义导致 Foundation/Vision
  编译失败；这是本机 SDK/toolchain 环境问题，不是源码检查失败。仓库已有
  arm64 bridge 的 `lipo -archs` 和 `--check` 均通过。安装完整匹配的 Xcode/
  CommandLineTools 后应重跑 universal 构建，脚本会在打包前阻断未验证产物。
- Windows 项目库改名的 SQLite 关闭顺序和 POSIX 目录改名假设按本次范围继续
  保留，作为后续专项遗留风险；本轮未执行 Windows 实机验证、Electron 前台 GUI
  或发布上传，也未提交、推送、重置、清理或切换分支。

## 2026-09-04 SM-03 Swift Migration implementation 与 Code Review 修复（等待用户确认）

### 施工方案与边界

- 本轮只实现 `.codex/swift-migration/packages/SM-03.md`：把
  `src/shared/contracts/index.ts` 的项目、任务、识别、OCR、场记、场景、模型发现、
  Provider、设置和日志 DTO 搬到 `SlateSyncDomain` 的 `Codable + Hashable + Sendable`
  类型；`JSONValue` 只用于未知字段/诊断边界，不作为已知业务合同的 `[String: Any]`
  替代物。
- `ProjectSettings`、Resolve 字段格式/注释、场景匹配和工作流配置在解码时补齐既有
  默认值并做版本、长度、范围、换行符校验；旧 CSV 快照的 `newline` 仍可读取，原生
  编码统一输出兼容的 `lineEnding`。
- 不实现 SM-04 SQLite schema/迁移、SM-05 CSV 引擎重写、SM-06 媒体/OCR、SM-07
  Provider 网络层或 SM-08 UI；Electron/React/Node/TS 兼容基线与 `.codex/refactor`
  历史证据保持不变。`CURRENT_STATE.json` 仍保持 SM-02 COMPLETE / next SM-03。

### 配置、数据根与安全决策

- `ApplicationSupportLocator` 的生产根继续是 macOS
  `~/Library/Application Support/SlateSync`，测试只能显式传入临时 root 或
  `SLATESYNC_TEST_ROOT`；项目库、`settings.json`、`global-config.json` 和迁移源均不
  指向测试机真实用户数据。目录权限为 0700，JSON 原子写入为临时文件 + rename，文件
  权限为 0600。
- 生效优先级固定为：调用点显式值 > `global-config.json` 有效覆盖 > 旧
  `settings.json.ocrPythonPath`（仅 `PADDLEOCR_PYTHON`） > 已存在的 process env
  （空值也遮蔽 `.env`） > `.env` > 内置默认值。全局 key 白名单、URL/枚举/数字范围和
  OCR 引擎互斥/required 清理均在 Swift typed validator 中执行；无效持久化值按字段
  忽略，不阻塞启动。
- `SlateSyncLogger` 使用 subsystem `com.slatesync.app` 的 OSLog；结构化 metadata
  先经过递归 redaction，API key、OAuth/token、Authorization、client secret、密码、
  cookie、Bearer/Basic 等不写入日志，path/request/task/session/diagnostic 标识采用
  private privacy。
- `KeychainCredentialStore` 以 `SecurityKeychainBackend` 为生产实现，以
  `InMemoryKeychainBackend` 为注入测试实现。旧 `provider-keys.json` 先严格解析并拒绝
  顶层重复 key，再逐条预检 Keychain：已有相同值只验证、不覆盖；冲突立即取消；新增
  值使用原子 create-if-absent 并取得不落盘的 ownership marker，再逐条 read-back 校验，
  任意失败只补偿本轮实际创建且仍匹配 ownership 的账户；只有全部验证成功才删除旧文件。
  删除失败会保留旧文件并返回无 secret 的错误，便于重试；文件删除还会校验原始内容和
  文件身份。该补偿仍是单次迁移调用内的 compensating transaction，不覆盖绕过协调锁的
  任意外部 Keychain 写入者。

### SM-03 Code Review 修复

- Provider 请求 DTO 恢复 `apiKey` 的 Codable round-trip；`CustomProviderConfiguration`
  仍是无密钥持久化 DTO，新增 `DomainResult<Value>` 对应 TS 的 success/error envelope，
  没有提前建立完整 `SlateSyncApi` 或接入 `SlateSyncApp` 启动编排。
- 新增 `CustomProviderValidator`，与 `lib/custom-provider.mjs` 对齐 ID、名称、Base URL、
  transport/JSON/image 枚举、模型 ID、revision 和 capability cache 规则；旧快照只发布
  经过规范化的有效记录，显式保存非法记录时抛出无密钥错误且不发布半成品文件。
- 配置目录/文件读取会修复为 0700/0600，原子写入失败清理临时快照；旧
  `provider-keys.json` 在读取前同样执行权限修复；`.env` 重复 key 采用首次出现优先。
- Keychain 补偿只处理本次实际写入的条目，并在删除前做值匹配；回滚失败返回
  `KEYCHAIN_MIGRATION_ROLLBACK` 并保留旧源。该语义是单次迁移调用内的 compensating
  transaction，不宣称跨进程绝对原子性；Provider ID 拒绝全部 C0/C1 控制字符。
- Xcode Test Plan 使用明确的 `-resultBundlePath`，Gate 在 xcodebuild 退出 0 或非零但
  result bundle 存在时读取 xcresult summary；断言/崩溃优先为 `FAIL`，UI runner 取消、
  Testing.framework 拷贝或沙盒环境错误为 `BLOCKED_ENV`，不再仅凭进程退出码记录 PASS。

### 本轮验证与未覆盖风险

- 最终 SwiftPM 验证为 39/39 通过，覆盖 shared fixture、请求 API key round-trip、
  无密钥持久化、DomainResult、Provider 校验/兼容别名、设置优先级、权限修复、显式
  `null` 删除、原子写入失败、递归日志脱敏、Keychain 冲突/重复 key/回读失败/写后失败/
  条件回滚/旧源保留，以及临时数据根隔离。`node script/tests/sm03_contract.mjs`、Gate
  helper 35/35、`git diff --check` 均通过。
- `npm test` 为 Node 323/323、Modern 118/118；`npm run check`、`npm run typecheck`、
  `npm run build:modern` 和 `npm run test:native:abi` 通过。Xcode Debug 构建通过，隔离的
  `SlateSyncTests` 为 1/1 通过；最终隔离完整 Test Plan result bundle 为 Unit/UI
  2/2 通过，Gate 也读取 summary 后记录 `xcode_test_plan=PASS`。Gate fixture 另覆盖
  exit-0 但 summary 失败、实际断言失败和 Testing.framework/runner 环境取消，并将后两类
  环境问题分类为 `BLOCKED_ENV`。
- dirty diagnostic Gate 在显式临时根
  `SLATESYNC_TEST_ROOT=/private/tmp/slatesync-sm03-review-gate-root-20260904d` 下运行，
  结果目录为 `/private/tmp/slatesync-sm03-review-gate-20260904d/SM-03/20260903T195846Z-c962e952ee08`；
  工件为 `overallResult=PASS`、`approvable=false`、`diagnosticDirtyWorkspace=true`。
  这是诊断证据，不是 Owner 批准或阶段完成；本轮未修改 `CURRENT_STATE.json`、
  `.codex/refactor`，未提交或推送。
- 受限 sandbox 中 SwiftPM 曾在 manifest 阶段报 `sandbox_apply: Operation not permitted`；
  在完整工具链权限下 `swift build`/`swift test` 通过。真实 Security.framework 登录钥匙串
  尚未在测试中读写；生产实现仍待后续启动/设置编排接入。当前完整 Test Plan 已通过，
  但不同 Xcode runner 若再次出现 signed `Testing.framework` copy 或 UI 取消，应保留
  `BLOCKED_ENV`，不得改写为 PASS。
- 所有失败注入和 fixture 均使用临时目录/内存后端，不读取或删除真实
  `~/Library/Application Support/SlateSync`；`npm audit` 已存在的依赖漏洞仍作为独立
  依赖治理事项保留，未修改锁文件；改动保持未提交，等待用户确认及独立审查。

## 2026-09-04 Sol review comments 修复（等待用户确认）

- 修复 Keychain 迁移的预检竞态：Security backend 使用原子 `SecItemAdd` 返回本次创建
  的 ownership marker，补偿删除将 marker 纳入条件并由服务级 sidecar `flock` 协调原生
  写入；旧 `provider-keys.json` 删除改为内容、大小、device/inode 快照校验，变化时保留
  源文件并返回 `KEYCHAIN_MIGRATION_SOURCE_CHANGED`。文档明确不宣称对绕过该协调机制的
  任意进程实现绝对跨进程原子性。
- 扩展日志字段/文本脱敏覆盖 refresh/id/oauth/auth/bearer token、client secret 和
  cookie 等常见 OAuth 凭据形态；补充 `.env` 缺失文件的 macOS `fileReadNoSuchFile`
  回退，避免首次运行误报配置错误。
- 新增共用 HTTP URL 规范化：按 JS URL 语义处理 scheme/host 大小写、默认端口和 `.`/
  `..` 路径段，并分别保留 custom provider 全量尾斜杠清理与 global setting 单个尾斜杠
  清理；capability cache 缺失/非法 revision 不再默认成当前 revision，错误的可选诊断
  字段只被忽略。
- 将 OCR、项目库和项目导入/导出/重命名结果改为带自定义 Codable 的 enum union，严格
  拒绝跨分支字段，保证取消与成功 wire shape 与 `src/shared/contracts/index.ts` 一致。
- Gate 在 xcodebuild 非零但存在 xcresult 时继续解析 summary；失败断言/崩溃优先于
  runner 文本，移除泛化的 `Testing.framework` 与 `encountered an error` 环境匹配，并
  增加混合失败、summary 取消和应用错误 fixture。
- 本次修复验证：`swift test` 46/46、`./script/tests/phase_gate_tests.zsh` 41/41、
  `node script/tests/sm03_contract.mjs`、`git diff --check` 通过；受限 sandbox 的
  SwiftPM manifest 仍因 `sandbox_apply: Operation not permitted` 阻塞，完整 Xcode
  toolchain 测试不访问真实用户目录或登录钥匙串。未修改 `CURRENT_STATE.json`、
  `.codex/refactor`，未接入 `SlateSyncApp`，未提交或推送。
- 未覆盖风险：真实 Security.framework Keychain 竞争者、不同 Xcode runner 的实际 UI
  取消/签名 framework 错误仍需在隔离环境观察；完整 Test Plan 若出现环境问题只能记录
  `BLOCKED_ENV`，不能替换为 PASS。`npm audit` 既有依赖漏洞继续作为独立治理事项。

## 2026-09-04 SM-03 全量问题修复实施（当前有效）

- 已按 SM-03 review 报告关闭全部 P1/P2/P3：旧任务缺失 `warnings` 的兼容解码、
  `providerId` Codable round-trip、Workflow 严格校验与 Project 设置宽容归一化、
  JS 数字/UTF-16/.env/Provider ID 兼容、HTTP(S) WHATWG 边界（含 IPv6 zone-id
  拒绝与空 userinfo 清理）、PaddleOCR 200 字符上限和动态 `paddlex` 默认值。
- 配置解析只保留 `GlobalSettingsResolution` 一套优先级实现；生产
  `ConfigurationResolver` 覆盖 legacy、空 process env、`.env` 和 dynamic root，
  并返回来源。非密配置权限修复失败回退默认值；密钥文件权限无法保护时拒绝读取并保留源文件。
- `SecurityKeychainBackend` 已成为生产运行时默认后端：使用 Application Support 下
  稳定 `.locks` 命名空间、有限等待、Data Protection Keychain、`AfterFirstUnlock`、
  service 常量、value + ownership marker 条件删除和 OSStatus 保留；旧凭据删除前
  复核 descriptor snapshot、device/inode、大小与内容。`CancellationError` 先补偿后原样
  抛出，`InMemoryKeychainBackend` 仅存在于 SwiftPM 测试支持目录。
- 新增 `SlateSyncRuntime` actor 与 secret-free `SlateSyncRuntimeSnapshot`，在启动时加载
  machine/global/`.env`、按来源解析配置并迁移真实 `provider-keys.json`；迁移失败不阻塞
  App 启动，保留源文件并在设置状态页提供重试。`SlateSyncApp` 已创建并 bootstrap
  `SlateSyncRuntimeModel`，`SettingsRootView` 只显示状态，不提前实现 SM-08 编辑工作流。
- Gate 分类顺序固定为真实断言/崩溃 > FAIL marker > BLOCKED_ENV marker > 环境文本，
  summary 只扫描诊断字段；`sm03_contract.mjs` 接受批准前后合法阶段状态并包含
  post-admission、PASS、混合失败和实现存在性夹具。所有新增代码路径均补充了边界注释。
- 当前验收已通过 SwiftPM 65/65、Gate fixture 52/52、Xcode Test Plan Unit/UI 2/2，
  以及 Node 323/323、Modern 118/118、typecheck/check、modern build 和 native ABI
  检查。真实 `SecurityKeychainBackend` 测试只使用随机 service/account 与独立协调目录，
  并在成功、断言失败和异常路径清理条目，不读取既有用户 Keychain 项。
- 本轮不修改 `CURRENT_STATE.json`、Electron/TypeScript 历史基线或 SQLite/CSV/OCR/
  Provider 网络实现；dirty diagnostic Gate 仅作为实现验收证据，正式 clean Gate、
  审查报告与 Owner 批准按治理流程继续执行。

## 2026-09-04 Sol 独立复审闭环（等待用户确认）

- 修复 Gate 的最后一处状态竞态：`xcodebuild` 与 `xcresulttool` 使用独立状态，
  因此在 `xcodebuild` 非零但 result bundle 可读时仍会先解析 summary；新增 exit-0
  summary 失败、非零可读断言失败、非零可读 runner 取消三条端到端夹具。
- 补齐 `HTTPURLNormalizer` 与 Electron WHATWG URL 的 authority 差分：IDNA/punycode、
  十进制/八进制/十六进制及压缩 IPv4、端口范围与前导零、HTTP(S) 反斜杠、编码点段、
  IPv4 尾点、IPv6 首个最长零段压缩和 IPv4-mapped IPv6 十六进制序列化；保留 `%2f`
  不被整体解码的安全边界。
- 最终验证：SwiftPM `swift test` 48/48、`CustomProviderValidationTests` 7/7、
  Gate helper 47/47、Xcode Test Plan 2/2、`node script/tests/sm03_contract.mjs`、
  `npm run test:node` 323/323、`npm run test:modern` 118/118、`npm run check`、
  `npm run typecheck`、`npm run build:modern`、`npm run test:native:abi`、shell syntax
  与 `git diff --check` 均通过。
- Sol 对当前未提交工作区进行最终只读复审，未发现 P0/P1/P2；原 7 条 review comment
  均已关闭，可交给独立 reviewer。隔离诊断 Gate 的技术检查通过；其退出码 3 只因
  `--allow-dirty` 将 `approvable=false`，不代表阶段批准或阶段完成。
- 本轮仍未修改 `CURRENT_STATE.json`、`.codex/refactor`；该复审阶段当时尚未接入
  `SlateSyncApp`，后续 SM-03 全量修复已完成最小 bootstrap 接线，
  未提交或推送；测试只使用临时目录/内存 Keychain，不访问真实用户目录或登录钥匙串。
  真实 Security.framework 竞争者及不同 Xcode runner 的环境行为仍是后续验证风险，
  `npm audit` 既有漏洞继续作为独立依赖治理事项。
