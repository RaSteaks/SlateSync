---
version: alpha
colors:
  primary: "#B45309"
  accent-soft: "#F59E0B"
  canvas-light: "#F6F7F9"
  canvas-dark: "#1E2229"
  evidence-light: "#FFFFFF"
  evidence-dark: "#2A2F37"
  success: "#1E7A5A"
  warning: "#7C6A00"
  danger: "#B03A2E"
  success-dark: "#7FC9A9"
  warning-dark: "#E3C36B"
  danger-dark: "#E58873"
typography:
  body:
    fontFamily: ".AppleSystemUIFont, PingFang SC, sans-serif"
  display:
    fontFamily: ".AppleSystemUIFont, PingFang SC, sans-serif"
  data:
    fontFamily: "SFMono-Regular, Menlo, monospace"
rounded:
  small: "6px"
  control: "8px"
  panel: "12px"
  large: "16px"
spacing:
  compact: "8px"
  control: "12px"
  section: "16px"
  panel: "20px"
components:
  focus-light:
    textColor: "{colors.primary}"
  focus-dark:
    textColor: "{colors.accent-soft}"
  canvas-light:
    backgroundColor: "{colors.canvas-light}"
  canvas-dark:
    backgroundColor: "{colors.canvas-dark}"
  evidence-light:
    backgroundColor: "{colors.evidence-light}"
  evidence-dark:
    backgroundColor: "{colors.evidence-dark}"
  status-success-light:
    textColor: "{colors.success}"
  status-success-dark:
    textColor: "{colors.success-dark}"
  status-warning-light:
    textColor: "{colors.warning}"
  status-warning-dark:
    textColor: "{colors.warning-dark}"
  status-error-light:
    textColor: "{colors.danger}"
  status-error-dark:
    textColor: "{colors.danger-dark}"

---

# SlateSync Design

## Overview

SlateSync is a professional film-production utility used for long, detail-heavy
sessions. Its visual North Star is a calibrated post-production workstation:
native macOS structure, graphite instruments, paper-like evidence surfaces and
one restrained tungsten-amber signal color. The signature is a subtle
slate-stripe edge on project identity surfaces; decoration elsewhere stays
quiet.

The product must never resemble a marketing dashboard, neon gaming UI, generic
rounded-card SaaS template, or touch-first iOS port. Dense information remains
legible through alignment, typography and native split-view hierarchy rather
than stacked ornament.

## Colors

`SlateSyncTheme` owns the native runtime mapping of these semantic roles.
Accent uses #B45309 in light appearance and #F59E0B in dark appearance;
canvas uses #F6F7F9 / #1E2229 and evidence uses #FFFFFF / #2A2F37.
Success uses pine green (#1E7A5A / #7FC9A9), warning uses brass
(#7C6A00 / #E3C36B), and danger uses brick red (#B03A2E / #E58873).
The amber accent is an action cue, never proof of success; status retains its
label and symbol. Low saturation and cool-gray backgrounds establish the quiet
visual hierarchy; warning sits about twenty degrees apart in hue from the
amber accent, so a needs-action row never reads as a selected row. Body text and
separators use system semantic colors. Feature views never embed RGB literals. Native sidebar and
window materials remain system-owned. Accent is reserved for current selection,
focus and the primary safe action. Sidebar, toolbar, page-heading, step, log-info
and empty-state icons render in neutral secondary gray; amber appears only on
primary action buttons, focus accents and live signals (recognition progress,
unread dots, locate capsules). Warning and danger remain distinct.

### 配色调整（2026-09-16）

- 整体方向：冷灰阶梯（微蓝调 slate）与单一钨丝琥珀强调；同日更早的暖石灰/
  鼠尾草方向在提交前被本方案取代。
- 浅色用纯白证据面承托原稿，冷灰画布区分工具区域；深色用提亮的石墨灰底
  （画布 #1E2229）与一级面板灰（#2A2F37），整体脱离纯黑以保证文字对比。
  原稿像素不染色，避免影响场记单核对。
- 第三轮（同日）：深色中性阶整体提亮；设置窗口改铺主题画布（原为系统窗底灰）；
  设置分类分段控件不再包玻璃卡片——原生 bezel 已足够，双重描边在深色下呈黑框。
- 主操作、焦点、进度和项目身份统一使用琥珀 accent；状态采用松绿、黄铜、砖红。
  warning 与 accent 拉开约 22° 色相，警告行不会与选中行混淆。
- 图标一律中性：侧栏、工具栏、页首座标、帮助步骤圆点、日志信息点与空态图标
  使用次级灰；琥珀仅保留在主操作按钮（`slatePrimaryActionStyle`）、搜索框焦点
  描边和进行中信号（识别进度、tab 未读点、OCR 定位胶囊）。项目身份仍由
  黑白斜纹承载，项目/页首图标本身不再着色。
- 系统文字、原生选区、侧栏材质和表格继续由 macOS 管理，尊重系统强调色及辅助功能。
- 唯一运行时入口为 `SlateSyncTheme`；AppRootView / SettingsRootView 的 tint 和所有共享
  组件继承它。现有布局、字体、圆角、玻璃及操作流程保持既有契约。

## Typography

Use San Francisco with PingFang SC fallback for Chinese product text. SF Mono is
limited to clips, identifiers, model IDs, CSV data and technical status. Native
Dynamic Type metrics and accessibility sizes override fixed visual ambitions.

## Layout

Use `WindowGroup` with a stable `NavigationSplitView`: source-list sidebar,
task-focused detail, and an inspector/supplementary column only where it reduces
modal switching. Default window size is 1440×900 and minimum is 960×600.
Comfortable and compact density share the same hierarchy. `SlateSyncDensity`
maps comfortable/compact to panel padding 20/12 pt, section spacing 16/12 pt,
list vertical padding 7/3 pt and CSV row height 30/24 pt. Native controls also
follow the same existing `density` preference.

The task rail is 210 pt and can be hidden independently. The workspace retains
Input / Recognition Results / Resolve CSV tabs and a current-task heading.
Input gives the evidence preview the remaining height, with a 300 pt recognition
panel. At workspace detail widths below 900 pt the panel starts hidden and
opens as an overlay; at wider widths it starts inline. Explicit user toggles
are retained for the life of the workspace view. Advanced prompt settings are
collapsed initially. Local slate CSV stays with input; metadata scanning belongs
to Resolve CSV.

Results keep their table in one structural position. Optional original evidence
uses up to 420 pt (40% at wide sizes), appears inline at 900 pt and above, and
overlays at narrower sizes. Paging never implies a row-to-page mapping. Resizing
changes geometry only; explicit layout changes cross the native editor and
existing autosave barriers before hiding content.

Settings has a 780×620 default and a 700×540 minimum, with scrollable native forms
and a native segmented selector for General / Provider / Recognition / OCR /
Advanced. A single flexible content host avoids the fixed ideal size imposed by
the macOS 15 Settings TabView host.
OCR environment diagnostics use native form rows with selectable path/version
details, textual status and SF Symbols; success/warning/error reuse theme colors.
Checks have explicit idle, progress, cancel, failure and stale-result states.
Tables retain their own bounded scroll region, independent of adjacent forms.
Minimum sizes refer to the complete native window. `slateWindowMinimumSize`
measures the owning window's chrome and subtracts it from the content minimum;
the probe never replaces the window, its toolbar or restoration behavior. It
enables the native `resizable` style omitted by the macOS 15 Settings host;
SwiftUI continues to own minimum and maximum content constraints.

## Elevation & Depth

Prefer native materials and separators. Static panels are mostly flat; shadows
are reserved for temporary overlays and raised evidence previews. Avoid opaque
custom fills over a native sidebar.

## Liquid Glass adaptation (2026-09-15)

`SlateGlass.swift` owns the shared Liquid Glass presentation layer. Feature
views choose semantic roles (`panel`, `control`, `prominent`, or `status`) rather
than selecting materials independently. macOS 26 uses the system `glassEffect`
renderer and grouped `GlassEffectContainer`; macOS 15–25 use `regularMaterial`
or `thinMaterial` with the same Slate semantic fills and separator edges.

Native `NavigationSplitView`, sidebar, toolbar, Settings scenes, sheets and
lists remain system-owned. Custom glass is reserved for bounded floating
surfaces such as workspace configuration/progress panels, page summaries,
search/filter strips and Provider status panels. The CSV `NSTableView`, Light
Table evidence canvas, media canvas and dense log rows remain opaque/high
contrast. Glass is never applied per row in a large scrolling collection.

The helper keeps the macOS 15 deployment target through availability checks.
Reduced Transparency uses an opaque semantic fill; macOS contrast and
Differentiate Without Color settings strengthen borders; Reduced Motion avoids
interactive glass motion. Accent, success, warning and danger tints are
semantic only and are not used to decorate every control.

## Shapes

Controls use 8px visual rounding when the native control does not own geometry;
panels use 12px. Pills are reserved for short status badges, never general
buttons or containers.

## Components

`SlatePanelHeading`, `SlateSearchField`, `SlateEmptyState` and `SlateStatusBar`
own repeated headings, local clearable search, empty guidance and feedback.
Status bars preserve feature-owned operation lifetimes and never add toast timers.
`SlateBadge`, `TakeMark`, `LeaderProgress`, `LightTable`, `CredentialChip`, `CapabilityChip` and
`WarnRow` extend the shared kit for the 2026-09-14 workspace direction (dated
section below); every color comes from `SlateSyncTheme`, and each stays quiet
outside its owning business state.
`CapabilityChip` reuses the credential badge's capsule surface for verified,
failed, unverified and attention states; its symbol and label carry meaning
independently of color.
Recognition progress remains visible across routes in the app shell.
Buttons combine safe/danger intent with native emphasis. Forms keep visible
labels and inline recovery. Project rows/cards expose one primary open action and
separate contextual actions. The editable CSV surface is an NSTableView bridge
with stable columns, native selection, IME-safe editing and bounded scrolling.

## Do's and Don'ts

- Do use system commands, toolbars, focus, accessibility labels and reduced motion.
- Do keep action and feedback vocabulary short, direct and consistent in Chinese.
- Do reserve layout space for progress, errors and asynchronous results.
- Don't add gradients, oversized promotional headings or screen-local colors.
- Don't hide actions behind hover or gestures without keyboard/menu equivalents.
- Don't use emoji as functional icons; use SF Symbols.

### 项目打开状态（2026-09-11）

打开项目后，在整个窗口内容中央显示项目名称、当前加载阶段和原生不确定进度条。
面板最大宽度 360 点，内边距 24 点，圆角复用 `SlateSyncTheme.panelRadius`（12 点），带细边框与轻阴影；覆盖层不改变底层列表布局。
名称单行截断并提供完整提示；紧凑/舒适模式分别使用 12/20 pt 内边距。
加载期间禁用重复操作，成功和失败均移除进度；失败保留旧项目及现有错误恢复入口。
状态只属于发起打开的窗口；进度不估算百分比，也不绕过编辑保存屏障。

### 运行性能约束（2026-09-11）

预览缓存仅保留当前页图片，换页和素材替换时更新；进度、主题和布局刷新不得重复创建同一图片对象。
任务列表仅加载摘要，打开任务后才恢复完整编辑数据；视觉反馈不能提前提交项目/任务身份或跳过保存屏障。
启动统计使用只读项目查询，识别本地处理复用标准化排序键；不以减少识别轮次、压缩精度或省略数据校验换取速度。

### 钥匙串授权状态（2026-09-11）

沿用 Provider 行的原有 Label 和项目库错误区域。凭据状态必须区分“已配置”“缺失”
“需要授权”“读取失败”，不能将取消授权显示成缺失。项目库取消解锁后保留错误与“重试”
按钮，自动窗口加载不能重新打开授权弹窗；仅主动重试重置失败状态。旧凭据迁移等待用户
点击“迁移旧凭据”，启动时不执行秘密读取。颜色与字体继续由 SlateSyncTheme 负责。

### 场记工作台界面（2026-09-12）

- 新版延续原生工作站配色，用项目身份与任务层级建立视觉区别；颜色仍由
  SlateSyncTheme 提供，不引入独立页面调色板。
- SlatePageHeading 统一项目库和工作台页首：44 pt 语义图标区域、title2 半粗标题、
  callout 辅助文字；面板仍用 SlatePanelHeading，避免所有区域同等强调。
- 项目库固定概览展示真实活跃/归档数量，下方原生 List 独立滚动与选择。
  行内保留项目识别线，加入 40 pt 图标底座和打开/归档提示符。
- 侧栏显示 SlateSync 品牌与“场记整理工作台”，底部提供原生全局设置入口。
  侧栏底色、选择和键盘行为继续由系统拥有。
- “当前项目”分组标题右侧显示已打开项目名称；名称保持单行、中间截断并提供完整
  悬停提示，未打开项目时不显示占位文字，避免与下方导航项争夺层级。
- 任务栏增加项目任务标题与总数，状态同时使用文字和 SF Symbols；搜索不改变总数含义。
- 保留三段原生工作页、原稿对照、保存屏障、300 pt 配置面板与现有密度规则。
  不新增动画，减少动态效果设置无需额外适配。

侧栏左上角品牌图标采用运行中应用的 applicationIconImage，32×32 pt 原色等比显示；
功能导航继续使用 SF Symbols。

### 单一主题与工作台组件扩展（2026-09-14）

- Slate Workbench 是唯一视觉语言；深色/浅色只是同一语义 Token 的外观 mode，
  不新增主题色，功能视图继续禁止内嵌 RGB 字面量。
- 圆角阶梯的运行时常量由 `SlateSyncTheme` 提供：`smallRadius` 6 / `controlRadius` 8 /
  `panelRadius` 12 / `largeRadius` 16 pt，自定义容器一律使用 `.continuous` 圆角；
  功能视图不得写 7/9/10 pt 局部圆角，药丸形仍只用于状态徽章。
- 新增共享组件（与现有组件并列于 `SlateSyncUI/Components/`）：
  `SlateBadge`（项目身份斜纹左缘，仅用于项目层级）、
  `TakeMark`（待定空心点 / 好条保条铅笔圈 / 作废油笔划线，确认描边 240 ms，遵循减弱动态）、
  `LeaderProgress`（识别进行中的真实页码进度，减弱动态时退化为原生进度条，完成后停止不空转）、
  `LightTable`（灯箱证据容器，页码/缩放/导入控件放在相邻控制栏，纸面内不放表单按钮）、
  `CredentialChip`（凭据四态：已配置/缺失/需要授权/读取失败）、
  `WarnRow`（告警行 dim 底 + 3 pt 左缘 + 行尾动作）。
- 片场痕迹按业务状态单点出现：输入页突出灯箱证据，结果页使用铅笔圈/油笔划线，
  识别进行中才显示 LeaderProgress，项目身份只保留低调斜纹边缘。
- 识别完成不自动抢占当前工作页：状态栏给出“识别完成 · n 条结果”与“查看识别结果”动作，
  结果 tab 点亮圆点（含 VoiceOver 文案），用户访问后熄灭。

### Liquid Glass review corrections (2026-09-15)

- Informational surfaces remain neutral, matching their foreground semantics.
- Increase Contrast updates mounted surfaces through workspace accessibility notifications.
- Credential badges retain capsule geometry; custom outlines appear only for accessibility modes.
- Search owns its focus/separator outline; the configuration panel owns its full-opacity leading rule, avoiding duplicate helper borders.
- The library summary uses a canvas-backed fallback, including reduced transparency, distinct from the evidence-surface list.

### 应用语言（2026-09-16）

- 通用设置提供「语言 / Language」，选项以本语言名显示「简体中文」「English」。
  同一语言覆盖所有窗口、应用菜单和帮助，重启后统一生效；不通过替换 View 身份切换语言。
- 英文文案使用同一原生字体、颜色与密度体系，较长说明允许换行，设置表单保留独立滚动。
- `L10n` 与 `Resources/English.json` 是显示文案的统一入口；用户内容、识别提示词与导出格式
  不受界面语言影响。UI 文案与参数覆盖由 `script/audit_localization.py` 和语言回归测试检查。

### Provider 管理与本地凭据（2026-09-25）

- Provider 使用主题证据面承托独立、无阴影卡片；名称、来源、地址与状态分层，
  常显配置和刷新，默认项使用主题 accent 边框。状态和错误始终归属于对应卡片。
- 已添加项优先，未配置内建项默认折叠；读取失败不隐藏已添加项。搜索覆盖名称、
  地址和备注，沿用 SlateSearchField 的即时清除与键盘焦点行为。
- 一个添加弹窗容纳可搜索预设网格与配置表单；返回预设时保留当前编辑器输入。
  主字段优先，高级协议参数折叠，滚动内容与底部保存操作分离。
- 凭据使用 CryptoKit AES-256-GCM 本地文件与独立主密钥文件，不读取旧钥匙串。
  展示仅发布配置状态；API Key 默认隐藏、不回填，查看按钮仅显示当前输入。
  配置和凭据分阶段保存，部分失败保留 Provider 身份并允许重试。
- 与既有规则的协调：将旧 Provider“钥匙串需要授权”的引导替换为本地文件读取
  失败与显式重置；项目库解锁规则保持原样。不增加页面独有颜色或玻璃行。

### Provider 凭据恢复状态（2026-09-25 审查修复）

- 凭据暂时被占用使用时钟图标与 warning 色，提示稍后重试；权限/文件访问失败只提示检查访问权限。仅无法解密或主密钥缺失时说明显式重置选项，仍由原有破坏性确认保护。
- 内建和自定义编辑器共用 ProviderListPresentation 的恢复文案；CredentialChip 承担状态标记。失败状态保持 Provider 可见，不误报缺失。
- 取消属于独立操作状态；密钥已提交但刷新失败保留保存事实。旧 Provider 迁移入口与投影已删除，以上规则替代旧 Provider 钥匙串迁移引导；项目库解锁规则不变。

### Provider 草稿模型列表（2026-09-25）

- API Key 下方提供显式“获取模型列表”，请求当前草稿的 Base URL；原生 checkbox
  将所选模型加入手动 ID，保留手动输入和未在远端返回的模型。
- 列表使用 140 pt 有界滚动区域，加载支持取消；空列表、错误就地反馈且可重试。
  URL/Key 改动或关闭撤销请求。列表获取不代表视觉能力验证，不自动选中或保存。
- 复用原生 Button/Toggle/ScrollView、L10n 和 SlateSyncTheme；保存仍由原有表单负责。


### 模型服务配置流程（2026-09-27）

- 此节更新此前 Provider 编辑器的完成行为与草稿列表主入口：两类服务共享分步编辑器，连接配置、选择/验证和用途设置保持在同一弹窗。保存后继续，不自动关闭；保留仅保存配置，关闭不撤销已保存内容。
- 服务预设预填名称、地址及协议。密钥突出显示，预设地址可展开编辑；高级选项与备注折叠。首次密钥提示粘贴，已有凭据才提示留空保留；不回填已保存密钥。
- 模型使用共享原生搜索、Picker 筛选及 checkbox 列表，分为已验证、待验证、失败/取消、不支持识别；手动 ID 始终可达。仅已验证模型可以设置默认/备用，目录发现不采用成功色证明识别能力。
- 默认和备用以已保存值展示，显式操作立即提交；服务删除使用持续显示到成功的原生 sheet。模型服务页不再提供第二次统一保存，其他设置分类维持原有保存行为。
- 每个阶段保留一个强调主操作。网络工作使用真实阶段或模型计数并支持取消；所有视觉角色继续来自 SlateSyncTheme，不添加颜色、玻璃或布局体系。
- 请求配置变更先解释验证和用途影响，验证后可显式恢复原用途；未保存退出保护仅处理当前草稿，避免让用户误认为关闭会撤销已提交配置。
- 原生 XCUI 验收已完成：9 个场景及中英文 × 浅色舒适/深色紧凑的 700×540 矩阵通过，键盘和 AX 控件状态已确认；独立 VoiceOver 朗读不属于本次已执行范围。
- 模型列表以模型身份驱动单层懒加载行，行视图独立更新验证文案和忙碌状态，避免分组变化遗留旧状态。用途操作固定在底栏，长译文通过 ViewThatFits 换行；备用列表整个标题使用原生 Button 展开/折叠，携带可访问状态。
- 原有窗口探针在有效外观变化时重新恢复 Settings 原生缩放标志；尺寸仍由 SwiftUI 最小宽高约束控制，切换主题后保持可缩放。


### 模型配置审查修复（2026-09-27）

- 需要凭据的内建服务在未配置时停留连接页，尝试联网会定位 Key 字段；仅保存配置继续允许离线完成。匿名自定义服务不受 Key 门控影响。
- Base URL 接口后缀保留 warning 文案，不作为语法错误阻断合法 HTTP(S) 地址；原有地址不自动改写。字段硬错误与建议提示分开。
- 刷新目录显示本次操作结果，不被上一次验证摘要遮蔽；持久证明及对应失败诊断独立保留。静态目录不得把 API 明确不支持的模型降回待验证。
- 角色恢复基线属于操作前意图，按目标服务的撤销范围推导；更换/删除凭据部分失败后仍可继续恢复，外部角色变更仍触发冲突保护。页脚使用实际操作标签，不把读取、删除统一描述为保存。
