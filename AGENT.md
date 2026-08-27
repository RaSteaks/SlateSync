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
