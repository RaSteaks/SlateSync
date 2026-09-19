# SlateSync 当前项目方案

## 2026-09-19 CI 策略：功能门禁与非阻塞性能报告

- 按用户明确决定，将开发分支合并检查与性能预算分开：保留原 `native-test` 检查名称，调用 `phase_gate.sh SM-09 --functional`；构建、全部功能/数据断言、资源释放与虚拟化限制、Xcode UI、归档及打包仍阻塞合并。
- 功能模式只委托耗时预算，不删除混合测试中的业务断言；CSV 前台 FPS 用例由独立 `performance` 任务执行。该任务以 strict 模式运行原生表格、列表、SQLite 加载及 10k CSV 性能用例，原阈值不改，失败输出 warning、JSON、日志与 GitHub Summary，步骤和任务均非阻塞。
- 默认无参数的阶段 Gate 与 release workflow 保持完整严格验收。功能报告显式标注 scope=functional、performancePolicy=advisory、approvable=false；原生验收证据区分 FUNCTIONAL_ONLY 和委托用例，不制造完整 SM-09/发布批准。正常功能模式 PASS 返回 0；业务失败、环境阻塞和 dirty 诊断仍各自返回非零。
- 取消上一轮尚未提交的“全部性能继续阻塞但独立进程执行”方案，改用上述明确的门禁政策。添加策略回归：严格/功能预算区别、功能覆盖遗漏仍失败、无测试/无指标不能宣称性能 PASS、报告保留失败码，以及禁止主任务或 release 偷变成 advisory。
- 验证：功能模式完整 Swift 套件 387 项（2 项环境跳过）0 失败；135 项 Gate helper 自测、7 项策略边界测试、8 项 release contract 负例与原生功能静态契约通过。独立性能报告实际运行通过，生成 4 类指标 JSON、完整日志和 Summary；失败/无测试结果的报告路径通过 mock 验证，不把失败包装为 PASS。

## 2026-09-19 完整 UI 通过后的运行预算与诊断

- 运行 `35435508999` 的 Xcode Test Plan 已 15/15 通过，确认弹窗、设置缩放与完整外观/密度矩阵修正有效。归档、审计与 ZIP/DMG 也已通过，但打包后的完整 UI 矩阵尚未结束即触及原 30 分钟上限。
- CI 与 ad-hoc candidate 共用的作业上限调整为 45 分钟并同步静态契约，为完整 Debug/Release UI 与冷构建留出有限余量；不改任何业务测试/性能预算。CI 的失败诊断上传覆盖 canceled，使超时也保留原始日志。
- 同一类型 runner 的滚动帧率出现 58.28 与 33.63 FPS 波动；低值运行的空闲基线仍为 60 FPS，不能视为空闲环境不合格而放行。用临时 `codex/ci-perf-triage` 分支单独执行原 Release CSV 前台用例并采样主线程，主 PR 不引入诊断分支的精简流程。
- 调用栈采样主要落在 AppKit 文本字段图层绘制和布局。共享 CSV 字段显式关闭独立输入框 bezel 并限定一行显示布局，保留多行 field editor、原文和提交内容；新增原生多行插入/提交回归。对照运行 `35437399450` 在同一 runner 上依次测得 baseline 36.88/40.02/53.03 FPS，优化后 56.39/55.69/50.87 FPS；无采样器干扰，所有原阈值保持不变。该实验仍有先后顺序，最终以完整 CI 为准。
- 本地原生表格 9 项回归（1 项按环境跳过）0 失败，最终 Release 全量 386 项（2 项按环境跳过）0 失败，strict UI audit 0 findings；资源/原生静态契约、本地化审计、diff 检查、严格 Swift 构建和 Xcode 测试目标构建通过；隔离应用目检原生行选择、Return/Tab 编辑焦点及既有 CSV 恢复正常，最终 CI 待推送验证。

## 2026-09-19 macOS 26 UI 自动化复验

- 运行 `35434166066` 已通过完整 Swift 套件、资源契约、Release 性能、Universal 归档与 ZIP/DMG 回验。远端空闲 60.25 FPS、滚动 58.28 FPS；五次项目/任务选择峰值 54.94/44.03 ms，原预算均满足。
- 剩余失败定位到 UI 测试：全应用按钮查询命中 Touch Bar 的“仍要导出 CSV”，改为仅查询实际确认 sheet；窗口三点角拖拽在 macOS 26 圆角区域不命中 resize，改为工作区原点定位后分别拖动直边中点。
- 窗口尺寸仍精确断言请求值（受屏幕 visibleFrame 大小约束），保留 700×540 设置与 960×600 工作台缩放覆盖；不再从移动后的 window origin 推算高度，避免把 674 点可用高度错误算作 663 点。记录请求、支持尺寸、屏幕可用矩形和实际窗口矩形。
- 后续验证进行中；不声明完整远端 Gate 已通过。

## 2026-09-19 PR #6 远端 CI 修复

- 根据 GitHub Actions 运行 `35432288078` 的实际工件定位：帮助资源哈希过期连带阻断归档/打包，AppKit bridge 与窗口最小尺寸契约仍是旧结构；UI 测试点击已删除的独立导出入口，并假定 CI 显示宽度可达 1440 点。
- 当前资源清单同步帮助字节与哈希、补录 English.json，release contract 要求全部 UI 资源入册；不改历史 oracle、冻结夹具或旧验收凭据。原生桥白名单显式纳入现有窗口 chrome 与编辑屏障探针，保留严格边界检查。
- 旧库 UI 测试继续验证未匹配记录被拒绝导出，然后通过原生表格人工编辑、确认告警、统一导出验证精确 CSV 字节与输入保留；尺寸矩阵以实际屏幕可用宽度检查系统约束，并记录请求与真实尺寸。
- 使用 `/tmp/slatesync-ci-manual-export` 合成旧库和独立应用实测统一 CSV 导出：拒绝无效导出、Return/Tab 原生编辑、告警确认、保存均可用；逐字节核对人工 Scene 保留、原有 Shot/Take 原样、协议补充空 Comments 列及源文件不变。同步修正 XCUI 键盘进入编辑流程与完整输出期望；此人工实测不替代尚待远端执行的完整 UI 测试。
- 本地化仅对资源中已知模板缓存解析片段，未知输入不缓存，静态文案跳过解析；补充全资源双语与未知/越界占位符的独立参考实现对照测试，保留人工内容与单复数语义。
- 远端原始性能证据为空闲 60.45 FPS、滚动 33.02 FPS，五次列表选择峰值 123.25/127.86 ms；本机 macOS 15 Debug 基线滚动 118.61 FPS，未复现远端超标。Gate 的完整 Swift 套件改用 Release 交付配置衡量用户延迟，Debug 构建及 Xcode Test Plan 仍执行；所有测试、45 FPS / 120 ms 阈值、五次采样和前台资格检查保持不变。不能以本机通过代替 macOS 26 CI 结果。
- Release 完整套件发现并修复识别完成竞态：收尾期间先撤销操作 ID，等进度任务释放后再发布终态；cancel 仅接受仍持有 ID 的任务，避免完成被晚到取消改写、或看到成功后切换任务仍被旧 owner 拒绝。网络识别、本地 CSV 读取与结果生成共用相同收尾顺序。
- 本地验证：最终 Release 全量 385 项（2 项环境跳过）0 失败，识别/所有权 Release 定向 61 项通过，严格 Debug 构建、本地化审计、原生静态契约及 7 项负例、资源契约及 8 项负例、打包自测 16/16 通过。首轮完整 Gate 暴露的识别失败已定向及全量复测修复；本机 Xcode UI runner 启用 automation mode 超时，不能声明 UI 验收或完整 Gate PASS，远端 CI 待新提交复验。不沿用旧 SM-09 PASS 或 Owner 批准，不执行发布。

## 2026-09-19 PR #6 合并冲突修复

- 将 `origin/swift-rewrite` 合并至 `feat/swift/UI-improvement`；`AGENT.md` 顶部双方新增记录全部保留，不以任一分支覆盖另一方方案。
- 保留源分支 UI、本地化、CSV 数据保护与持久化改进，同时纳入目标分支 OCR 管道中断恢复、Gate 工具缺失处理及验收测试诊断；保留相关代码注释。
- 目标分支既有 SM-09 PASS 记录仅对应其原始审查提交，不代表本次合并已完成发布 Gate 或 Owner 批准。
- Gate 自测发现源分支本地化正则强制初始化及 OCR 测试未检查的并发声明违反现有规则；正则改为可失败初始化并保留原文回退，测试改为 MainActor 隔离，补充相应注释，不放宽检查。
- 验证：相关 Swift 定向测试 23 项、2 项环境跳过、0 失败；最终完整 Swift 测试 384 项、2 项环境跳过、0 失败；Gate helper 自测 134/134、本地化审计（637 调用点 / 1005 资源）、严格 Swift 构建与 diff 检查通过。本轮未执行 GUI 或完整发布 Gate。

## 2026-09-19 全量 Review 五项修复

- Resolve CSV 仅规范化成功匹配的识别字段，取消合并与正常编码中的全表改写；未匹配、冲突、不完整行保留原有内容，人工稀疏编辑在最终导出中原样保留。更新旧兼容字节期望，明确本次优先保障数据保留而非复刻旧版破坏性规范化。
- 外部项目包的 project_meta 逐项检查唯一键与非空值，重复键返回 INVALID_PROJECT_PACKAGE，不再触发 Dictionary fatal error。
- 设置投影、模型发现和识别协调器共用单一 ProviderRegistry，并合并动态模型到工作台列表；发现后发布界面 revision。能力验证原位更新相同版本 Provider 的资格，失败会撤销资格，保留无关发现结果且不取消其他窗口识别。配置/凭据修改仍失效旧资格，发现结果以 generation 拒绝迟到响应。
- 任务 patch 的读取、浅合并和 UPDATE 在 SQLite 事务及加密快照锁内一次完成；保留任务 ID、创建时间、未知字段和显式 null，缺失行不 upsert。任务保存、patch、删除共用跨连接锁，覆盖 SQLite 提交与兼容 JSON 写入/删除，避免迟到快照复活删除记录。
- 增加临时目录中的明文/加密跨连接 30 字段并发更新、删除后 patch 拒绝与重开、畸形项目包拒绝、CSV 保护及真实 façade 离线模型发现/验证/识别回归。不使用真实 Provider、钥匙串凭据或业务项目。
- 验证：完整 `swift test` 共 383 项，2 项按环境跳过，0 失败；`swift build -Xswiftc -warnings-as-errors`、本地化审计（637 调用点 / 1005 条资源）及 `git diff --check` 通过。跳过项为真实 Paddle 环境与前台显示节奏测试；未执行 GUI/发布 Gate。

## 2026-09-18 评审问题修复

- 原生识别开始前的任务所有权校验改为 SQLite 行存在性查询，只读取常量而不加载可能包含大图片与识别结果的完整任务 JSON；查询仍在 `ProjectRuntime` 项目租约内完成，缺失任务保持 `ENOENT` 语义。
- 诊断消息的动态本地化只匹配显式白名单中的领域/工作流模板，不再遍历全部通用 UI 文案，避免将项目名或文档内容误识别为界面操作文案。
- 增加大任务行存在性、缺失任务错误以及通用 UI 模板隔离回归测试。
- 验证：完整 `swift test` 377 项通过、2 项按环境跳过；最终本地化定向测试 7/7 通过，本地化审计 637 个调用点/1004 条资源无错误，`git diff --check` 通过。

## 2026-09-18 侧栏当前项目名称

- 左侧导航栏“当前项目”分组标题右侧展示该窗口已打开的项目名称；未打开项目时不显示占位，长名称单行中间截断并保留完整悬停提示。
- 名称复用窗口已有项目库与已保存项目设置状态：项目设置改名保存后即时更新，且不会把其他项目遗留的设置草稿显示到当前窗口。
- 增加 XCUI 项目创建流程断言，覆盖项目打开后侧栏名称的辅助功能标识与原文展示；继续保留原生 Section、选择与键盘行为。
- 验证：严格 Swift 构建、Xcode UI 测试目标构建、本地化审计、strict UI audit 与 diff 检查通过；聚焦 XCUI 创建/打开/重开项目流程 1/1 通过。

## 2026-09-17 全局 OCR 环境检测

- 全局设置 OCR 页提供手动检测、进度、取消和逐项结果，覆盖 Vision 当前语言/级别或自定义程序、Python 3.10+ 版本/架构/实际路径、Paddle 运行脚本，以及 paddle、paddleocr、cv2、numpy、pip、venv 的真实导入状态。
- 检测通过运行时原有优先级解析当前草稿，不保存配置、不安装依赖、不创建 OCR 模型实例；模型权重、设备与推理能力需实际识别验证。未配置 Python 时检查本机候选并明确提示尚未配置；显式路径失败不静默回退。
- 复用有超时和取消回收的子进程执行器，过滤 Provider 凭据与 pip 镜像配置，不展示第三方原始输出；安装与检测按钮互斥。设置编辑后标记结果过期，重装后清空历史结果，退出时取消并等待检测收尾。中英文文案和代码注释同步补齐。
- 验证：22 项 OCR/设置/运行配置/本地化定向测试通过；严格 Swift 构建、Xcode Debug 构建、本地化审计、strict UI audit 和 diff 检查通过。隔离应用实测 Vision、Python.framework 自动发现（3.12.7）、依赖缺失、低版本 Python（3.9.13）和编辑后过期提示；未安装依赖或验证模型实际推理。


## 2026-09-16 审查确认问题修复

- 加密 SQLite 的缓存依据改为完整已认证密文字节，取消仅凭 stat 时间戳/大小/inode 信任内存的路径；load 返回实际认证的 envelope，save 返回实际落盘的 envelope，统一缓存资格并移除重复头部读取。初始化也统一使用规范化 URL。每次访问会读取密文，连接额外保留一份密文，以换取不依赖文件系统时间戳精度的一致性；保留解密与反序列化缓存。此方案仍以合作写者遵守跨进程锁为前提，不承诺与任意不加锁写者并发操作的原子性。
- DiagnosticsStore 导入先排除已有 ID，重复快照不再导致无效加密重封；任务和诊断导入在目录无 JSON 时直接返回，避免全表 ID 查询。缺失快照仍按内嵌 ID 恢复，已有 SQLite 数据保持权威。不采用 total_changes 通用跳过保存，避免丢失 DDL/PRAGMA 修改。
- project bootstrap 从自身 CREATE DDL 推导表/索引名单，移除重复手写名单与 11 魔数；未知语句形式回退执行 DDL，保留完整 schema 不写库与缺失索引恢复行为，不变更 v1 user_version 协议。
- WorkspaceView 在任意布局保存屏障期间接收分段请求，成功后应用最后一次点击，失败恢复原页；保留外部导航入口原有重试语义。移除已无调用方的 ResolveCSVModel.standaloneData，底层导出协议不变。
- 新增加密快照等长原地替换（保留 mtime）后写入保留外部内容、诊断重复重开字节不变/缺失快照恢复/已有记录不覆盖、缺失索引恢复不丢任务测试。81 项持久化与工作台定向测试通过；bootstrap 最终修改后 27 项持久化定向复测通过，swift build -Xswiftc -warnings-as-errors 与 git diff --check 通过。未在粗粒度文件系统挂载卷上实测，也未做 GUI 点击复验；原地替换测试不宣称固定 ctime。

## 2026-09-16 运行日志筛选栏错位修复

- `LogsView` 的空状态显式撑满剩余宽高，与原生日志 List 保持一致的布局占位；首次无日志或筛选无结果时，筛选栏保持在标题栏下方，不再随内容整体居中下移。
- “级别”原生菜单按固有尺寸显示，剩余横向空间交给尾部 Spacer，避免菜单横向拉长；保留现有筛选、刷新与日志轮询行为，并补充布局注释。
- 验证：严格 Swift 构建、Xcode Debug 构建及隔离启动通过；UI strict audit 0 项发现。macOS 隔离实例已目检空日志、有日志、分类筛选无结果、清除筛选和级别菜单展开；筛选栏位置稳定。未覆盖 macOS 26 原生玻璃路径。

## 2026-09-16 全软件英文适配（取代帮助单独语言设置）

- 按用户更正，将语言归为应用级偏好，通用设置提供简体中文/English，帮助取消独立选择；旧 `helpEnglish` 不再决定语言。应用启动时读取隔离正确的偏好 suite，同步 SwiftUI locale 与原生 `AppleLanguages`；更改后提示重启，不重建当前编辑会话。
- 新增 `L10n` 与 English.json 统一覆盖界面、菜单、设置、辅助功能、进度与错误显示。编号占位符支持英文词序且不再次解析参数内容，常见计数处理英文单复数；内建 Provider 描述翻译，用户自定义名称保持原文。
- 持久化错误、日志事件、用户项目/任务名、识别原文、提示词、CSV/Resolve 协议、条次状态及导航 rawValue 不随界面语言改写；底层产品消息仅在呈现时匹配已知完整模板，未知第三方/系统消息原样显示。
- 新增语言持久化、帮助中英文、占位符/中文用户内容保留、错误显示与 Provider 名称边界测试，以及中英往返 XCUI 用例；`script/audit_localization.py` 检查 UI 字面量与英文文案占位符。
- 验证：完整 SwiftPM 360 项（2 项环境跳过）通过；后续 6 项语言专项测试通过；632 处文案调用/982 条资源审计与 strict UI audit 无发现，git diff --check 通过。最终 Xcode 应用构建通过；测试目标也已构建通过。XCUI runner 启用 automation mode 超时，未执行用例，不能记为 UI 自动化通过。已用隔离应用直接检查英文帮助、侧栏、菜单、通用/Provider/OCR 设置、项目创建、工作台、中文项目名保存，以及重启回中文和语言保存提示。实际业务数据与真实凭据未用于验证。

## 2026-09-16 多任务项目打开与列表性能

- 加密 SQLite 在跨进程锁内检查设备、inode、大小及纳秒修改/变更时间；文件未变时复用已认证的内存连接，首次查询也复用打开结果。其他连接提交、原地修改、迁移路径变化或操作失败均触发重新读取；旧明文/WAL 输入不启用该缓存。
- 已具备完整 v1 表与索引的项目跳过无效 schema 写入；空事务不再重新加密整个数据库。任务兼容导入先读取已有 ID，跳过重复序列化与插入，继续解析旧快照的内嵌 ID，保留文件名不一致时的恢复能力。
- WorkspaceModel 仅在任务集合或搜索词变化时更新筛选结果及可选行；TaskRailView 直接使用缓存投影，减少选择、进度与保存状态变化时的全量筛选。保留原生 List、稳定 ID、选择反馈和保存屏障。
- 新增跨连接更新、失败脚本回滚恢复、原地损坏/删除、加密项目重复打开不改写、旧快照恢复及 1,000 任务搜索切换回归；性能计时使用隔离合成项目，不读取真实项目。
- 验证：完整 SwiftPM 套件 352 项、2 项环境跳过、0 失败；兼容性与首次查询缓存修正后专项复测 81 项、0 失败；最终严格告警构建、五次计时回归及 `git diff --check` 通过。原生 UI 静态契约审计 0 项发现，未运行真实项目的 GUI 端到端计时或 Instruments。
- 本机 Debug 合成基准（32 个任务，每个含 64 KiB 图片字符串；重新创建任务存储、读取列表并恢复一个任务，五次中位数）：优化前 HEAD 22.477 ms，最终版本 7.285 ms，约 3.1 倍。仅代表这一持久化加载路径与样本，不代表整个项目窗口、冷磁盘启动或 Release 性能；兼容快照的读取和 ID 校验仍随任务数增长。


## 2026-09-16 工作区分段切换闪烁修复

- 输入 / 识别结果 / Resolve CSV 的原生 Picker 同步记录待切换选项，避免异步保存期间读回旧值导致选中指示回跳。
- 内容页仍在编辑与保存屏障成功后切换；保存期间连续点击合并到最后一个选项，失败则恢复当前页选中状态并保留编辑内容。
- 重复点击已选中项不再触发保存与布局切换；辅助功能选中值跟随选择器反馈。
- 验证：严格 Swift 构建通过；工作区所有权、原生编辑表面及工作台组件共 67 项测试，1 项显示时序测试按环境跳过，0 失败；UI strict audit 与 diff 检查通过。本轮未在运行中的应用内做闪烁视觉复验。

## 2026-09-16 移除独立导出入口

- Resolve CSV 页面移除“独立导出…”按钮及其专用点击处理，保留“合并识别结果”和统一的“导出 CSV…”入口。
- 现有 CSV 导出校验及底层独立 CSV 生成能力保持不变；本次仅精简界面入口。

## 2026-09-16 Provider 保存后返回

- 内置 Provider 配置及本次请求的 API Key 更新全部成功后，自动关闭配置弹窗并返回上一层设置界面，与自定义 Provider 的保存行为一致。
- 校验失败、保存失败或仅部分保存成功时保留弹窗、输入和错误提示，便于修正后重试。

## 2026-09-16 全局配色调整

- 共享 SlateSyncTheme 改为冷灰阶梯（微蓝调 slate）底色与单一钨丝琥珀强调色，覆盖两个外观模式；
  同日更早的暖石灰 / 鼠尾草方向在提交前被本方案取代，未留下中间提交。
- accent 亮 / 暗用 #B45309 / #F59E0B；canvas #F6F7F9 / #1E2229；evidenceSurface #FFFFFF / #2A2F37。
  成功、警告、错误分别采用松绿 #1E7A5A / #7FC9A9、黄铜 #7C6A00 / #E3C36B、砖红 #B03A2E / #E58873；
  保留文字与图标语义，不以颜色独自表达状态。
- warning 从赭金系移到黄铜：新 accent 为琥珀（色相约 28°），旧赭金（约 33°）与其明度相近，
  警告行会与选中行混淆；黄铜（约 50°）拉开约 22° 色相。状态三色整体从暖土系转为冷调系以贴合冷灰底。
- SettingsRootView「重启生效」提示由系统 .yellow 改为 SlateSyncTheme.warning，消除唯一的
  游离状态色字面量。SlateBadge 黑白斜纹、TakeMark systemGray 铅笔与黑色阴影 / 遮罩 / 径向渐变
  为既定豁免（内容性标识，以及任何色板下均为黑色的阴影效果）；PreparedImageEncoder 白底属
  图像处理非 UI；App 图标（build/slatesync.icon 蓝色渐变）为对外品牌资产，本次不动，留作后续选项。
- DESIGN.md 与运行时颜色同步；原稿像素、系统原生选区与文字保持原有所有权。
  `.claude/ui-design/design-system.md` 与其 README 的靛蓝旧色板章节同步到本方案（此前已过期）。
- 第二轮（同日应用户反馈）图标中性化：琥珀不再用于全体图标。侧栏（含底部全局设置/
  外观/密度按钮）、工具栏普通按钮与菜单、项目库行座标、`SlatePageHeading` 页首座标、
  帮助步骤圆点、日志信息点与全部空态图标改为中性次级灰（`.tint(Color.secondary)` 或
  `.foregroundStyle(.secondary)`）。琥珀仅保留在主操作按钮（`slatePrimaryActionStyle`）、
  搜索框焦点描边与进行中信号（LeaderProgress、tab 未读点、OCR 定位胶囊）。
  `SettingsRootView` 表单控件与分段选择器保留 accent tint（焦点/选中语义）。
- 第三轮（同日应用户反馈）：深色中性阶整体提亮脱离纯黑（canvas #0F1115→#1E2229、
  evidenceSurface #1A1D23→#2A2F37），改善文字与灰底的对比；设置窗口改铺
  `SlateSyncTheme.canvas`（原为系统窗底灰，不参与主题）；设置分类分段控件不再包
  `.control` 玻璃卡片——分段控件自带原生 bezel，双重描边在深色下呈黑框。
  `.claude/ui-design/design-system.md` 中性阶梯同步提亮。
- 验证：`swift build -Xswiftc -warnings-as-errors` 通过；`swift test --quiet` 347 项、
  2 项按环境跳过、0 失败；`git diff --check HEAD` 通过。accent 与三类状态色对画布和证据面
  共 16 组（token × 外观 × 背景）对比度全部 ≥ 4.68:1，其中 dark accent 图形为 6.27:1–7.43:1。
  运行中界面已按浅色 / 深色两种外观截图目检（`script/build_and_run.sh --verify` 启动，
  项目库视图）：冷灰画布、纯白证据面、中性图标与琥珀单点强调符合预期，原生选区仍为系统蓝。
  目检时登录钥匙串对重建二进制弹出 `com.slatesync.local-project-encryption` 授权框
  （签名 ACL 失配或钥匙串锁定所致，与配色改动无关，未代为应答）；项目库主数据目检改用
  `SLATESYNC_TEST_ROOT` 隔离实例完成。macOS 26 原生玻璃合成仍需 macOS 26 环境补充截图验收。

## 2026-09-15 Liquid Glass review 修复

- 两份 review 去重为 6 项：修复中性状态色、增强对比度动态刷新、配置面板竖向分隔、凭据胶囊形状与冗余描边、项目库摘要底色层级及搜索框重复描边。
- 共享适配层通过 NSWorkspace 的 accessibilityDisplayOptionsDidChangeNotification 更新视图状态；边框支持默认、仅辅助功能及调用方拥有三种策略。
- 凭据徽章保持胶囊，默认不添加自定义描边；搜索框与配置面板分别保留自身焦点边框和全不透明分隔线。librarySummary 使用 canvas 回退，与 evidenceSurface 列表保持区别。
- review 中“减弱透明度时仍为 0.34 边框”不符合源码（实际为 0.72 / 1pt），但同色层级问题成立；徽章问题是圆角不足，并非直角矩形。
- 本轮验证：arm64 与 x86_64 严格构建通过；`swift test --quiet` 347 项、2 项跳过、0 失败；`git diff --check HEAD` 通过。当前运行系统为 macOS 15.7.3，未进行系统辅助功能开关的人工交互验收或 macOS 26 原生玻璃视觉验收。

## 2026-09-15 Liquid Glass 全界面适配

- 新增 `Sources/SlateSyncUI/Components/SlateGlass.swift`，以 `SlateGlassRole`、
  `SlateGlassContainer`、`slateGlassSurface` 和 `slatePrimaryActionStyle` 统一
  macOS 26 Liquid Glass 与 macOS 15–25 material/语义色回退。
- 项目库摘要、工作台页首/配置面板/识别进度、状态条、帮助/日志控制区、全局设置分类器、
  Provider 状态面板和主操作按钮已接入；原生侧栏、工具栏、Settings、Sheet、CSV
  `NSTableView` 与灯箱证据区域继续由系统或高对比表面拥有。
- 适配只改变视觉层，不改变业务、数据格式、导航、保存屏障或项目库错误处理；自定义玻璃
  遵循单容器采样规则，禁止对大型列表逐行添加玻璃。
- Reduced Transparency 使用不透明 Slate 表面；Increase Contrast/Differentiate Without Color
  加强边界；Reduced Motion 不启用交互玻璃动态。macOS 26 原生玻璃需要在 macOS 26 环境补充截图验收，
  当前 macOS 15 已通过严格 Swift 构建、347 个测试（2 个既有环境测试跳过）、Xcode Debug 构建启动，
  并冒烟检查项目库、帮助、日志和全局设置回退路径。
- 本轮代码注释、`DESIGN.md` 与 `UX-CONTRACT.md` 同步记录该视觉契约；此前隔离启动的
  `file is not a database` 保持为独立问题，不在本轮处理。

## 2026-09-14 Slate Workbench 实施落码（第一轮）

- 新共享组件落 `SlateSyncUI/Components/WorkbenchComponents.swift`：`SlateBadge`（场记板斜纹身份左缘）、
  `TakeMark`（待定空心点 / 过·保铅笔圈 / 废条油笔划线，确认描边 240 ms，遵循减弱动态）、
  `LeaderProgress`（真实页码进度表盘，总数未知显示命名阶段，减弱动态退化为原生进度条）、
  `LightTable`（灯箱证据容器，控制件留在相邻栏）、`CredentialChip`（凭据四态）、`WarnRow`（告警行）。
- `SlateSyncTheme` 增补圆角 Token：smallRadius 6 / controlRadius 8 / panelRadius 12 / largeRadius 16
  （`.continuous`）；`SlateSearchField`、项目库图标底座、设置模型校验面板共 5 处裸 8 pt 圆角改为 Token。
- 工作台：三段 tab 上方叠加“有新内容”圆点（识别结果 / Resolve CSV，Picker 保留当前选中值并通过
  `accessibilityHint` 提供未读文案，访问后熄灭）；识别进行中输入页显示 LeaderProgress 卡片（页数来自 workflow 流）；
  状态栏“识别完成”分支新增“查看识别结果”动作，`WorkspaceEntryPoint` 增加 `.result`，已挂载时经既有
  guard 换页（过编辑屏障）；原稿对照表格单元格不动，在结果页表格上方加 TakeMark 汇总条（过/保、废条、待定计数）。
- Resolve CSV：`ResolveCSVModel` 加性保留最近一次合并诊断 `lastMergeDiagnostics`（导出字节路径不变，
  canonical re-merge 冻结合同不动）；新增三类告警徽章条与内联详情（WarnRow，封顶 8 条，不筛选/重排表格）；
  存在未解决告警时导出先经确认对话框（返回校对 / 仍要导出）。
- 外壳：侧栏底部新增外观循环（跟随系统→浅色→深色）与密度切换图标钮，与设置场景共享
  `@AppStorage("appearance"/"density")`；设置 Provider 行凭据状态改用 `CredentialChip`（四态映射不变）。
- 与原型的有意偏差（已记录）：不做行点击→原稿翻页映射（DESIGN.md 冻结“翻页不暗示行页对应”）；
  TakeMark 不写入 canonical NSTableView、不提供表内状态循环（SM08 表格身份/IME 冻结合同），仅表外汇总；
  告警徽章点击展开详情而非过滤行。
- 验证：`swift build -Xswiftc -warnings-as-errors` 通过；SwiftPM 全量 346 项测试通过、2 项按环境跳过、
  0 失败（含新增 WorkbenchComponentTests 3 项与 SM08 所有权/原生表格、导出回归等既有合同）。

## 2026-09-14 Workbench review follow-up

- 未读结果/Resolve CSV 标记提升到窗口级并按任务 ID 保存；切换任务或项目不会串用旧圆点，离开工作台期间完成的操作也会在返回后保留提示。
- 识别完成状态携带结果所属任务；任务切换会清理旧完成动作，状态栏只允许打开当前任务的有效结果。
- 工作区路由提示仅在保存屏障成功后消费；已有布局变更时排队，失败后保留提示并提供重试。
- Resolve CSV 导出先运行 canonical merge，再依据完整的未写入记录诊断决定是否确认，并缓存同一份导出字节供用户确认后保存；Picker 保留当前页 VoiceOver value，把未读提示放入 hint。
- 验证：`swift build -Xswiftc -warnings-as-errors` 通过；`swift test --quiet` 通过（347 项，2 项按环境跳过，0 失败）；`git diff --check HEAD` 通过。

## 2026-09-14 新版 UI 方案收敛与 Figma 预览

- 新版界面统一为单一 `Slate Workbench` 主题；深色/浅色只是同一语义 Token 的外观 mode，
  不再维护第二套视觉语言或独立色板。
- 圆角沿用 `DESIGN.md` / `SlateSyncTheme`：small 6pt、control 8pt、panel 12pt、large 16pt，
  SwiftUI 自定义容器使用 `.continuous`；功能视图不得写局部 RGB 或 7/9/10pt 圆角。
- 保留 `NavigationSplitView`、原生 `List`/`Picker`/`NSTableView` 与 macOS Settings 场景；
  异步反馈统一由 `SlateStatusBar` 承载，识别完成不自动抢占当前页面，以 Tab 圆点和状态栏动作引导查看结果。
- 灯箱只承载真实场记单证据，页码/缩放/导入控件放在相邻控制栏；片场痕迹按场景单点出现，避免主题化过度。
- Figma 预览按 `Foundations → Project Library → Workspace/Input → Results → Resolve CSV` 建立，
  Figma 变量只镜像 SwiftUI Token，不替代运行时主题来源；预览目标为 `朱煜天's team` 中现有的
  `codex` draft，当前先完成 Light 预览，同时按 Light/Dark 可切换的语义结构组织 token，
  不另建第二套文件。
- 本轮仅优化设计文档与方案记录，未修改 Swift 运行时代码；SwiftUI 继续保留 Light/Dark 自适应，
  Figma 当前先交付 Light 画板，Dark 作为后续 mode 补齐。当前 Figma Starter MCP 调用额度已耗尽，
  文件已写入基础 token，语义 alias 与页面画板待额度恢复后继续。

## 2026-09-13 Keychain 状态查询与加密 SQLite 恢复

- Keychain 凭据状态查询使用配置为 `interactionNotAllowed` 的 `LAContext`，保持状态刷新不弹授权框，并兼容当前 macOS SDK 的严格告警构建。
- 真实钥匙串探针与生产查询共享同一非交互认证上下文，并显式链接 `LocalAuthentication`，避免回归覆盖验证过时的 API。
- 加密 SQLite 只使用内存连接；已加密主快照在迁移或直接打开时，均在数据库协调锁内清理可能由中断快照替换遗留的 `-wal`、`-shm` 和 `-journal` sidecar，避免明文页残留。
- 增加加密数据库残留 sidecar 的迁移与直接打开回归测试。
- 验证：`swift build -Xswiftc -warnings-as-errors` 通过；SwiftPM 全量 343 项测试通过、2 项按环境跳过、0 失败；加密专项 9 项测试全部通过；临时钥匙串探针通过三次独立读取、重签名拒绝、属性查询、锁定与恢复场景。

## 2026-09-12 侧栏品牌图标

- 左上角品牌区使用 NSApplication.shared.applicationIconImage，跟随应用打包图标。
- 以原色、32×32 pt 等比显示，替换 film.stack.fill；不复制图标资源或施加主题染色。
- 验证：swift build 与 git diff --check 通过；不更改导航与业务行为。

## 2026-09-12 场记工作台 UI 重设计

- 在已有未提交界面上增量实现，保留当前业务模型、项目/任务选择与保存屏障。
- 增加共用 SlatePageHeading / SlateCountLabel；项目库固定概览与原生滚动列表分层。
- 侧栏加入品牌和全局设置入口；任务栏增加标题、真实数量及文字+符号状态；
  工作区统一任务标题层级，保留输入/识别结果/Resolve CSV 的原生分段选择。
- 所有颜色复用 SlateSyncTheme，间距复用 SlateSyncDensity；已为新增组合与行为边界添加注释。
- DESIGN.md 同步记录新构图；本轮验证结果见 docs/ui-redesign-2026-09-12.md。


## 2026-09-11 启动、识别与运行性能优化

- 项目库启动统计对已有 tasks 表使用只读连接，避免每个加密项目执行无效 schema 写入和重新加密；未初始化的旧数据库保留原初始化回退。
- 历史任务列表在 SQLite 内投影名称、状态、时间和记录数，不再向 Swift 返回全部图片/CSV/识别内容；保留空 editedRecords 优先、异常数组回退、原有排序及完整持久化格式。
- 识别后处理预计算物料排序键与继承排序键，保留稳定排序及卡号语义；场次正则只编译一次，跨页共享只读实例。
- 预览仅缓存当前页 NSImage，识别进度及布局刷新复用它，换页/换素材时更新；缓存属于视图，不跨窗口共享。
- 新增大图片列表旧新一致性、加密统计文件不改写、2,000 条识别排序兼容回归。性能测量使用隔离合成数据，不使用真实项目或外部模型请求。
- 验证：严格构建通过；完整 `swift test` 330 项、0 失败、2 项专用环境跳过；补充识别回归 8/8（包含完整套件后新增的排序测试）及启用前台 Gate 的原生表格 8/8 通过。离线实际 Paddle 模型测试未运行。
- 本机 Debug 单次样本（24 任务，每个含 512 KiB 图片字符串）：旧完整读取/Swift 解析 30.202 ms，SQLite 摘要投影 5.106 ms，约 5.9 倍；两者结果逐字段一致，完整任务图片仍保留。该样本不代表端到端启动、云端识别或 Release 性能。
- Xcode `testPreviewPagingPreservesResultSelection` 首次在文件面板等待超时，其他测试结束后单独重跑 1/1 通过；保留首次失败事实，不将其隐藏为始终稳定。未修改文件面板或放宽断言。
- 本轮临时测试库由 UI 测试 teardown 清除；构建目录、截图、结果包及日志均清理，仅保留源码与文字验证记录。未提交、未推送。


## 2026-09-11 历史任务选择反馈修复

- TaskRailView 同步记录点击的 pendingSelection，原生 List 在保存/加载挂起时维持目标行高亮，避免旧 selectedTaskID 回写造成新旧行跳动。
- 挂起期间忽略选择回声；成功后使用已提交的任务 ID，失败后恢复原行并保留 WorkspaceModel 的错误反馈。未提前替换编辑数据或绕过保存屏障。
- 验证：语法解析与 `git diff --check` 通过。严格构建、UI 目标构建及 Ownership 测试均被当前持久化层编译错误阻挡（SQLiteDatabase.swift 并发发送检查、LocalProjectEncryption.swift 异步迭代检查），未宣称运行回归通过；未改动这些无关文件。

## 2026-09-11 项目打开反馈

- AppSessionModel 在首个 await 前发布窗口独立的项目名称，统一工作区/项目设置打开入口，加载期间忽略重复打开请求。
- WorkspaceModel 按保存草稿、等待操作、读取列表、恢复任务、读取配置及完成切换发布阶段；保留全部保存屏障及成功后原子发布规则。
- AppRootView 在禁用内容之外显示原生不确定进度条与阶段说明（`project.opening.progress`），成功或失败均清除；不显示虚假百分比。
- 本轮改善等待反馈与重复请求，不声称数据库加载耗时降低；实际性能优化仍需对慢项目分阶段测量。
- 验证：`swift build -Xswiftc -warnings-as-errors` 通过；`swift test --filter SM08OwnershipTests` 55/55 通过（含新增反馈生命周期、重复打开、窗口隔离和保存失败测试）。本轮未运行 Xcode UI 测试或新增截图；临时构建/测试日志已清理。

## 2026-09-11 原生 UI 与外观优化

本轮在当前 Swift UI 分支实现“精致原生专业工具”方案，保持 macOS 15、
1440×900 默认主窗口与 960×600 最小窗口。UI 层不更改业务、持久化、
文件格式或发布主线。

- 工作台使用大预览、300 pt 可收起配置面板；900 pt 为内容区内联/覆盖切换点。
  保留三个工作页，元数据扫描移到 Resolve CSV，结果支持独立翻页的原稿对照。
- 任务栏与辅助面板通过几何/可见性变化保持列表和结果编辑器身份；
  WorkspaceEditorBoundary 先拒绝中文组合输入，再调用现有 workspace.flush。
- SlateSyncTheme / SlateSyncDensity 统一深浅色、状态、间距与 30/24 pt 表格行高；
  密度更新不 reloadData，编辑期间延迟到完成后应用。
- SlateStatusBar、SlateEmptyState、SlatePanelHeading、SlateSearchField 统一跨页表现；
  设置窗口改为默认 780×620、最小 700×540。DESIGN.md 与 UX-CONTRACT.md 同步维护。
- 验证使用临时项目库和确定性场记图像，不读取用户项目或真实凭据。
  新增原生表格密度/组合输入回归与 UI 外观、密度、尺寸、对照截图矩阵。
- 最小尺寸按原生窗口外框计算；窗口探针测量标题栏，避免 600 pt 内容区
  实际撑高为 652 pt。设置使用原生分段分类和可滚动表单，保留系统设置窗口，
  避开 macOS 15 特殊 TabView 宿主的固定尺寸。探针测量标题栏并补齐设置窗口
  缺少的原生 resizable 标志，不改变窗口位置、恢复或 SwiftUI 尺寸约束。
- 工作台统一持有素材、CSV 与目录选择面板，避免同一宿主的多个 fileImporter
  相互覆盖；CSV 解码、导出字节契约和安全作用域读取仍走原有模型。

验证结果记录于 `docs/ui-refresh-validation.md`：严格告警构建通过；Swift 全量
322 项、1 跳过、0 失败；完整 11 项 UI 测试通过，补充双页 PDF 与最终矩阵 2 项通过。
40 张窗口截图及万行表格复用、编辑、前台滚动指标已归档。960×600 外框实测通过；
1440×900 宽图受当前屏幕工作区限制，实际约 883–885 pt 高，未冒充全尺寸验收。

## 2026-09-16 CI 修复重新进入待验收

- 按 Owner 请求将本次修复冻结为独立候选提交，SM-09 当前状态为 REVIEW_READY；旧 COMPLETE 批准及验证完整保留在 CURRENT_STATE.json.history，当前批准字段清空，不伪造新提交 PASS。
- 补齐同阶段 REVIEW_READY Gate 入口；仍拒绝 IN_PROGRESS 自行准入、跨阶段准入和沿用历史批准，只有 COMPLETE 才核验批准新鲜度。
- 新增 5 项待验收状态回归；候选提交的正式 Gate 在临时独立工作树运行，避免其他未跟踪 UI/本机文件影响 clean-worktree 校验；最终证据追加到 `.codex/swift-migration/reviews/SM-09.md`。
- 本次仅处理源码与 CI 验收，不含真实库、发布、推送或历史批准重写。

## 2026-09-15 swift-rewrite CI 修复

- 已 fetch 并确认目标分支最新仍为 `82a664c4f0253fbaef4c290be7262768dcf7d70c`；GitHub 运行 `34500064568` 的失败步骤确为共享 SM-09 Gate。工作区从干净的 UI 分支切换至 `swift-rewrite`，未修改其他分支。
- CI 在 Gate 前显式安装/验证 ripgrep，并上传前台 CSV JSON。必需工具缺失时列出全部缺项、停止后续检查、记录 `NOT_RUN`，保留失败摘要；缺少 Python 时仍能由 shell 写摘要。扫描故障仍按失败处理。
- OCR 新增关闭 stdin/stdout 后延迟 600ms 退出的合成子进程模式；修复前定向测试实际返回 `OCR_PROTOCOL`。管道错误分类改为最多 1 秒的异步退出协调，保留原 deadline/取消，已确认的 EPIPE/EIO/EOF 中断可触发监督者原有最多一次 one-shot 恢复。非法哨兵协议不进入该分类路径。错误诊断只含 errno、写入字节计数、EOF、退出观测及分类，不含请求正文。
- 前台 CSV 同窗口增加 2 秒空闲基线及系统/显示帧率证据，空闲不达标明确报告环境不合格并继续失败，滚动阈值仍为 45 FPS。Release CSV 增加解码/合并/编码阶段采样；没有调整算法、哈希或性能阈值。
- 定向验证：严格 Swift 构建通过；Gate 自测 124 项、打包自测 16 项通过；OCR 10 项、1 项专用离线 Paddle 环境跳过、0 失败（包含原失败用例及新增竞态）。缺少 rg 的真实入口模拟退出 1，JSON/摘要保留，未执行依赖检查。
- 本机环境 macOS 15.7.3、Xcode 26.3 (17C529)、arm64。前台合成 10k 行空闲 120.160 FPS、滚动 118.758 FPS。Release 基线 5k/10k 中位 0.749898/1.500247 秒；阶段计时复测 0.758354/1.515169 秒、10k 最大 1.521344 秒，哈希及业务断言通过。10k 解码约 0.015 秒、合并 1.384–1.394 秒、编码 0.109–0.113 秒；暂无本机持续超标证据，不做推测性优化。
- 原始定向日志保存于 `/tmp/slatesync-{ocr-regression,release-baseline,release-stages,foreground,gate-self,package-self,strict-build}.log`，显示 JSON 位于 `/tmp/slatesync-foreground-metrics/`。
- 首轮完整 Gate 的冻结夹具哈希检查发现新增故障模式改动了历史字节，现已恢复夹具，改为仅在临时运行时注入；新增回归再次通过。首轮 Xcode 旧库 CSV 测试在完整文件路径 Return 已提交面板后仍等待确认按钮，现兼容自动提交与显式确认两条路径，仍要求面板关闭、导入业务结果及精确导出字节。打包 Release 9 项 UI 场景已通过修正后的测试。
- 最终验证（2026-09-16）：第二轮完整 `./script/phase_gate.sh SM-09 --allow-dirty --results-dir /tmp/slatesync-ci-fix-gate` 所有检查 PASS；SwiftPM 321 项、1 项专用离线 Paddle 环境跳过、0 失败；Xcode Test Plan 11/11、打包 Release UI 9/9。Release 构建、Universal/签名、归档、依赖审计、ZIP/DMG 生成回验及清理全部通过。最终严格构建和 `git diff --check` 通过。
- 最终 Gate 性能：5k/10k 中位 0.733203/1.474190 秒，10k 最大 1.484113 秒、比例约 2.011；空闲 120.267 FPS、滚动 118.416 FPS；原阈值与输出哈希保持不变。完整证据在 `/tmp/slatesync-ci-fix-gate/SM-09/20260915T155558Z-82a664c4f025/`，首轮失败证据保留在同目录的 `20260915T154622Z-82a664c4f025/`。
- 限制：这是未提交工作区诊断，Gate 总结果 PASS、`approvable=false`（诊断退出码 3），不代表新提交的正式批准或远端 CI 已通过。没有提交、推送、部署或发布；GitHub runner 的性能复验及是否需要专用 Mac 尚无新证据。执行期间出现的其他未跟踪文件未修改。测试使用合成数据及既有临时 Library 流程。


## 未来目标与分支治理（当前有效）

### 架构职责

- `main` 继续作为 Electron 主架构分支，维护现有 Electron 产品与其兼容行为。
- `swift-rewrite` 是当前 Swift/SwiftUI 原生架构的开发基线，也是现阶段项目开发的主基线。
- Swift 原生实现与 Electron 主线在明确切换决策前并行维护，不能把“Swift 本地 Gate 通过”解释为
  “Swift 已经成为 `main` 的主架构”。

### 分支规则

- 当前项目的新功能、修复和重构分支，默认必须从 `swift-rewrite` 创建，并以 `swift-rewrite` 为
  合并目标。
- 在 Owner 或项目决策明确记录“Swift 成为主架构”之前，禁止将 `swift-rewrite` 或其派生分支
  直接或间接合并到 `main`；不得通过普通合并、squash、fast-forward 或其他等效方式绕过该规则。
- 针对 `main` 的 Electron 维护工作必须保持 Electron 架构边界，不得以该工作改变 Swift 的开发基线。

### Swift 成为主架构前的目标

1. 继续在 `swift-rewrite` 上完成原生功能开发、回归验证、严格告警清理和 GitHub CI 验证；已配置的
   分支保护必须持续要求对应的 native checks。
2. 保持 Electron `main` 的可维护性与历史兼容性，不用未批准的架构切换破坏现有主线。
3. 只有在完成明确的 Owner/项目决策、功能与数据兼容验收、发布和回滚方案、CI/默认分支治理
   更新后，才允许讨论将 Swift 提升为 `main` 的主架构。
4. 架构切换决定必须先记录在本方案和相关发布文档中，再执行任何从 `swift-rewrite` 到 `main`
   的合并。

本节是当前有效的分支与架构约束；下方历史迁移记录只描述当时阶段，若与本节冲突，以本节为准。

## 2026-09-10 路径一收尾：B1–B3 遗留修复

Owner 批准路径一后按红绿流程完成三项遗留修复，各自独立提交。
89d2bb0 将五处逐次新建的 ISO8601DateFormatter 收敛为 Mutex 共享实例：
Persistence 层新增 PersistenceTimestamps（带毫秒/整秒两型渲染与 v1
库校验的双配置解析序，字节输出冻结不变，保留"带毫秒格式无法解析整
秒戳"的非对称），Workflow 层新增 WorkflowTimestamps 承担
discovery/probe 元数据的整秒戳；Mutex 不可复制，选实例必须分支而非
三元。906d07f 修复两处 fileImporter 完成回调在主线程
Data(contentsOf:) 同步读盘：新增 SecurityScopedFileReader，安全作用
域开启后横跨后台读取全程（提前关闭会使描述符在读取中途失效），缺失
与无权限均抛错并继续走 model.report，保持 fail-closed。
bb1d865 补齐安装停止的差集回收：启动前快照进程表，发起停止后仅回收
"快照之后出现且可执行路径或 argv 携带受管根签名"的进程（pip 构建
隔离的孙进程不再逃逸为孤儿），读不到的进程跳过、无签名者绝不触碰；
清扫挂在"我们发起过停止"上而非仅 KILL 升级点——无 trap 的子进程常
在 KILL 期限前就死于 TERM，仅挂升级点会漏扫。

验证：真实孙进程回归先在空签名（等价旧行为）下失败、暴露存活孤儿
pid，启用清扫后转绿；swift test 320 通过、2 跳过、0 失败；swift
build -Xswiftc -warnings-as-errors 通过；git diff --check 干净。
技术门禁 .codex/gate-results/SM-09/20260909T163904Z-bb1d865f3db0：
除 approval_freshness 按设计 FAIL（需 Owner 在最新提交重新批准）外
全部 PASS，含 sm09_packaged_ui 打包 e2e（SecurityScopedFileReader
改造后的导入路径随本轮一并见证）。终局：Owner 在本节提交上批准后复
跑 Gate 以 24/24 COMPLETE 收束。

## 2026-09-09 CSV 导出守卫回归与验收流水线

复盘 Gate 20260909T140705Z 的 7 项 FAIL：0e0f3e1 将非 Sendable 的
Vision 对象（handler/request/results）生命周期整体固定进 performQueue
闭包，仅回传 Sendable 结论，修复 forbidden_items、gate_self_tests 与
sm09_native_contract 的 @unchecked Sendable 根因；3cc9f2e 让 phase
state 校验数据驱动地接受终局阶段（无后继包文件）的 nextPackage=null，
非终局阶段仍拒绝 null。

打包 e2e 重冻结牵出真实生产缺陷：合并导出守卫误用 updatedRowCount，
而整表位宽规范化（002→02）会把无匹配行也计为已更新，密封 SM-09
旧任务（记录缺卷号/视频码）的合并导出因此静默成功并弹出保存面板。
旧源码 public/csv-background-tasks.js export-resolve 有意以
matchedRecordCount 判定（fps 回填不得掩盖卷号/视频码不匹配），
c2bdfc7 据此改回 matchedRecordCount 并新增仅规范化场景的回归冻结。
edf11e5 将 e2e 重冻结到保留 Worker 语义：CSV 场景改在旧任务上执行
（Workspace.activate 自动选中首任务，其恢复记录缺卷号/视频码，合并
导出必须报"没有匹配到可写入的完整记录"且不产出文件）；错误 Label 的
AX label 为空、消息在 value（失败快照证据），见证改为读 static text
value；独立导出冻结 <sheetTitle || 场记单>_场记识别.csv 命名与
UTF-16LE BOM/CRLF/位宽字节（A001/002/03→001/02/03，未知 remark 键
不入库故 Comments 为空）；保留新建任务与重开"2 个任务"断言。

验证：swift test 311 通过、2 跳过、0 失败；swift build -Xswiftc
-warnings-as-errors 通过；打包 e2e 定向 45.2s 通过（导入、报错见证、
独立导出字节、退出重开）。已知环境限制：approval_freshness 将按设计
FAIL——4816fe4 的 Owner 批准先于本轮修复提交，需 Owner 在新提交上
重新批准后方可置 COMPLETE；sm09_packaged_ui 的 UI runner 依赖桌面与
TCC 环境，历史上偶发键盘焦点 flake（见 2026-09-08 小节）。最终状态：
SM-09 技术项全绿，终局以本提交（edf11e5 之后的干净树）上的 clean
Gate 复核为准，结果落盘 .codex/gate-results/SM-09/。

## SM-09 测试退出与失败证据（2026-09-08）

680424e clean Gate 共享 UI 11 项通过，打包 UI 8 项通过、CSV 1 项失败；
同一 Release ZIP 解包后单独运行 CSV 仍在 Go 跳转后等待确认按钮失败。
整体保持 FAIL，不能以此前定向 PASS 或历史 Gate 批准当前版本。
独立复核另确认测试删除目录时 App 仍持有 SQLite 文件，日志出现 vnode
unlinked while in use。统一 XCTest teardown block 现在先终止 App 并验证
退出，再删除隔离目录；退出失败保留目录并报告失败。两个连续定向 UI
用例通过，此清理修复不作为 CSV 问题已解决的证据。

2026-09-09 将 Go 跳转 Return 发给已验证路径的输入框，避免从应用级目标
发送键盘事件。同一 680424e Release ZIP 上 CSV 定向用例通过，包含导入、
字节比对及退出重开；仍须以新技术提交的完整 Gate 验证所有测试组合。

## SM-09 文件面板同步修复（定向验证通过）

2d22eda 的新Gate共享UI出现CSV导出等待超时及Settings AX连接丢失，打包UI
通过；整体保留FAIL。独立审查确认旧choosePanelPath没有等待异步呈现面板、
路径焦点或跳转完成，不能归因于用户干扰。工作区助手改为等待确认按钮、
明确替换Go路径并核对值、等待Go关闭、点击打开/保存及等待面板关闭。
用户确认桌面空闲后，Settings定向通过；CSV助手按实际AX标识OKButton、
GoToWindow、PathTextField修正后定向通过，保留字节和源数据断言。
新技术提交仍须完整clean Gate；不以旧PASS批准本次修复。


## SM-09 独立复审二次修复（2026-09-08）

独立复审确认既有证据哈希、实际执行和删除映射，但发现两个 P1：混合环境
诊断覆盖 XCTFail/未知失败，以及进程查询错误被吞后误报清理成功。分类器
现在按失败条目识别 runner 初始化问题，未知/缺失条目保持 FAIL；进程枚举
和读取错误向上传递，仅再次成功枚举证明 PID 消失才接受进程退出竞态。
新增分类与无真实信号的进程 stub 测试，Gate helper 共119项通过。
修复后须重新独立复核、形成技术提交、执行精确提交 clean Gate。


## SM-09 UI 验收环境依赖修复（2026-09-08）

cf26822 完整 Gate 保留 FAIL：共享 UI 两项断言失败，打包 lane 暴露 Desktop
夹具读取权限与 AX 环境问题。将同一冻结夹具作为 UITest target 的资源复制，
运行时仅从测试 bundle 读取，不依赖仓库 Desktop 访问权限；启动后显式激活
被测 App，保证键盘/AX 验收在前台执行。两个失败用例定向重跑均通过，
测试 bundle 夹具与 canonical 原文件逐字节一致；原生业务代码未改动。
新技术提交后重新运行完整 clean Gate，旧失败不得被改写。

## SM-09 双模型 review 修复（2026-09-08）

结构化 XCTest 失败始终向外层 Gate 传递分类标记，覆盖失败计数非零但明细为空的边界。
六项 Owner 删除决定逐项绑定真实实现/测试或原样归档；合同拒绝模板替代映射。
历史 coverage 保持不变，新增 final coverage attestation 并核对 seal 哈希与提交；
49 项夹具逐项记录并验证实际 Git 来源，两个 SM09 夹具冻结于 c9a4004。
定向验证：Gate helper 103、release pipeline 16、native contract 7 项通过。
全部技术/方案文件先提交，再于精确干净 SHA 跑完整 Gate；其后只更新阶段 review，
防止再次因 manifest/AGENT 变更使证据过期。Dock/Spotlight CUA 再次超时，
远端保护与 CI 的只读结果记录在 sm09-review-external.json；待办不转换成通过。


## SM-09 打包测试目标绑定修复

收尾 clean Gate 在 `c6e1634` 的 packaged UI 新增用例失败；旧版源夹具本身未漂移。
修复 `.xctestrun` 的 `UITargetAppPath` 和对应 dependent product，使 XCTest 的正式
目标与 URL 启动目标同为 Release app。保留测试运行器 App Sandbox 与其临时目录，
不扩大 App 权限。修复后同一 ZIP 的9项 UI与进程清理通过。
同时将 xcresult 的断言详情输出到 Gate 日志；旧失败日志加上真实断言后，分类验证
为 FAIL，不能再被旁侧环境日志覆盖为 BLOCKED_ENV。修复提交 `01d8bce` 已通过完整 clean Gate，证据见 `sm09-closure-gate.json`。

## 2026-09-08 SM-09 收尾补验（clean Gate PASS，待独立审查）

新增旧版真实 Library 在 App 内打开、CSV 导入/导出及退出重开的 XCUI 验收，
检查默认 Shot/Take 格式、CRLF 和源 CSV 不变，单项已通过。
打包 smoke 将临时根规范化为真实路径，并把应用进程退出作为成功条件，修复
`/var` 与 `/private/var` 不一致造成的清理遗漏。干净提交 `01d8bce` 的最终 Gate 已执行并通过新增测试及打包进程退出检查。
隔离旧包替换、提示词恢复和 Finder 无窗口重开已有 CUA 观察；Dock/Spotlight
接口超时，仍待验收。独立审查与最终 Owner 批准保持待办，不能标记 COMPLETE。
自动提交使用 Conventional Commits，并在正文补足原因、验证及影响范围。

## 2026-09-08 SM-09 原生切换（技术 Gate PASS，待审查）

Owner 已确认继续实施 WP-6，包括六项待决文件。代码提交 `c9a4004` 的最终 clean Gate PASS，详情见 `.codex/swift-migration/reviews/SM-09.md`。
239 个旧生产/构建/测试输入按
`sm09-cutover.json` 逐项记录 SHA、原因和原生替代后提交删除，可从 Git 恢复。
原始 `.codex/refactor` 保持不变；旧 UI 审计配置另存 `sm09-premium-ui-history.json`。

当前构建和测试入口只使用 Swift/Xcode/macOS 工具。共享 `phase_gate.sh SM-09`
验证删除前提交 `52b2a78` 的 ancestry、PASS 与哈希，运行原生测试、Release CSV
性能、45 项原生界面证据、Universal Archive、ZIP/DMG 审计，以及从 ZIP 解压出的
Release app 的完整 XCUI 路径。CI 获取完整 Git 历史以验证来源；不再提供旧阶段
运行入口，历史阶段从其批准提交重放。

新增原生合同冻结了49份夹具及235项既有XCTest成功用例，并拒绝来源/夹具/
Prompt漂移、缺失执行、性能超限和删除映射缺口。旧 Node 合同的执行覆盖迁入
Python 标准库检查，来源文本只从已验证 Git 对象读取，不执行旧代码。

真实旧版导出的项目/项目库作为离线 base64+SHA JSON 夹具保留。SM09 原生测试验证
导入、未知字段、编辑、关闭重开、再次导出/导入以及原包不变；所有数据在临时根。
可选 Paddle 真实模型测试仍通过 `script/paddle_offline_check.sh` 显式注入离线环境。
唯一发布资源位于 `SlateSyncApp/Resources/PaddleOCR`，不捆绑 Python/venv/模型。

五个 Swift 模块与 SQLite v1/Keychain 语义保持原有架构；说明见 README.md、RELEASE.md。
当前只验证 ad-hoc 本地候选包；最终 clean Gate 与审查完成前不标记 SM-09 COMPLETE。

## 历史方案记录（以下内容只描述当时阶段，不是当前操作入口）


## 2026-09-08 SM-09 最终删除前兼容刷新（当前有效）

- WP-2～WP-5 与后续 Gate fail-closed 修复已收敛到精确提交
  `52b2a78f6619145b0999bdccf588d83a95349e7c`。该干净提交仍保留全部 legacy
  oracle，并完成 SM-09 全矩阵：34 项 PASS、批准窗口 1 项 NOT_APPLICABLE、
  `approvable=true`。SwiftPM 236 项（1 项离线环境跳过）、Xcode Test Plan
  10/10、Node compatibility 324/324、Modern 118/118、Gate helper 106/106、
  release contract 7/7 与 package pipeline 16/16 均通过。
- 最终 evidence 目录为
  `.codex/gate-results/SM-09/20260907T155254Z-52b2a78f6619`；tracked 摘要为
  `.codex/swift-migration/manifests/sm09-final-pre-cutover.json`，保存 result、
  checks、summary、34 份日志、inventory/coverage 与 package artifact hashes。
  初始 `sm09-pre-cutover.json` 保持原样，未用事后结果改写历史 baseline。
- Gate 生成的同源 Universal app/ZIP/DMG 均为 arm64+x86_64、macOS 15.0、
  Xcode 26.3、ad-hoc+hardened runtime、空 entitlements、系统依赖；ZIP/DMG
  checksum、解压、只读挂载、签名、资源和 app lineage 回验通过。artifact manifest
  明确记录 Developer ID/notary 未配置、`published=false`，不构成外部分发。
- CARRY-02 已按本机约 7 分钟完整 compatibility Gate 重新核定两条 workflow 的
  30 分钟上限；CARRY-07/08/13/14 已在最终刷新复验并写入 carry closure。
  WP-6 仍需 Owner 对六项 `decision-required` 建议一次性确认；确认前 legacy
  production inputs 和这六个文件保持原样。

## 2026-09-07 SM-09 WP-2～WP-5 原生发布链路（当前有效）

- WP-2 将 PaddleOCR runner 与固定依赖清单迁入唯一 canonical 目录
  `SlateSyncApp/Resources/PaddleOCR/`。Xcode 以文件夹引用保留包内
  `Contents/Resources/PaddleOCR/` 层级；Swift runtime、安装器、SM-06/08
  fixtures 与最后一次 Electron compatibility oracle 均读取同一份源码。
  `Info.plist` 的 short/build version 改由 `MARKETING_VERSION` 与
  `CURRENT_PROJECT_VERSION` 注入，Release 保持 macOS 15、Swift 6、Universal、
  hardened runtime、空 entitlements，Debug 继续保留可调试边界。
- `.codex/swift-migration/manifests/sm09-native-resources.json` 冻结 Paddle、Help
  与 icon 源文件的大小和 SHA-256，并定义最终 bundle allowlist/denylist。
  `script/verify_bundle.sh` 对精确 arm64+x86_64、版本/标识、macOS 15、资源字节、
  符号链接、renderer/Node/Python runtime 残留、Mach-O 系统依赖、空 entitlements、
  hardened runtime、ad-hoc/Developer ID lane 和 nested code 签名 fail-closed。
- WP-3 新增 `script/archive_release.sh`、`script/package_release.sh`：版本作为显式
  build input，不改 tracked project；输出目录必须在仓库外且原子新建。ZIP 与 DMG
  从同一 audited app 生成，解压/只读挂载后再次做 bundle 审计和目录 manifest
  血缘比对；失败 trap 会卸载磁盘映像并删除 staging/partial artifacts。输出包含
  `SHA256SUMS`、JSON manifest 和中英 release notes。fake tool 自测覆盖单架构、
  错误资源、symlink、签名/hardened runtime 失败、mount/DMG 失败、并发输出、
  partial cleanup，共 16/16 通过。
- 默认 Gate 结果目录可能位于仓库内的忽略目录，而 release packager 必须拒绝任何
  仓库内输出。`phase_gate.sh` 因此先在系统临时目录完成 ZIP/DMG 构建、挂载与
  lineage 回验，成功后才把审计过的候选包复制到本次唯一 Gate evidence 目录；CI
  仍可上传 evidence，packager 的仓库边界保持不变。SM-09 有意修改过的 Vision/Paddle
  compatibility sources 已同步到 SM-06/08 冻结清单；独立 retained-artifact
  postcondition 防止 shell 提前返回把缺失产物误报为 PASS。全量 manifest hash scan、
  Gate helper 106/106、SM-06/08 负例、release contract 7/7 与 pipeline 16/16 均通过。
- 本机真实 Xcode 26.3 archive 已生成并验证为 arm64+x86_64、macOS 15.0、
  `flags=adhoc,runtime`、空 entitlements，依赖仅为系统 framework/dylib；同一 app
  的真实 ZIP（约 7.0 MiB）与 DMG（约 8.4 MiB）均通过解压/只读挂载、签名、
  版本、资源和血缘回验。当前证据位于 `/private/tmp/slatesync-sm09-wp3-archive-2`
  与 `/private/tmp/slatesync-sm09-wp3-artifacts-2`；这是施工期验证，最终 clean
  compatibility refresh 及精确 commit 证据见上节。
- WP-4/5 workflows 已去除 Node/npm/Electron 构建步骤，固定 `macos-26` 与
  `/Applications/Xcode_26.3.app`。GitHub 官方 runner 清单确认该 image 提供
  Xcode 26.3；原定 `macos-14` 已进入弃用窗口。CI/release 均调用共享
  `SLATESYNC_NATIVE_ONLY=1 ./script/phase_gate.sh SM-09`；release 复用 Gate 生成的
  单一 Universal archive，不做双架构矩阵拼接。30 分钟 timeout 依据本机完整
  compatibility Gate 约 7 分钟，并为托管冷缓存、UI、DMG 挂载和清理保留余量。
- WP-0 决策仍只授权 local/PR ad-hoc lane。本次未配置或读取 Developer ID/notary
  secret，未执行公证、Gatekeeper 发布评估、tag、push 或 GitHub Release；artifact
  manifest 与中英 notes 明确记录 `BLOCKED_ENV`/未发布状态。旧 Electron/React/Node
  目录继续保留，直到 WP-2～WP-5 clean pre-cutover refresh 全项 PASS 且 Owner 确认
  WP-6 六项 decision-required 建议。

## 2026-09-07 SM-09 初始基线与 WP-1C 实施（当前有效）

- 准备提交 `218b43c` 已创建；该精确 clean commit 的 SM-09 Gate 全项 PASS、
  approvable=true，覆盖 SwiftPM、Xcode Unit/UI、真实 App 启动、Universal
  Release/Archive、Node 324、Modern 118、TypeScript/build 和 Electron ABI。
  27 份日志 hash 与 UI 运行条件封存在 `sm09-pre-cutover.json`。这是 WP-1
  初始 baseline，WP-2～WP-5 后仍须 final refresh 才能进入 WP-6 删除。
- CARRY-08 已在 `218b43c` 修复：日志分类五处 rg 扫描均检查退出码；2+ 输出诊断并
  返回 FAIL。移除 quiet 提前退出，避免匹配后输入故障被隐藏；既有真实断言、
  FAIL marker、BLOCKED_ENV marker 与环境分类优先级保持不变。
- Gate 自测 106/106：新增逐扫描位置注入 2/127 与缺失日志的 11 项回归。
  `node script/tests/sm02_platform_contract.mjs`、zsh 语法检查通过。
- WP-0 清单生成器保留全部引用者，使用 NUL 分隔支持中文/换行文件名，
  git grep 故障不再吞成空引用；所有分类含 owner 与引用图。schema v2 明示
  working-tree、dirtyWorkspace、approvable=false；自身摘要明确排除，封存时
  外部 hash，避免记录上一版摘要。`sm09-coverage.json` 已为 233 个
  legacy-remove 文件逐项记录 pre-cutover hash、原生 family、replacement 与
  acceptance IDs，unowned=0；清单/覆盖回归 8/8 通过。
- WP-1C 已实施 CARRY-01/06：Paddle wire 改为 typed payload 单次编码与
  recognize envelope 单次拼接，约 18 MiB 图像数据的旧/新字节完全一致；
  Paddle/Vision 改用 actor-owned continuation FIFO，单 waiter 取消、deadline、
  close 唤醒和 active drain 均无生产忙轮询。媒体定向 28 项通过（1 项专用
  离线 Paddle lane 跳过）。实现提交为 `2679db6`；其 clean SM-09 Gate 全项
  PASS、approvable=true，证据目录为
  `.codex/gate-results/SM-09/20260907T142544Z-2679db6e4d4c`。此前完整 dirty
  diagnostic Gate 也全项 PASS，证据目录为
  `.codex/gate-results/SM-09/20260907T141615Z-218b43c71bc8`；按设计退出 3、
  approvable=false。CARRY-01/06 已闭合；legacy 源未删除。
- CURRENT_STATE 继续保持 SM-08 COMPLETE；未 push/tag/release，未触碰用户
  Library、Keychain 或安装目录。

## 2026-09-07 SM-09 开工（当前有效）

- Owner 已授权进入 SM-09（cutover and release）。授权时准入条件核对通过：SM-08
  COMPLETE、状态与 review 指向同一已批准 commit 链、原生 App 覆盖全部
  表面、旧兼容源完整；当前施工工作树因 carry/Gate 修复和本计划更新已变脏，正式
  Gate 前必须重新形成精确 SHA 的 clean commit。
- CI/Gate 解析器升级为"工作阶段"语义：上一阶段 COMPLETE 且下一阶段已开工
  （有施工包、尚无 review）时，CI 跑下一阶段 Gate 的预准入模式
  （`gate_validate_phase_state` 接受 {N-1, N}，approval_freshness 只在
  Gate 阶段==状态阶段时生效），实施期提交不再击穿上一阶段批准检查；
  `phase_gate.sh` 新增 SM-09 预准入 case（sm05/07/08 合同 technical-only、
  Node/Modern 兼容车道保留至 WP-6、里程碑构建/归档检查已纳入）。
- WP-0 产出：`script/sm09_inventory.py`（568 个 tracked 文件的全量分类：
  native-product 120 / native-test 84 / release-input 19 / migration-history
  104 / fixture-migrate 2 / legacy-remove 233 / decision-required 6，含
  sha256 与删除前引用图）落盘 `.codex/swift-migration/manifests/
  sm09-inventory.json`；发布/版本/分发决策冻结在
  `manifests/sm09-wp0-decisions.md`（ZIP+DMG 双格式、v1.0.0/1 版本映射、
  本阶段仅 ad-hoc lane 不公证不发 Release、六项 decision-required 建议）。
- SM-09 剩余 WP-0 项：sm09-coverage.json（旧测试 family → Swift/fixture/
  history-only 映射）随 WP-1 baseline 产出；decision-required 六项在 WP-6
  删除前需 Owner 一次性确认。
- SM-00～08 全部遗留问题已按 Owner 指令并入 SM-09 统一台账
  `manifests/sm09-carried-issues.md`（CARRY-01～14：代码遗留 7 项、Gate/
  治理 2 项、已裁决不修 4 项、环境观察 1 项，另附已闭合 8+2 项备查）。
  Owner 指示逐项修复：CARRY-07（App 组合根强制解包）已完成——以显式
  回退链替代 `UserDefaults(suiteName:)!`，隔离运行永不写真实 `.standard`；
  CARRY-03（createProject 孤儿目录）已完成——修复时核实 SM-04 已加补偿，
  本轮补上精确性守卫（预存在目录不再被无差别删除）与两个失败注入回归，
  SlateSyncPersistenceTests 62/62；CARRY-02（CI timeout）已完成——
  ci.yml 15→60、release.yml 30→60（完整 Gate 本地实测 15-20 分钟，托管
  runner 更慢），WP-4/WP-5 重写时再按 native-only 步骤核定；CARRY-04
  （defaultProjectID 悬空契约）已完成——修复时核实自 SM-04 起 bootstrap
  即对每个 Library 幂等播种 default 行（与旧版 Electron 语义逐字一致），
  原审查描述在 HEAD 不成立，无需行为变更；本轮以注释固化不变量并新增
  全新 Library 的 default 契约回归（存在+canArchive+归档/删除保护），
  SlateSyncPersistenceTests 63/63；CARRY-09（阶段状态断言时序刚性）已按
  Owner 治理决策修复——引入 `lifecycleState: "PASS"` 合法中间态：批准窗口
  内"状态阶段 == 请求阶段"的 Gate 重跑被接受，预准入仍严格要求 COMPLETE；
  `approval_freshness` 门控改 JSON 精确判断（PASS 窗口记 NOT_APPLICABLE），
  ci/release 解析在 PASS 窗口跑状态阶段自身 Gate（不硬编码 SM-XX），
  PHASE_GATES.md 固化语义；Gate 自测 95/95（新增 8 项正负例）；其余项仍按
  台账保留为未闭合状态，待对应施工包实施。
- 已将 CARRY-01～14 逐项插入 `.codex/swift-migration/packages/SM-09.md`：WP-1
  baseline 后新增强制 WP-1C，集中处理 CARRY-01 wire payload、CARRY-06 FIFO
  continuation，并复验 CARRY-03/04/05；CARRY-02 随 WP-4/WP-5 重新测定 timeout，
  CARRY-07 随 WP-2 复验，CARRY-08 在 WP-9 final Gate 收敛，CARRY-09 回填治理提交
  SHA，CARRY-10～14 分别进入兼容矩阵、历史 allowlist、coverage 和 UI 运行条件证据。
  计划同时要求 `sm09-carry-closure.json` 和台账精确 SHA；本次仅更新施工计划，未把
  CARRY-01/06/08/14 标为已解决，也未修改产品代码。

## 2026-09-07 分支审查修复（当前有效）

- 对 `swift-rewrite` 全部 58 个提交完成只读审查后，按 Owner 确认的清单修复
  九项仍存活的问题；全部修改停留在工作树，未提交。
- CI/release 不再硬编码 `phase_gate.sh SM-02`：新增从 `CURRENT_STATE.json`
  解析当前阶段的步骤（与 `gate_validate_phase_state` 的 {N-1,N} 合法状态对应），
  `sm02_platform_contract.mjs` 同步改为断言"调用共享 Gate 且未硬编码阶段"。
  修复前 CI 在 SM-03 起必然失败。
- AGENT.md 顶部治理叙述与 `CURRENT_STATE.json` 对齐（见下方 SM-08 完成章节）。
- OCR 管线：`ManagedOCRProcess` 写入/读取管道故障先按子进程存活状态分类，
  子进程已退出时映射为 `OCR_PROCESS_EXIT`（监督者 one-shot 恢复白名单成员），
  修复"大请求写入中子进程死亡被误判为 OCR_PROTOCOL 不恢复"的竞态；
  `OCR_PROCESS_EXIT` 错误现在附带有界（2KiB 采样/500 字符）且脱敏的
  stderr 尾部摘录。
- Vision 原生识别的同步 `perform` 移到专用串行队列，actor 在 continuation
  上挂起，不再长期占用 Swift 协作线程池；非 Sendable 的 Vision 对象沿
  `WindowLifecycleBridge` 的地址移交先例跨队列（passRetained/takeRetained），
  不引入 Gate 禁止的 unchecked Sendable 声明。
- CSV 输入新增统一 64 MiB 预算（`CSVInputBudget`，Owner 选定；媒体侧为
  20 MiB）：`ResolveCSVEngine.decode` 与 `SlateCSVWorkflow.decode` 超限即
  fail-closed 返回 `CSV_INPUT_SIZE`，解析循环逐行 `Task.checkCancellation`。
- Gate 扫描 fail-closed：`forbidden_items_check` 移入 lib 并对 rg 退出码
  2+ 显式失败；SM-01 范围检查的三处 rg/git grep 扫描（生成物/凭据路径/
  凭据内容）同样不再被 `|| true` 吞成"无违规"；gate 自测新增 5 项负例
  （注入退出码 2 的 rg），当前 87/87。
- SQLite WAL 附属文件 `-wal`/`-shm` 在打开、checkpoint 与关闭三个时点
  尽力修复为 0600（nonisolated 实现，init 亦可调用）。
- `SlateMetadataParser.supports` 的后缀匹配语义经核实为冻结的旧版
  `/slate\.txt$/i` 兼容行为（黄金测试要求接受 `A001C001-SLATE.TXT`），
  行为不变，仅修正误导性注释并说明两层兜底。
- 新增回归：EPIPE 场景 one-shot 恢复（fake runner 新增 die-after-warmup
  模式并同步 manifest 哈希，断言 `launches == 2` 证明恢复发生）、CSV 预算
  负例。SM-06 契约自测、SM-02 平台契约、Gate 自测与受影响测试目标均通过。

## 2026-09-06 SM-08 阶段正式完成（当前有效）

- 治理收尾提交 `bb5c910` 已将 `.codex/swift-migration/CURRENT_STATE.json` 更新为
  SM-08 `COMPLETE`：Gate 结论 `PASS`，审查提交 `70fb5db`，Owner 批准时间
  `2026-09-06T11:07:39Z`，正式记录在 `.codex/swift-migration/reviews/SM-08.md`。
- 下方"SM-08 正式收尾"章节是完成前（`BLOCKED_ENV` 期）的历史记录，其中
  "CURRENT_STATE.json 仍保持 SM-07 COMPLETE、SM08 为 BLOCKED_ENV/PENDING"的表述
  已被本章节取代；当前准入为 SM-08 `COMPLETE`，下一施工包为
  `.codex/swift-migration/packages/SM-09.md`。

## 2026-09-06 SM-08 正式收尾（历史记录，已被上方完成章节取代）

- 用户已允许最终验收使用前台测试；中间回归仍优先后台执行。所有
  `.xcresult`、截图、日志与性能数据只写入 `/private/tmp` 或已忽略的
  `.codex/gate-results` 目录，不进入提交。
- 前台 XCUI 已证明原有两项 ⌘W 失败是产品缺陷：应用级 `Commands`
  中的 `dismissWindow` 没有当前 Scene 所有权。关闭命令现路由至
  `NSApp.keyWindow?.performClose(nil)`，使 WindowGroup delegate 保存拦截与辅助窗口
  关闭同时生效；多窗口关闭/重开和 Settings 关闭返回 Help 已 2/2 通过。
- 新增中文键盘与明暗外观验收时发现 macOS Form 的纵向 TextField 及
  Picker 只将标题暴露为独立静态文本，交互控件本身无 VoiceOver 名称。
  当前修复为显式无障碍标签与稳定标识；中文保存恢复、VoiceOver 语义和浅深色
  前台验收已通过。
- 独立代码审查补出并修复识别取消 drain 期间重新准入、失效 Provider/Model
  被静默替换、非 Workspace route 的 ⌘N 隐藏建任务三类所有权缺陷。取消期间
  `recognitionTask` 与 `cancelTask` 共同关闭准入；任务/项目保存的失效选项会原样
  显示“不可用”并提供 Settings 入口，只有用户明确切换 Provider 才清除不兼容模型。
- 空任务不再继承上一任务的 View-local Provider/Model。共享
  `GlobalSettingsModel.revision` 会在 Settings 发布后触发所有仍挂载的 Workspace 与
  Project Settings 重载；`RecognitionModel` 以 generation 拒绝重叠加载的迟到结果。
- CSV 键盘 selector 现由纯策略覆盖 Enter/Escape/Tab/Shift-Tab/方向键/Home/End，
  copy/paste 保留给 NSTextView responder chain，IME marked text 只阻断单元格导航。
  万行 fixture 已加入中文、emoji、长字段、空值、重复文件名与混合状态；coverage
  将含原生交互的宽泛验收项移回 manual/Gate lane，native evidence 还要求结构化命令、
  退出码、逐项断言和不可复用的 Gate 根目录制品。当前后台 owner 52/52、完整 Swift
  220 项（1 项专用 Paddle 跳过）均为 0 失败；原生前台证据仍不据此宣称 PASS。
- 最终产品提交 `dc00b6d15ec9119e308f5f38f0f38fbddb032e2a` 已完成精确提交后台
  复验：Swift 220 项（SM08 owner 52/52）、Debug、Release、静态分析、双架构
  Archive、Gate helper 82/82、Node 324/324、Modern 118/118、静态检查、类型检查、
  production build 与 Node/Electron SQLite ABI 均通过。独立代理
  `01a07569-6bba-7950-aa7c-d1b1226fef02` 只读审阅完整 diff，P1/P2/P3 均无可执行
  代码发现；正式记录在 `.codex/swift-migration/reviews/SM-08.md`。
- 完整 SM08 contract 在缺少 native-surface 执行和 Owner-attested evidence 时按设计
  fail closed；本地 evidence schema 只能验证结构、摘要和源码新鲜度，不能自建可信
  执行根。因此 `CURRENT_STATE.json` 仍保持 SM-07 `COMPLETE`，SM08 为
  `BLOCKED_ENV/PENDING`，不得在后台约束下伪标 COMPLETE 或启动 SM-09。
- 为遵守“所有测试在后台进行”同时继续关闭可自动化证据缺口，SM08 native-surface
  harness 改为把真实 `NSWindow` 固定到所有显示器之外并使用 `orderBack`；不再调用
  `makeKeyAndOrderFront`、`orderFront` 或应用激活 API。独立复审发现 titled window
  可能在首次 ordering 时被 AppKit 约束回屏，现于 alpha=0 后重新设置离屏 frame，并
  明确断言不与任何 `NSScreen` 相交、`screen == nil`、非 key/main、应用激活状态和原
  key/main window 均未改变。真实 AppKit field editor、
  NSTableView 万行复用/滚动/释放、同 revision 数据替换和 close delegate 4/4 通过，
  完整 Swift 回归因此可不跳过该 suite，当前为 224 项、1 项 Paddle 跳过、0 失败。
  完全离屏窗口没有显示器合成语义，因此已从该测试删除 display-link FPS 通过门槛和
  `scrollFramesPerSecond` 指标；真实帧率继续保留为前台 PERF-02 Gate，不用后台 tick
  冒充屏幕渲染证据。
  SM08 contract 已继续执行到唯一缺失的 `--native-evidence` 门槛，不再因 native-surface
  XCTest 未执行而提前失败；这仍不替代 XCUI/VoiceOver/真实候选窗或 Owner 背书。
- 历史 XCUI `.xcresult` 活动树与录像证明：Help 路由已通过，两个窗口失败
  都是 ⌘W 后目标窗口持续可见，不是 XCUI 计数滞后。根因为
  `SlateSyncCommands` 替换了整个 `.saveItem` 系统组，连同 macOS
  Close 命令一并删除。现用 SwiftUI `dismissWindow()` 显式恢复当前窗口
  ⌘W，并只注册一个聚焦 ⌘S；工具栏 Save 调用同一 workspace owner 但不再
  重复注册快捷键。正式 UI PASS 仍等待允许前台后复跑。
- 关闭/退出失败横幅现由 `TerminationCoordinator` 清除自己的错误，不再误调
  `AppSessionModel.clearError()`；只有导航/自动保存错误显示“重试保存”，
  IME 组字、Library barrier 等终止错误不再提供无效重试动作；对应回归已纳入
  SM08 coverage 的 `APP-06` 与 Gate regression evidence，防止后续只编译未执行。
- Provider 探针与 Paddle 安装的同步进度回调会各自 hop 到 MainActor；模型现在拒绝
  completed/percent 倒退的迟到样本，避免并发调度让可见进度回退。反序回调测试已纳入
  `SET-05`、`SET-07` 和 Gate regression evidence。
- Provider probe 取消现进入 `GlobalSettingsModel` 的 active-call barrier；Paddle
  安装取消 task 由模型保留并在应用 drain 中等待。退出不会在这两个取消 service hop
  仍活动时提前关闭 workflow；probe 取消用独立 UUID 所有权阻止删除/编辑 Provider 后
  的迟到终态回写。确定性 gate 测试覆盖取消、后继删除与原操作同时挂起的顺序。
- AppDelegate 在 WindowGroup 尚未注入生命周期 owner 的极早期 Quit 现在 fail closed
  为 `.terminateCancel`，不再用 `.terminateNow` 绕过全局 settings/installer/window drain；
  SM08 静态契约固定该安全默认值。
- 收尾代码审查发现并修复两个可在后台验证的问题：CSV 缩表刷新前裁剪
  `NSTableView` 选区，避免重新应用越界行；Paddle 安装子进程改用受管
  HOME 并禁用 pip/user-site 配置，不再隐式读取用户包索引凭据。
- 项目/任务 List 性能 harness 改为只附着不展示的 `NSWindow`，不再调用
  `makeKeyAndOrderFront`；这项规模测量因此可以遵循“所有测试在后台进行”的约束。
- List 挂载时跳过已有项目库的重复 load，任务 rail 忽略原生选区回写的
  同 ID echo，减少重复读取与选择动作。隐藏 List 测量中每次挂载一次的
  `NSTableView` delegate 重入预警，已用不含任何 SlateSync 状态/绑定的
  纯 `List(0..<500)` 后台最小复现；6 次挂载精确产生 6 条。因此当前
  12 条可归类为未 ordered 的 SwiftUI List/harness 行为，不是项目/任务
  model 重入；可见窗口仍留待专用 UI 环境确认。
- 识别取消新增项目级 ticket：如果关闭/归档发生在 coordinator 构建或
  started-log 挂起期间，排队请求在进入真实 OCR/Provider 前即会收敛为取消，
  不影响其他窗口项目。facade 入场还同时检查调用 Task 的取消状态，封闭“取消已先
  发生、旧调用随后才进入 actor 并捕获新 ticket”的窗口；构建后会在写 started 日志
  前重新校验，已取消请求不会留下误导性的启动事件。
- `NSWindowDelegate` 的 Objective-C 动态转发入口现在显式使用 AppKit 主线程
  契约访问 MainActor 所有的 previous delegate，清除 Swift 6 非隔离重写警告。
- 本地场记 CSV picker 的迟到回调现在与媒体/metadata 共享底层准入门：
  任务切换、窗口关闭、项目库变更或退出期间不再启动新的解析/识别；
  picker 读取失败也改由 Recognition 表面报告。
- 安装进度测试改为同步加锁收集回调，避免并行回归中多个无结构
  actor-hop Task 合法乱序后造成的假失败。
- 审查后后台 Swift 回归共 214 项、退出码 0；SM08 owner 专项
  47 项全通过。不呈现窗口的 500 projects / 1,000 tasks List
  规模测试单项通过；12 条重入预警已通过最小纯 SwiftUI 对照归类为
  隐藏 harness 行为，对照日志为 `/private/tmp/slatesync-sm08-minimal-hidden-list.log`。
- 产品提交 `cf4396856e55f485ddcf64439284e75de3be3d35` 的 Xcode
  Debug/Release build、静态分析以及本地 Release Archive 均在后台重新通过；Archive
  路径为 `/private/tmp/slatesync-sm08-cf43968-signed.xcarchive`，是
  arm64/x86_64 universal、ad hoc、hardened runtime，codesign strict verification
  通过，不代表 Developer ID 签名、notarization 或发行资格；Xcode 静态分析亦无源码诊断。
- 用户已要求继续完成 SM-08 剩余阶段，并明确所有后续测试在后台进行；因此本轮不再启动或操作前台应用，不把未执行的原生窗口、IME、VoiceOver、明暗色和最小窗口验收伪记为 PASS。
- 已补齐后台可验证的功能缺口：识别选项通过任务快照保存/恢复，metadata 扫描使用 CSV canonical material key，CSV 键盘顺序/边界有单元回归；窗口 close coordinator 的成功许可会在复用到新窗口时重置。
- 早期后台非原生 Swift 回归退出码为 0（日志含 210 条测试记录）；
  识别选项、metadata canonical key、CSV 键盘、真实 SQLite 规模加载均通过。
- 当前 Gate helper 后台自测为 82 passed / 0 failed（`/private/tmp/slatesync-sm08-postreview-final-gate-selftest.log`）；这只证明 Gate 辅助逻辑，不等于运行了完整 SM-08 Gate。
- 兼容矩阵后台检查均通过：Node 324/324、Modern 25 files/118 tests、静态检查、TypeScript typecheck、Modern production build、Node/Electron SQLite ABI（137/148 modules，SQLite 3.53.2）；原始日志见本轮背景验证记录。
- 真实 SQLite 规模证据：500 个项目、1,000 个任务，1 次 warm-up 加 5 次样本；项目列表 291.21–310.09 ms，任务列表 10.31–10.70 ms，均低于 1,500/900 ms 预算。原始指标在 `/private/tmp/slatesync-sm08-metrics/real-sqlite-scale.json`。
- 后台 Debug 构建、Release 构建、静态分析和 Archive 均成功；产品提交
  `cf43968` 的当前 Archive `/private/tmp/slatesync-sm08-cf43968-signed.xcarchive`
  为 universal arm64/x86_64、ad hoc runtime 签名，无 Developer ID Team ID，
  因此仅完成本地包完整性验证，不宣称 notarization/distribution 通过。
- 前台约束生效前的最新 XCUI 记录 `/private/tmp/slatesync-sm08-ui-rerun-20260906.xcresult` 为 5 项中 3 项通过、2 项关闭后的窗口计数等待超时；Help 导航已通过，main close 修复随后又有更新，Settings 关闭尚未在后台条件下重新验证。该记录保留为历史诊断，不作为当前 PASS。
- 当前结论为 `BLOCKED_ENV`，不是 `COMPLETE`：原生 UI/A11y/IME/完整窗口生命周期证据、clean Gate、独立 `reviews/SM-08.md`、Owner approval 尚未齐备；`CURRENT_STATE.json` 继续保持 SM-07 `COMPLETE`，不启动 SM-09。

## 2026-09-06 本轮目标结束条件调整（历史目标，已被上方要求覆盖）

- 用户明确允许“代码构建完成，可以停止并完成当前目标”。本轮以代码构建完成交付，
  停止继续 UI 冒烟；不把这次目标结束解释为完整 SM-08 阶段验收通过。
- 当前 App 代码已由 Xcode Debug 编译、链接并启动测试，构建成功；最后 UI 运行报告
  `/private/tmp/slatesync-sm08-window-ui-retry.xcresult` 为 2 通过、3 失败，尚有帮助导航、
  多窗口关闭和 Settings 交互断言待查。失败原始记录保留，不标记 PASS。
- 当前专项回归为 43 项通过；完整 Swift 回归此前为 205 项、1 项专用离线 Paddle
  跳过、0 失败。当前所有修改仍未提交，未执行正式 clean Gate/Owner 阶段批准。
- 构建和非界面测试可后台执行；原生 XCUI 冒烟会操作前台窗口，不能称为无干扰后台测试。
  后续如继续 GUI 验收，宜使用独立 macOS 登录会话或专用测试主机。

## 2026-09-06 全阶段语言验收范围（用户明确调整）

- 所有阶段仅要求中文语言与中文输入法验收；取消日文及其他语言的专项覆盖要求。
- IME 测试使用中文拼音组合输入和中文提交结果，继续验证候选转换期间不得误保存、
  取消或切换。通用 Unicode、emoji 与既有文件格式/字段别名兼容测试继续保留。
- 此范围调整适用于当前和后续阶段；历史已执行证据保持原样，不据此宣称阶段完成。

## 2026-09-06 SM-08 验收续进（仍在实施）

- 原生 CSV IME 改为 `zhongwen` 组合输入→“中文”提交；Help 搜索验收改用中文。
  迁移顶层 contract/master plan 与 SM-08 package 已同步用户的全阶段语言范围决定。
- 1,000-task List 去除 ForEach 内条件行结构，使用单一可复用行投影；同一五样本
  测量中选择耗时从约 160–170 ms 降到 23–24 ms，保留原定 120 ms 上限。
- 实际 NSTableView 新增同 revision 不同 tableID 切换回归，避免新结果显示旧行；
  debounce/flush 去重与 CSV canonical 同值去重防止误报 CSV_CHANGED。
- 独立审查推动补齐文件拖放/迟到 picker 的 model admission、导航 request generation、
  Workspace 单一身份投影。识别/库变更/退出冻结下 media/metadata 不再启动新输入。
- 日志事件使用固定 allowlist；安装器输出 drain 分批返回取消/超时检查，真实 noisy
  TERM-resistant 子进程测试验证返回时 ESRCH。每次代码修改均补充相应所有权注释。
- 完整 Swift 回归 `/private/tmp/slatesync-sm08-full-swift-current.log`：205 项、
  1 项专用离线 Paddle 环境跳过、0 失败。后续上述修复由 43 项 SM08 专项通过覆盖，
  日志为 `/private/tmp/slatesync-sm08-current-regression-tests.log`，正式 Gate 仍须整轮重跑。
- CSV 指标已包含五样本滚动/驻留内存、关闭后 retained delta 与 2 秒 owner 释放；
  取内存失败现在直接失败，不能把 sentinel 相减当成零开销。
- Gate 扩展 qualified XCTest 名称，并强制核对 43 项专项实际 PASS；静态负例自测通过。
  这些专项不能替代剩余 manualOrGate 的逐项证据，尚未生成全部原生证据报告。
- WindowGroup 增加稳定 main ID；新建窗口改用 ⌘⌥N，避免与新建任务 ⌘N 冲突。
  新增双窗口、关闭最后窗口后新建与独立 Settings UI 测试；初轮发现测试计数/异步关闭
  等待问题，已修正并单独重跑，结果待回填。

## 2026-09-06 SM-08 complete 目标续作（当前有效，实施与审查中）

- 当前权威准入为 SM-07 `COMPLETE`，review SHA 为
  `49f09f4de5cf45f7b6714d12bb1e24b872d06a87`。用户本轮明确要求推进 SM-08
  至 complete；以下旧章节中的 SM-07 approval pending 仅为历史记录。
- 接续已有未提交实现，发现现有 13 个专项用例不足以证明完整阶段：特别是
  `manualOrGate` 清单尚无逐项执行证据，不能据此宣布完成。
- 保存整改：结果与提示词共用单一有序快照队列，250/500 ms 仅改变同一 writer
  的 debounce；关闭先 join enqueue，同项目重开先 flush。CSV 表格编辑已接入
  TaskData 与同一 writer，路由/关闭先提交仍聚焦的 AppKit cell，marked text 阻断切换。
- 生命周期整改：原 `onDisappear` 已晚于关闭且吞掉错误，改用窄的
  `WindowLifecycleBridge`/`NSWindowDelegate` 代理 veto/retry。该额外零尺寸
  representable 仅定位所属 SwiftUI window，不创建窗口或承载业务 UI；属于
  CSV 之外必要的 lifecycle 适配例外，应在 Gate allowlist 显式逐文件审计。
- Recognition 的订阅与请求共用 single-flight runtime factory；取消先取消捕获的
  request，再等待 service 与 observer 排空。完成后刷新持久化 task，防止旧草稿覆盖
  识别结果。Metadata 取消保留句柄并串行等待被替换的 scan。
- UI 错误与 local-log sink/read 使用 Domain `ProductPrivacy` 统一最终脱敏。
  Global Settings 重开、凭据保存与 probe 刷新保留未提交草稿；Provider 回调使用
  request token，删除/修改先失效 token 再等待取消。
- 测试根现在同时隔离文件系统、Keychain、进程环境与 UserDefaults；隔离 App
  禁用真实 Provider/安装器外部操作。原生 UI 三项端到端测试通过（项目库启动、
  新建项目进入工作台、离线 Help）；Swift 专项 36 项已通过，后续新增验收仍在运行。
- 独立审查已发现并推动修复跨窗口库变更/退出竞态、reconciliation 错误解锁、
  CSV decode/merge 迟到结果、设置凭据/安装后保存未 drain、结果编辑提交时序。
  库变更覆盖所有窗口；部分 close 失败保留 owner 供退出重试，UI 保持冻结。
- Recognition result 与 CSV 复用同一原生 cell editor。测试实际挂载 NSTableView，
  发现并修复首次附着 scroll view 之前创建万行控件的问题。五次初步测量为
  约 51–54 ms 装载、156 个可见 cell；marked text 与窗口保存失败重试测试通过。
  帧率/内存与项目/任务 List 的五次正式样本另行记录，不能用数组测试替代。
- 本地场记 CSV parser/record projection 新增保留 Worker 的 differential oracle；
  本地结果与远端结果共用 canonical editor/autosave/SM05 Resolve merger。
  NativeRecognitionPersistence 对已存在任务使用 patch，保留媒体/CSV/metadata。
  Scenario 选项来自 project runtime；Help 为 bundle-local 中英文 6 节与 SHA256。
- 完整 Swift 回归发现既有 OCR Process 在已退出后再次 waitUntilExit 的 run-loop
  等待问题；改为等待 isRunning=false 后异步释放，需重新完成 SM06 资源/取消回归。
- 性能 manifest 原缺少可执行内存上限；在第一次内存测量前补充 CSV resident delta
  128 MiB 与释放后 retained delta 32 MiB，现有时间/帧率/控件数预算不变。
- `sm08_contract` 现在要求逐 ID、source fingerprint、原始 artifact SHA 的原生证据。
  严格设计静态审计无违规，但不能替代视觉/A11y 运行验收。正式 clean SHA Gate、
  全部验收证据和最后独立审查尚未完成，当前不写 `COMPLETE`，不启动 SM-09。

## 2026-09-05 SM-08 原生 UI 施工（进行中，未提交）

- 已建立 `UIWorkflowContracts` 和单一 `SlateSyncWorkflowFacade`：UI 目标只依赖
  Domain/Workflow，由 composition root 组合 Project Library、任务、CSV、metadata、
  OCR/Provider、全局设置与本地日志，视图不直接打开 SQLite、Keychain、
  URLSession 或 Process。每个 `WindowGroup` 保持独立 session/workspace/
  recognition owner，Settings 和应用级 lifecycle 才共享。
- 已接通 Project Library 的 active/archive/create/import/export/rename/relocate/exact-name
  delete，所有 Library 变更与导出均先经过同一 Workspace flush barrier。Workspace
  任务 rail 与 500 ms 单一 autosave writer 将 route/project/task switch 统一收敛到
  可等待 barrier；失败时保留原 route、selection 和 immutable draft，macOS
  context menu 按其所属 row ID 删除，不误删当前选中项。
- Recognition 操作跨 route 存活，Provider/model 只从 Workflow 投影的已配置/
  可用项中选择，识别前先 flush，权限 URL 覆盖整个操作生命期。Resolve CSV
  使用唯一允许的 `NSTableView` bridge，通过 stable row/column/revision 值编辑
  10,000 行表格，cell commit 固定为 250 ms，delegate 在 teardown 时解绑。
- 全局 Settings 已分为 General/Providers/Recognition/OCR/Advanced，自定义
  Provider 支持完整 CRUD、revision 递增、transport/JSON/image detail、手动模型、
  discovery/probe 与取消。凭据只在 view-local secure field 短暂存在，保存后清空
  且不进入 observable model、日志或错误。
  Paddle installer 使用 bundle 内固定 `paddlepaddle==3.3.1`/
  `paddleocr==3.7.0`，固定 5/20/35/90/100% stages、30 分钟 timeout、single-flight、
  sanitized environment、受管路径/symlink 拒绝与 TERM→2 秒→KILL。
- Persistence 的 actor-owned JSONL 日志使用每日文件、0700/0600、`flock`、
  7 日保留、默认 500/上限 2,000 和 3 秒 UI polling；写入前统一脱敏，坏行按
  degraded 跳过。Help 为恰好 6 个 bundle-local 中文 section，无 WebView/网络/分析。
- `SlateSyncUIUnitTests` 使用临时根、fake process 和无网络 fixture，13 项专项测试已覆盖
  autosave latest/retry、route/Library mutation failure barrier、并发 terminate join、10k 末行编辑、
  recognition result flush、Provider 创建/修订/discovery/probe、日志权限/filter、6-section Help
  和 Paddle 固定阶段/环境/symlink/cancel-drain。`sm08_contract.mjs`
  将源文件 SHA、500/1,000/10,000 fixture、全部验收 ID、已执行测试、模块
  依赖和 AppKit allowlist 纳入 fail-closed Gate；`phase_gate.sh SM-08` 同时保留
  Swift/Xcode/Release/Archive/隔离启动及 Electron/Modern/Node/ABI 兼容矩阵。
- 本轮实现检查点已提交；仍未修改 `CURRENT_STATE.json`，该提交不是
  SM-08 formal review commit，也不将 diagnostic/后台证据解释为 COMPLETE。待全部验证
  收敛后，仍需 clean Gate、独立 review 与 Owner approval 才能进阶 SM-09。

## 2026-09-05 SM-08 / SM-09 详细施工包（规划完成，尚未开工）

- 已将 `.codex/swift-migration/packages/SM-08.md` 从阶段摘要细化为 WP-0～WP-9：
  行为/fixture/性能预算冻结、UI façade 与 window-scoped session、Project Library、
  Workspace/Task/单一 autosave、Recognition、10k `NSTableView` CSV editor、全局/项目
  Settings、Provider/Vision/Paddle、文件日志/Help，以及 A11y/IME/multi-window/lifecycle/
  performance 与正式 Gate。
- SM-08 固定 500 ms Workspace autosave、250 ms cell/result commit、500 projects、
  1,000 tasks、10,000 editable CSV rows、3 秒日志刷新、7 日保留和 500/2,000 read limit；
  AppKit 只允许 CSV table、必要 file panel 与 async termination/reopen 的窄桥，业务真相仍在
  Swift actors/façades。
- 已将 `.codex/swift-migration/packages/SM-09.md` 细化为 WP-0～WP-9：最终 inventory、
  删除前完整兼容矩阵、Xcode/资源/版本/签名、Universal archive/ZIP/DMG、Swift-only CI、
  Developer ID/公证 lane、Electron/React/Node production-input cutover、data/package/upgrade
  audit、文档/smoke 和最终治理。
- SM-09 使用 pre-cutover 与 final native cutover 两点证据链；旧 Node/Electron oracle 只有在
  完整矩阵 PASS、replacement coverage 与 source hash 封存后才可删除。`.codex/refactor/**`
  原样保留；Paddle Python runner/requirements 迁为唯一原生 App resource，不与 Node 输入
  一起误删。最终 CI/Gate/Release 不再依赖 node/npm/npx。
- ad-hoc Archive 只证明本地/PR 可构建签名，不能宣称 Gatekeeper-ready。正式外部分发另需
  Developer ID、notary Accepted、staple/validate、`spctl` 与已发布 artifact smoke；缺凭据按
  `BLOCKED_ENV`/同 commit 等价 CI evidence 处理，不允许静默降级后继续发布。
- 两份施工包都只是计划：当前 `CURRENT_STATE.json` 仍合法停在 SM-06 `COMPLETE`；
  SM-07 的 formal clean Gate 已在 review commit
  `5001aa4319e443bddde87fe837dfcd4692be01b9` PASS，但 Owner approval 仍为 PENDING。
  因此 SM-08/09 均保持 `NOT_STARTED`，本轮未改产品/测试/Gate/CI/Release/阶段状态，未删除
  legacy 输入，也未生成或发布 artifact。

## 2026-09-05 历史产物完整清理（当前有效）

- 复核当前分支全部可达提交；保留产品/打包输入、可执行测试夹具、
  视觉基线与 Markdown 审查摘要，删除原始运行截图、逐轮 manifest、完整
  终端日志、可再生成性能/smoke JSON、Icon Composer 导出和旧图标迭代。
- Renderer、Electron Dock/窗口、README 和打包统一使用
  `build/slatesync.icon/Assets/icon.png`；其它图标副本不再跟踪。
- 性能、Electron smoke 和现代/旧视觉捕获的默认输出统一迁到已忽略的
  `test-results/refactor/`；`repository-hygiene.test.mjs` 防止上述原始产物被重新跟踪。
- 本次使用新清理提交，不改写已共享历史；历史提交中的 blob 仍保留，
  如需减少 clone 历史体积须单独授权历史重写。

## 2026-09-05 SM-06 二进制夹具清理（当前有效）

- SM-06 功能提交中的媒体文件属于测试输入夹具，不是 Gate 关键证据；
  正式 Gate 日志与产物仍保持在 Git 忽略的 `.codex/gate-results/` 中。
- 删除 Workflow 测试目标下未使用的 `sm06-integration.jpg` 和与
  Media 夹具字节重复的 `sm06-integration.pdf`；Workflow 测试改为运行时
  生成最小单页 PDF，不依赖外部工具、网络或用户文件。
- 保留 `SlateSyncMediaTests/Fixtures/SM06` 中被测试直接使用的最小媒体矩阵，
  继续覆盖 PNG/JPEG/WebP、EXIF/透明度、PDF 页数/旋转/裁剪/密码/损坏与异常
  bounds；manifest 仅冻结这些实际测试资源。

## 2026-09-05 SM-07 Provider 与识别实施（clean Gate PASS，Owner approval 待定）

- 用户已单独授权 SM-07 代码施工。已在 Domain 建立 secret-free Provider/
  recognition 执行值、稳定错误和单一 TakeStatus adapter；Persistence
  通过 `RecognitionPersistence` 继续使用 ProjectRuntime 租约写入 task、
  diagnostic 和活动时间。
- Workflow 已实现五个 Provider 与固定模型 catalog、revision-aware registry、
  15 秒/5 分钟模型发现、项目无关的冻结 PNG 视觉探针、Responses/Chat
  payload 及 schema→object→prompt 窄降级。实时价格只用于派生公开
  value 评级，原始 price/cost 不离开发现边界。
- `URLSessionProviderTransport` 由 actor 单一持有 session/task/deadline；只在
  header 构建时读取 Keychain，timeout 才重试，完整 body 与 headers 共用
  deadline，cancel/close 等待排空。URLProtocol 实测确认跨 origin redirect
  不携带 Authorization；response body 安全上限冻结为 16 MiB。
- 三个中文 system prompt 与 full/core schema 已与保留 JS oracle 逐字/
  canonical JSON SHA-256 对齐。已接通结果容错规范化、跨页继承、
  sandwiched/dropped-shot-tens 修复、高精度 primary＋audit＋定向
  review 以及有界逐页并发。
- `RecognitionCoordinator` 已接通 SM-06 OCR-first 媒体、Scenario 选择、
  UTF-8 请求预算、单调进度、全局 fail-fast limiter、按项目取消、
  持久化尾段和 single-flight close；原始 PDF 在 prepare/OCR/network/
  persistence 任何副作前拒绝。
- `Fixtures/SM07` 已冻结 12 个旧源 SHA、prompt/schema/探针哈希、
  redirect/页失败策略和 57 个验收 ID。SM-07 contract 已接入统一 Gate，
  Gate 自测已扩展为 79 项并通过。
- 实施收尾验证为 SwiftPM 167 项（0 失败、1 项按设计跳过），SM-07
  专项 28 项；其中独立验证错误视觉 marker 必须失败，主动取消探针
  batch 必须排空请求且不落库。Xcode 共享 Test Plan、SM-05 技术回归、Electron/Modern
  兼容、TypeScript 静态/类型/构建和 Node SQLite ABI 均通过。最新
  dirty diagnostic Gate 为 `PASS/approvable=false`，证据目录为
  `.codex/gate-results/SM-07/20260905T122916Z-d65a6063fe80/`。
- 治理状态依旧保留 `CURRENT_STATE.json` 中已批准的 SM-06 COMPLETE。
  SM-07 dedicated review commit 为
  `5001aa4319e443bddde87fe837dfcd4692be01b9`；该精确 SHA 的 formal clean Gate
  已 PASS（20 项 PASS、`approvable=true`），review report 已完成。Owner 最终批准仍为
  PENDING；只有批准和治理提交完成后，才可把 SM-07 转为 `COMPLETE` 并开放 SM-08。

## 2026-09-05 SM-07 Provider 与识别详细施工包（历史规划记录）

- 已将 `.codex/swift-migration/packages/SM-07.md` 从两行阶段摘要细化为 WP-0～WP-9：
  行为/fixture 冻结、Domain 与 TakeStatus adapter、Provider registry、URLSession
  transport、模型发现/能力探针、prompt/schema/payload、结果规范化、高精度逐页复核、
  OCR-first 总编排/持久化和正式 Gate。
- 准入以 `CURRENT_STATE.json` 和 `reviews/SM-06.md` 为准：SM-06 已正式 COMPLETE，
  审查提交为 `3ba200cafad758b10ad51c08eace5024bcffa90e`。迁移 README 中旧的
  SM-06 IN_PROGRESS 文字已同步为完成状态。
- 施工包冻结五个内建/兼容 Provider、Responses 与 Chat Completions payload、15 秒
  discovery、5 分钟 cache、30 秒合成视觉探针、180 秒单次模型 timeout、默认一次
  timeout retry、逐页并发 2、全局 fail-fast 并发 1，以及结构化输出降级条件。
- 三个中文 system prompt、full/core schema、custom/CSV/Scenario 拼接顺序、字段/状态
  规范化、高精度 primary＋audit＋target review、跨页继承和两类序列修复均要求在写
  Swift 前生成独立 oracle，不能以 strict Codable 或 URLSession 默认行为改掉兼容语义。
- SM-07 直接消费 SM-06 的图片/OCR evidence，拒绝原始 PDF；legacy `_OK`、`_KP`、
  `过`、`保`、`ng`、`x`、`×` 等在单一 adapter 转为 `TakeStatus`，不修改 SM-05
  merger 的 CSV 真相。
- 所有 transport、discovery、probe、timeout、retry、fallback、取消、迟到响应和
  persistence await-boundary 使用 deterministic URLProtocol/fakes 与临时 Library 验收；
  正式 Gate 不需要真实 Provider key 或公网，也不得访问用户默认 Library。
- 本节保留了当时“只生成施工包”的历史记录；后续实施授权和
  实际进度以上方 IN_PROGRESS 章节为准。

## 2026-09-05 SM-06 媒体与 OCR 实施（已正式完成，COMPLETE）

- 用户已授权按 SM-06 施工包实施。Domain 增加图片/页面/OCR evidence、配置、
  deadline、取消和进程协议；Media 负责原生 PDFKit/ImageIO/CoreGraphics、
  Vision 和受管 Paddle；Workflow 提供无网络的 OCR-first 组合与 Scenario adapter。
- 保留 20 MiB、20 页、整页＋两张重复表头局部 JPEG、三档不可变压缩、0.94
  完整 UTF-8 请求预算，以及旧 JS 的几何、设置、LTRB、UTF-16 evidence 行为。
  原始 PDF 与下游图片 DTO 分离；历史 `pdfDataUrl` 在下游调用前拒绝。
- Vision 默认内建、串行处理视图；显式 binary 使用旧协议。Paddle 复用未改写的
  Python runner，实行单 worker、单次预热、共享排队/恢复 deadline、generation
  和 TERM→1000 ms→KILL→退出等待。取消/关闭等待实际资源排空，不回填缓存。
- 每引擎 8 项 LRU 按会话、页面/视图分组、顺序、图片和有效配置隔离；required
  OCR 失败阻断，optional 明确降级，取消终止。Scenario v1 指纹保持不变；
  `_OK`、`_KP`、`过`、`保`、`ng`、`x`、`×` 的 TakeStatus 映射留给 SM-07。
- 已冻结旧 JS/Swift helper 来源哈希、独立 oracle、媒体样本及 35 个验收 ID。
  Gate 检查真实测试日志、夹具完整性、旧阶段技术回归和批准前后的合法阶段状态。
  Xcode 资源复用同一 runner 文件，离线 Paddle 验收实际使用 App bundle 内的副本。
- 用户明确提供另一个工作区的 `.venv-paddleocr`，并确认同级 `.paddlex-cache`。
  所需 v5 模型已复制到独立临时目录，源 runtime/cache 只读；运行时 HOME/cwd/cache
  显式隔离，由操作系统禁止网络，不安装依赖、不下载模型。v6 命名 preset 仅按
  仓库冻结参数验证，未声称已有 v6 模型实测。
- 最终 dirty Gate 为技术 PASS：27 项检查通过，SwiftPM 139 项（通用运行 138
  通过，专用离线 Paddle 补跑 1 项通过）、Xcode 3/3、Node 323/323、Modern
  118/118、Gate self-tests 78/78；真实 App、Universal Release/Archive 与 ABI
  验证均通过。证据目录为 `.codex/gate-results/SM-06/20260905T074810Z-0429abf0980a/`。
- Gate 另修复 Xcode 通用失败横幅覆盖已解析环境分类的问题；真实断言仍优先。
  后台 `--verify` 显式注入临时数据根，并沿用 UI 测试的忽略窗口恢复参数，
  避免旧菜单栏会话使项目库视图从未加载。普通启动方式保持现有行为。
- Review 提交前审计确认 PDF fixture 的 xref 尾随空格属于冻结二进制内容；根目录
  `.gitattributes` 将 `*.pdf` 标记为 binary，避免文本清理破坏 manifest 哈希。
- 详细结果、模型/fixture 哈希及资源测量见 `.codex/swift-migration/reviews/SM-06.md`。
  后续正式 Gate 已在 review commit `3ba200cafad758b10ad51c08eace5024bcffa90e`
  通过并获 Owner 批准；`CURRENT_STATE.json` 已记录 SM-06 COMPLETE。上方 dirty
  Gate 仅作为实施期诊断历史保留，`.codex/refactor/` 历史不变。

## 2026-09-05 SM-06 具体施工包（规划完成，尚未开工）

以下保留原始规划记录；当前进度以上方实施章节为准。

- 已将 `.codex/swift-migration/packages/SM-06.md` 从阶段摘要细化为 WP-0～WP-8：
  行为/夹具冻结、Domain 与依赖协议、原生 PDF/图片解码、裁剪/多视图/压缩、Vision、
  Paddle 受管进程、OCR 选择/降级/缓存/evidence、Workflow 组合与正式 Gate。
- 准入读取 `CURRENT_STATE.json` 和 `reviews/SM-05.md`：SM-05 已正式 COMPLETE，
  审查提交为 `7c36f642632401ac21ff97316f1f3a9c1e8e6530`。下方早期章节及迁移
  README 中的 SM-03/04 进度仅是旧记录，不能覆盖当前审批状态。
- 施工包冻结现有 20 MiB 输入、20 页 PDF、整页＋两张重复表头局部 JPEG、几何参数、
  三档压缩、0.94 请求预算、OCR 参数/坐标/evidence、自动 timeout 和每引擎 8 项 LRU；
  几何/JSON/evidence 做精确差分，跨框架 PDF/JPEG 栅格按预先冻结的内容/容差验收。
- 原生 Vision 默认内建运行，显式 `VISIONOCR_BINARY` 保留兼容适配；Paddle 继续复用
  Python runner，由 Swift 管理 single-flight 预热、串行 worker、共享 deadline、
  generation、TERM/KILL/退出等待和故障 one-shot 恢复。取消不允许恢复或下游降级。
- 交付测试覆盖媒体、Vision、Paddle 进程、OCR 策略/缓存、组合、资源和治理负向案例；
  fake 进程回归与真实 Vision/离线 Paddle 分开验收，真实环境缺失记 BLOCKED_ENV。
  所有测试根、Python/runtime/model cache 显式隔离，不自动下载模型或访问用户数据。
- SM-06 输出只包含页面图片与 OCR evidence；原始 PDF 不进入下游。Scenario adapter
  保留 SM-05 v1 坐标/指纹；legacy take-status 文本转枚举明确交给 SM-07 adapter。
- 本轮仅生成施工文档，未修改产品代码、测试、`CURRENT_STATE.json` 或历史证据，
  未启动阶段实现、未运行阶段 Gate、未提交或推送。后续须经实施、专用 review commit、
  clean Gate 和 Owner 批准，才可宣布 SM-06 COMPLETE。

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
- `SM-01`、`SM-02`、`SM-03` 已完成 Owner 批准；SM-04 施工已获 Owner 授权创建
  dedicated review commit，clean Gate 与最终 Owner 批准仍待执行。
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
- SM-02 已正式完成；本节保留其平台收敛方案作为后续阶段约束。

## 2026-09-04 SM-04 SQLite 与 Project Library v1

- SM-03 已由 Owner 批准并在 `CURRENT_STATE.json` 标记为 `COMPLETE`；当前施工
  包为 `.codex/swift-migration/packages/SM-04.md`，治理状态在 SM-04 正式批准前
  继续保留 SM-03 COMPLETE。
- `SlateSyncPersistence` 使用系统 SQLite3 保留 v1 的三个数据库文件名、完整
  Library/Project schema、WAL、foreign keys、5 秒 busy timeout、目录/文件权限和
  JSON 兼容快照；`SQLiteDatabase.rows` 只在 `SQLITE_DONE` 时返回完整结果。
- Project Library 继续只持有项目索引；每个项目独立持有 task、diagnostic 和
  scenario 数据库内容。旧全局数据以只读源一次性迁入 `project-default`，源数据
  不删除、不改写。
- v1 传输层保留 `.slatesync-project` / `.slatesync-library` 后缀、manifest 与
  数据库校验；导出在临时目录中用 SQLite online backup 生成无 WAL 依赖的
  单文件数据库，校验后原子发布。导入项目生成新 ID，并统一换绑
  `project_meta`、task/diagnostic JSON 及有效快照的归属。
- Library 激活/迁移在返回 `restartRequired` 前先保存 `settings.json.libraryPath`，
  再排空并关闭项目 runtime 与 Library SQLite 连接。原生 App composition root
  已改用惰性启动服务：重启后读取该路径，自定义便携 Library 保持原址，
  仅已知历史默认目录可迁移，新旧默认目录冲突时继续使用已持久化目录。
- 项目删除由 `ProjectRuntime` 租约和 Library tombstone 两层保护：先拒绝新操作并
  等待/关闭项目 SQLite owners，再改名、删索引；索引失败恢复目录，物理清理失败
  留待下次启动重试。
- `ProjectRuntime` 作为唯一项目租约入口，已暴露 task 的 create/update/list/load/delete、
  diagnostic 的 create/list/load/delete 和 scenario 的 import/read/observation；所有修改均在
  同一租约内完成，避免后续 workflow 绕开删除/关闭边界直接开库。
- 自动测试全部使用显式临时目录，覆盖复制 v1 Library 的读写/关闭/重开、未知 JSON
  字段、快照迁移、诊断保留、场记外键、legacy marker/source preservation、删除补偿，
  以及开放连接下的项目包/Library 导出、重复导入换绑、链接/路径防护、激活关闭顺序和
  重启后的 Library 路径选择/历史默认目录冲突语义。
- Owner 已明确授权本次 dedicated review commit；该授权不等于最终阶段批准，
  提交后仍需在精确 SHA 上通过 clean Gate、写入 review report 并由 Owner 单独批准。
- 补齐启动 composition root 后的最新 dirty diagnostic Gate 为全技术检查 PASS：SwiftPM
  88/88、Xcode Test Plan 3/3、Node 323/323、Modern 118/118，Debug/静态/类型/
  生产构建与 Node/Electron SQLite ABI 均通过。证据为
  `.codex/gate-results/SM-04/20260904T144246Z-b5eed3db5d2e/result.json`；该结果产生于
  review commit 之前，仅是 `approvable=false` 的诊断证据。
- 对首个 review commit `b23a83efd9c0fbed611e37b8391e7b14b06b8337` 的代码审查
  发现 actor 重入会重复 bootstrap、项目 close/delete 标记可被并发调用提前清除、
  runtime close 非单航班且等待 Library 查询的 acquire 可在关闭后重开 context、
  Library rename 未先排空快照写入、激活操作可并发提交、
  Scenario 重复导入可能触发唯一约束，以及传输遍历/Gate UI runner 分类未完全
  fail-closed。上述问题已修复并补充回归，Owner 已授权生成新的 review-fix
  commit；旧 commit 的 clean Gate 证据不再可用于最终批准。
- 修复后的最新 dirty diagnostic Gate 全技术检查 PASS：SwiftPM 96/96、Xcode
  Test Plan 3/3、Node 323/323、Modern 118/118，Debug/静态/类型/生产构建与
  Node/Electron SQLite ABI 均通过；证据为
  `.codex/gate-results/SM-04/20260904T163751Z-b23a83efd9c0/result.json`。该运行因
  工作树含未提交 review 修复而按设计为 `approvable=false`。新的 review-fix commit
  已获 Owner 授权；只有新 SHA 的 clean Gate 与最终 Owner 批准都完成后才可推进
  `CURRENT_STATE.json`。
- Owner 授权后已生成 review-fix commit
  `69411f5a956ea1807715b32055cb74e6984e96c0`。该 SHA 的首次 clean Gate 只在
  Xcode UI 测试失败；xcresult 附件显示 UI Test Runner 因位于 Desktop 下的
  仓库内而触发 macOS“桌面文件夹访问” TCC 弹窗，产品窗口和按钮在弹窗前
  已成功出现。Gate 现将 DerivedData、UI runner 和运行中 xcresult 置于系统
  临时目录，运行结束后再由 Gate 父进程把完整 xcresult 移入证据目录；
  端到端夹具会防止 runner 路径退化回受保护的仓库。修复后 Gate helper
  71/71，完整 dirty diagnostic Gate 的 SwiftPM 96/96、Xcode Test Plan 3/3、
  Node 323/323、Modern 118/118 及其余技术检查全部 PASS，证据为
  `.codex/gate-results/SM-04/20260904T165538Z-69411f5a956e/result.json`；
  其 `approvable=false` 仅因修复未提交。该修复保持未提交，需单独请求提交授权。

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

## 2026-09-05 SM-05 详细施工计划（规划完成，尚未开工）

- 已将 `.codex/swift-migration/packages/SM-05.md` 从阶段摘要细化为 9 个工作包：
  兼容行为/夹具冻结、Domain 与服务合同、CSV 字节兼容编解码、字段与素材编号规范化、
  Resolve 合并/稀疏编辑/独立导出、元数据解析与有界目录扫描、Scenario Profile 学习/
  指纹/相似度/原子匹配，以及后台服务组合、性能门禁和正式阶段验收。
- 实施顺序设置了逐级停止门禁：先冻结 JavaScript 行为和 SHA-256，再完成 typed contract，
  依次通过 CSV codec 字节 golden、规范化纯函数、合并/导出 golden、元数据树夹具、
  Scenario 指纹与 SQLite 原子事务，最后才允许服务集成和 Phase Gate；底层 golden 失败时
  不得用上层集成掩盖。
- 测试目录细化为 CSV 8 组、合并/导出 11 组、元数据 10 组、Scenario 12 组，并规定
  所有文件系统/SQLite 测试只使用 checked-in fixture 与临时目录，不读取真实用户
  Application Support、Project Library 或媒体卷。Swift fixture 副本必须由
  `sm05_contract.mjs` 与现有 Node baseline manifest 做长度和哈希一致性审计。
- 10,000 行 Release 性能样本使用固定 seed：12 列、四机位、80% 匹配、10% 未匹配、
  5% 重复行、5% 冲突/非法标识、1% 稀疏编辑并混合引号/分隔符/内嵌换行；输出行数、
  列序、字节长度和 SHA-256 固定。1 次预热后测 5 次，要求 10k 中位数不超过 2 秒、
  单次不超过 5 秒，且 10k 中位数不超过同源 5k 前缀中位数的 2.5 倍。
- 边界保持不变：复用 SM-04 v1 SQLite/项目租约，Scenario create/reuse、sample count 和
  observation 必须在一个既有 schema 事务内提交；本阶段不引入 schema v2，不实现
  SM-06 媒体/OCR、SM-07 Provider/识别编排、SM-08 UI 或 SM-09 Electron 删除/发布。
- 本轮只生成计划并记录项目方案，未修改产品代码、`CURRENT_STATE.json` 或
  `.codex/refactor`，未开始 SM-05 生命周期、未运行阶段 Gate、未提交或推送。

## 2026-09-05 SM-05 工程实施（未提交）

- 已完成 Swift 原生 CSV/metadata/Scenario 后台服务：Resolve CSV 编码、BOM、
  分隔符、换行、引号和最终换行保真；NFKC/中文数字/场镜次/素材 key 规范化；
  索引化合并、一对多回填、重复/冲突仲裁、稀疏编辑、相机元数据对账、序列异常与
  UTF-16LE 独立导出。
- 已完成 Kinefinity `slate.txt` 注册式解析、dirname/fixed-name 结构学习与只读有界
  扫描；根目录、深度、文件大小、预期 key、符号链接、取消检查及结果排序均已收紧，
  测试仅使用 SwiftPM fixture 和临时目录。
- 已完成 Scenario Profile v1 observation/layout/aliases/regions、稳定 JSON/SHA-256 32 位指纹、
  六位小数加权相似度、Profile 归一化/提示、阈值/歧义匹配，并在 SM-04 v1 schema 上将
  create/reuse、sample count、last used 与 observation 写入收敛为一个 SQLite 事务；
  并发相同观察、失败回滚、关闭重开和跨项目隔离已覆盖。
- `Tests/SlateSyncWorkflowTests/Fixtures/SM05/coverage.json` 将 CSV-01…08、MRG-01…11、
  META-01…10、SCN-01…12、PERF-01 与 SVC-01 映射到可执行测试；冻结 CSV 副本
  逐文件 SHA-256 与 Node baseline 一致。当前 SwiftPM 共 111 项测试全部通过，
  其中 SM-05 Workflow 17 项。
- PERF-01 使用固定 10,000 行、12 列、四机位、80% 匹配、10% 未匹配、5% 重复、
  5% 冲突/非法、1% 稀疏编辑工作负载，输出 SHA-256 为
  `ad23d3d8236478d658cfa72a45b7703ba5f9ffc3eab8ebf27bcd644cbb7ad227`。Gate 中
  Release 5k/10k 中位数分别为 0.674611/1.376391 秒，10k 最慢 1.390325 秒，
  缩放比约 2.040，通过 2.0/5.0/2.5 秒/比例门槛。
- `./script/phase_gate.sh SM-05 --allow-dirty` 于当时工作区上通过 SwiftPM、
  Xcode Debug/Test Plan、SM-05 contract、Release 性能、Node/Modern、check/typecheck/build 与
  native ABI 全部关键检查；最终证据目录为
  `.codex/gate-results/SM-05/20260904T181344Z-523fd49790a3`。连续 Gate 运行曾暴露 SwiftUI
  窗口恢复可只启动菜单栏，UI 测试现显式禁用持久化窗口恢复，连续两次 Test Plan 及最终
  Gate 均通过 3/3。本轮仍保持未提交。因用户明确要求不自动 commit，
  未生成正式 clean review commit/审查报告，也未更新 `CURRENT_STATE.json`；诊断 Gate
  因 `--allow-dirty` 正确记录为 `PASS` 且 `approvable=false`，这不代表 Owner 阶段批准。

## 2026-09-05 SM-05 施工复审修复（未提交）

- 已将 GLM 复审与本地逐行复审重新对照 `public/resolve-csv.js`、
  `lib/scenario/profile.mjs` 和 `lib/scenario/store.mjs`。关闭四类 P2：多 reel 与多素材
  告警按首现序稳定输出；卡号/视频码不再额外 NFKC；observation JSON 恢复 v1 顶层
  Profile 键；sidecar、记录分组、两阶段字段规范化及显示名回退恢复 JavaScript 顺序/文本。
- 同时关闭复审发现的边界：Scenario 匹配经 `ProjectRuntime` 项目租约持久化，平分保持
  `last_used_at DESC`，similarity 自行归一化；orientation、pageNumber 与 UTF-16 长度规则
  对齐；CSV 限定合法分隔符且不把 U+2028/U+2029 当换行；合并与独立导出补齐
  `CSV_NO_EXPORT` 闸口，稀疏编辑改为有序 typed list 并保留原始空白。
- 新增并冻结 metadata、scanner-tree、Scenario observation、performance 资源及 SHA-256
  manifest；资源使用唯一文件名以适配 SwiftPM 扁平打包，缺失时测试失败而非 skip。
  `sm05_contract.mjs` 现在审计所有五类 fixture、关键差分测试和 ProjectRuntime 租约路径。
- 保留并在 SM-05 包文档记录三项后续边界：扫描根无效时 native 继续 fail-closed；
  legacy take-status 字符串归一化由 SM-06/07 adapter 衔接；畸形 canonical key 的
  `localeCompare` 差异不扩展到有效业务 key。
- 复审后验证：SwiftPM 完整套件 113/113、SM-05 定向 19/19、
  `node script/tests/sm05_contract.mjs` 与 `git diff --check` 全部通过。未生成 review
  commit，未更新 `CURRENT_STATE.json` 或 `.codex/refactor`，也未将诊断 dirty Gate
  解释为阶段批准。
- 复审修复后的诊断 Gate `./script/phase_gate.sh SM-05 --allow-dirty` 全项 PASS：
  SwiftPM 113/113、Xcode Test Plan 3/3，Node/Modern/typecheck/build/native ABI 均通过；
  Release PERF-01 的 5k/10k 中位数为 0.794756/1.575901 秒，10k 峰值 1.597848 秒，
  缩放比约 1.983。最新证据目录为
  `.codex/gate-results/SM-05/20260904T194114Z-523fd49790a3`；dirty 模式按设计记录
  `PASS/approvable=false`，该本地证据不得提交，也不替代 clean review commit 与 Owner 批准。

## 2026-09-11 本地凭据兼容与项目加密

- `SecurityKeychainBackend` 默认改为 macOS 登录钥匙串，API Key 仍由系统加密保存；
  无 Apple Developer Team / provisioning profile 的临时签名构建不再默认调用
  Data Protection Keychain。保留显式 Data Protection 参数供具备授权的调用者使用。
- 正常启动由 `ProjectLibraryStartupService` 在打开任何项目存储前解锁本地 AES-256-GCM
  密钥并迁移项目库。测试/降级根不访问真实钥匙串；加密专项测试注入内存后端。
- 每个项目库的 `.slatesync-encryption` 仅保存随机密钥标识；32 字节密钥只在登录钥匙串
  与进程内存中。CryptoKit 随机 nonce、认证标签及版本化头保护 SQLite 和 JSON 内容。
  找不到既有密钥或认证失败时停止，不生成替代密钥、不覆盖失败的文件。
- 内部 SQLite 使用内存连接；每次操作在跨进程锁内重新读取加密快照，写操作完成后原子
  替换加密文件。SQLite 临时存储在内存中，不产生新的明文 WAL。此方案每次操作处理整个
  数据库，内存/IO 成本随数据库大小增长，适合当前项目元数据，不用于媒体大文件。
- 旧 SQLite 通过 online backup 读取已提交 WAL 页，再校验加密结果并原子替换；旧 JSON
  快照逐文件迁移，可中断后重试。迁移不会擦除历史系统备份/APFS 快照/SSD 已释放块。
  升级迁移期间应关闭其他旧版 SlateSync，旧版不理解新的加密格式。
- 标准项目包、项目库导出通过解密读与 SQLite backup 生成通用 v1 文件，不包含密钥或加密
  标识；导入到加密库时重新加密。激活新的本地项目库时继承加密策略。
- 范围：项目库索引、项目设置/记录、任务、诊断与场记 Profile，以及对应 JSON 快照。
  原始媒体、媒体缓存、导出的 CSV/项目包、机器级非敏感配置和日志不在此范围。
- 加密库依赖本机钥匙串。跨机迁移应使用应用内导出；丢失钥匙串后只能从可用导出恢复，
  不能仅凭复制的加密目录恢复。不要将内部加密目录当作通用项目包交给旧版本。
- 验证：SwiftPM 持久化回归与新增加密测试；Xcode 随机 service/account 的真实钥匙串
  create/read/conditional-delete 测试通过，构建签名为 ad-hoc 且无 Team ID。
- 最终验证结果：177 项 SwiftPM 持久化/工作流测试全部通过（含 4 项加密专项：旧库与
  快照迁移、标准导出/重新导入、并发连接/篡改、WAL/只读保护、缺失密钥保护）；
  1 项 Xcode 真实钥匙串测试通过。`script/build_and_run.sh --verify` 构建和启动通过。
  启动后只检查文件头，确认现有库 96 个 SQLite/JSON 文件全部加密；原项目列表正常，
  OpenRouter 凭据弹窗不再出现 -34018。未读取或填写用户 API Key。

## 2026-09-11 启动钥匙串授权优化

- App Debug/Release 使用 `Configuration/Signing.xcconfig`，引用被 Git 忽略的
  `LocalSigning.xcconfig` 中的本机证书指纹。`script/setup_local_signing.py` 幂等创建/复用
  自签名代码签名身份，私钥仅保留在登录钥匙串；用户级信任仅限 codeSign。
  `build_and_run.sh` 启动前检查身份、构建后核对实际证书，缺失身份不得退回 ad-hoc；
  显式 `SLATESYNC_TEST_ROOT` 或测试命令 `CODE_SIGN_IDENTITY=-` 保留隔离测试路径。
- KeychainBackend.status 仅查询属性，并设置禁止认证 UI；configured/missing/
  authorizationRequired/unavailable 分别投影为已配置/缺失/需要授权/读取失败。
  全局设置只取一次属性状态快照供 ProviderRegistry 和设置状态共同使用。
- KeychainCredentialStore 合并同 Provider 的在途秘密读取，成功后只在进程内缓存。
  保存/删除按 Provider 排队，读写版本防止旧读取覆盖新值；失败写入不发布新缓存。
  授权取消或拒绝会锁住自动读取，新的用户模型刷新/探测/识别动作才允许重试。
- 项目密钥按 ID 合并解锁，已解锁时不重复读取钥匙串；新的项目库使用进程内稳定候选 ID，
  避免首次取消后不断生成新 ID 绕过错误缓存。显式项目库“重试”清除解锁失败状态。
  既有密钥 ID/钥匙串条目/加密格式不变；已加密文件启动校验不再为迁移重复加密。
- 启动发现 legacy provider-keys.json 仅报告 awaitingAuthorization，用户在设置中点击
  “迁移旧凭据”才执行会读取秘密的旧凭据迁移；已迁移用户没有新增操作。
- 真实回归脚本 `script/verify_local_keychain.py` 仅使用临时独立钥匙串和固定签名测试 App：
  三次独立进程读、重新编译后的相同 designated requirement、拒绝不同签名访问、
  属性查询不弹窗、锁定失败与解锁恢复。不会修改登录钥匙串现有凭据或放宽其 ACL。
- 首次换成固定签名，已有项目密钥/API Key 可能分别要求用户选择“始终允许”；系统弹窗
  由用户本人操作。以后钥匙串锁定、证书更换或授权撤销仍可要求重新授权。
- 验证结果：269 项持久化/工作流/UI 回归中 268 通过、1 项原有显示器时序测试跳过；
  后续启动迁移/解锁/所有权 66 项全部通过。UI strict audit 零 findings。
  本地签名探针完整通过；真实 App 构建、最终证书核对及脚本启动通过，原项目列表与
  Provider 设置正常加载。未填写或打印用户 API Key，首次系统授权由用户自行处理。

## 2026-09-11 未提交改动审查修复

- 项目库校验在目录与符号链接检查通过后，先解锁目标库的既有密钥，再读取加密清单。
  此路径不创建密钥、安装标识或执行迁移；解锁失败保留 `PROJECT_UNLOCK_REQUIRED`
  和可重试状态。用户重新选择导入库时允许重新授权，后台校验仍保留拒绝缓存。
- 新增回归覆盖：重启后仅解锁 B 时重新校验 A、缺失密钥后的显式重试，以及校验便携库
  不改变其明文格式；既有加密库校验前后的数据库与清单字节保持一致。
- CI 与发布候选共用的 Gate 显式传递 `CODE_SIGN_IDENTITY=-`，覆盖 Debug、Release、
  Archive、XCTest 和打包验收测试宿主。正常开发构建继续使用本机稳定签名；无需在
  GitHub runner 安装个人证书。Gate 命令夹具新增签名参数断言。
- 验证：18 项加密/钥匙串/项目库转移 SwiftPM 测试通过；126 项 Gate helper 自测通过；
  Xcode 实际 Debug 构建设置确认为 `CODE_SIGN_IDENTITY = -`、Manual；脚本语法和
  `git diff --check` 通过。本轮未运行完整 SM-09 Gate、UI 测试或发布构建，未提交。


## 项目打开与居中进度修复

- 项目列表通过 SwiftUI `contextMenu(forSelectionType:primaryAction:)` 处理原生双击/键盘打开，避免行手势与 List 选择冲突；归档行不触发打开。
- `AppRootView` 的项目打开进度覆盖整个 split view，面板最大宽 360 点、24 点内边距，复用 12 点面板圆角；阶段变化不挤压列表，错误和成功沿用会话状态清理。
- 已加密 SQLite 在打开连接时只认证读取，不重新加密写回；新库与明文迁移仍先持久化。密钥 ID、加密格式与后续写入锁保持不变。

验证记录：`LocalProjectEncryptionTests|SM08OwnershipTests` 共 63 项通过；Debug 构建及稳定签名验证通过。隔离副本实际双击进入工作台、返回项目库后再次双击均成功。Xcode UI runner 因 enabling automation mode 超时未执行测试断言；真实库复测等待用户完成系统钥匙串授权。

## 2026-09-12 内建 Provider 配置与帮助导航优化

- 内建 Provider 列表统一使用“配置…”入口，保留凭据状态、模型刷新/配置能力与发现结果；配置面板改为可滚动内容加固定底部操作栏，展示服务说明、官网/密钥文档、Base URL、协议、模型发现状态及 Provider 支持的高级字段。
- API Key 使用 SecureField，仅允许用户输入或明确删除；空输入保留原凭据，外层空白会被裁剪，纯空白输入会被拒绝。普通配置保存与连接验证分离，支持普通配置已保存但凭据保存失败的部分成功状态，并在保存后清理模型发现缓存。
- OpenRouter 默认地址为 `https://openrouter.ai/api/v1`，站点地址与应用名称分别映射为 `HTTP-Referer` 与 `X-OpenRouter-Title`，应用名称默认 SlateSync；Base URL 不会自动拼接 `/chat/completions`。
- 帮助中心扩展为快速开始、项目与任务、识别与复核、Provider 配置、OCR 配置、Resolve CSV/元数据、日志与恢复七章，支持双语结构化步骤/提示/FAQ/动作/外链。新增类型化设置导航请求，使帮助动作打开设置后能定位、滚动并高亮目标区域，同时保留设置草稿；当前任务的 Resolve CSV 动作使用一次性工作台入口直接选中 CSV 分区。
- 增加 Provider URL 指引、OpenRouter 标题及帮助结构化内容的回归测试；未修改数据格式、识别算法、OCR 算法、SDK 依赖或 Provider 协议范围。
- 验证：SwiftPM 全量 342 项测试通过；新增 URL、OpenRouter Header、帮助结构化搜索与类型化设置导航的定向测试通过；Xcode Debug 构建通过。`-warnings-as-errors` 仍会报告既有 `KeychainCredentialStore.swift:96` 的弃用 API 警告，未在本轮扩大范围修复。
- 本轮编辑的 SwiftUI/工作流/域模型新增了状态、导航、保存边界和协议映射注释；OpenRouter Header 依据官方 Quickstart 文档实现。

## 2026-09-16 任务身份与完成状态一致性

- 原生识别必须绑定已有任务 ID；工作流入口在凭据/OCR/Provider 操作前检查任务存在，
  结果持久化仅允许 patch 原任务。缺失或空白 ID 不再退回新建任务，已删除任务也不会被重新创建。
- 工作台编辑快照同步替换侧栏中相同 ID 的摘要，保留列表数量和顺序；本地场记 CSV
  生成结果后，原任务行立即显示已完成及记录数，搜索投影同步更新，自动保存失败仍沿用草稿重试提示。
- 回归使用真实 SQLite、原生持久化适配器和识别协调器，模拟媒体及 Provider：验证连续两次
  识别与重新打开项目均只有同一个已完成任务，并保留创建时间和媒体；覆盖缺失/空白/已删除 ID
  禁止另建完成记录，以及本地完成后侧栏状态、计数、搜索和后续编辑的身份一致性。
- 当前有效 ID 的识别链路原有测试已通过；截图中的历史同名记录来源尚未复现。
  本次不按文件名自动合并或删除真实项目记录，避免丢失不同任务的输入、配置或校对结果。
- 验证：`swift test --filter 'SM08OwnershipTests|RecognitionStateRegressionTests|SM07CoordinatorTests|ProjectStoresTests'`
  共 76 项通过，`git diff --check` 通过。未调用真实识别 API、修改真实项目数据或重启正在运行的应用。
