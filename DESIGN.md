---
version: alpha
colors:
  # 2026-10-23: the app owns no palette. Every value below is the macOS
  # default of a system semantic color, listed only as a reference; the
  # runtime resolves them from the system (accent follows System Settings).
  accent: "#007AFF"
  canvas-light: "#ECECEC"
  canvas-dark: "#323232"
  evidence-light: "#FFFFFF"
  evidence-dark: "#1E1E1E"
  success: "#34C759"
  warning: "#FF9500"
  danger: "#FF3B30"
  success-text-light: "#1B6E3B"
  warning-text-light: "#8A4B00"
  danger-text-light: "#C4281C"
  success-text-dark: "#63D68A"
  warning-text-dark: "#FFB340"
  danger-text-dark: "#FF8077"
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
  focus:
    textColor: "{colors.accent}"
  canvas-light:
    backgroundColor: "{colors.canvas-light}"
  canvas-dark:
    backgroundColor: "{colors.canvas-dark}"
  evidence-light:
    backgroundColor: "{colors.evidence-light}"
  evidence-dark:
    backgroundColor: "{colors.evidence-dark}"
  status-success-light:
    textColor: "{colors.success-text-light}"
  status-success-dark:
    textColor: "{colors.success-text-dark}"
  status-warning-light:
    textColor: "{colors.warning-text-light}"
  status-warning-dark:
    textColor: "{colors.warning-text-dark}"
  status-error-light:
    textColor: "{colors.danger-text-light}"
  status-error-dark:
    textColor: "{colors.danger-text-dark}"

---

# SlateSync Design

## 极简原生重设计（2026-10-23，取代下文的琥珀 / 片场签名 / 玻璃叠层规范）

方向名"素面 Bare Face"：界面只由系统控件、系统字体、系统颜色和一根发丝分隔线构成。
下文各历史小节凡与本节冲突者（钨丝琥珀、冷灰阶梯、斜纹、铅笔圈、灯箱、扫描盘、
玻璃状态胶囊、侧栏品牌与底部入口、任务栏第二列）均已被取代，仅保留作变更记录。

- **颜色**：`SlateSyncTheme` 全部映射系统色。`accent` = `Color.accentColor`（跟随
  系统设置，只用于选中、焦点和唯一的主操作）；`canvas` = windowBackgroundColor，
  `evidenceSurface` = controlBackgroundColor；`success/warning/danger` = 系统绿/橙/红，
  只用于符号。需要承载状态色的小号文字使用 `successText/warningText/dangerText`
  （浅色 6.3/6.8/5.7:1，深色 9.1/9.4/6.8:1）。状态永远带符号与文字，色相不单独承载含义。
  图标一律中性；视图仍禁止 RGB 字面量。
- **结构**：窗口工具栏承载身份与动作——标题 + 副标题（页数 · 条数 · 状态）、居中分段
  控件（输入 / 识别结果 / Resolve CSV）、右端"主操作 / 更多 / 面板开关"。没有页内
  页首条。任务并入侧栏（项目分组：项目设置 + 任务，新建任务在侧栏底部，顶部搜索，
  失败显示橙色三角，处理中/识别中显示小转圈）；分组标题就是项目名称本身（半粗），
  无项目时该分组不出现。无品牌头与底部入口：
  设置走 ⌘,，外观在 设置 › 通用 选择。
- **主操作槽**：输入页为"开始识别 ↔ 取消识别"，Resolve CSV 页为"导出 CSV…"（合并在其旁；导入在"更多"菜单里，
  空态也有按钮），识别结果页没有主操作；工具栏尾部顺序固定为"主操作 / 更多 / 面板开关"。
  状态栏只在内容列底部（不压过侧栏）：识别进度为紧跟文字的真实页码原生进度条，取消只在
  工具栏没有取消的页面出现；识别期间只冻结配置表单，并在其表头显示锁图标，证据页面不变暗。
  识别结果页在内容列 ≥ 900 pt 时首次进入即并排显示原稿（之后由工具栏开关决定）。
  检查器面板落在窗口画布色上（深色下不抢在内容之前）。工具栏主操作一律用标准的强调色填充
  prominent 按钮（不用与工具栏材质融在一起的玻璃变体），次要操作用 bordered，使可用与禁用
  状态在深色下一眼可辨。
- **面**：没有卡片、彩色胶囊、渐变或状态着色底。停靠面板、列表和表格用内容面，分隔只用
  发丝线；文档页直接浮在窗口画布上，只带系统阴影。玻璃只留给真正悬浮的元素且不着色。
- **过条 / 保条 / 废条 / 待定**是唯一保留的片场语汇，四个不同轮廓的 SF Symbols：
  粗对勾（标签色）、书签（次级）、叉（三级色，行文字随之变淡）、虚线圈（系统橙，
  唯一等待决定的状态）。结果页摘要是静态图例（符号 + 名称 + 数量），不是筛选。
  结果表本身仍是原生可编辑文本表（状态列为文字），不改写单元格。
- **设置**：窗口标题跟随当前面板；面板切换为图标页签（符号在上、名称在下，选中为 accent
  符号 + 静底）；表单直接铺在窗口背景；版权信息由 Info.plist 的
  NSHumanReadableCopyright 提供，在系统"关于"面板和设置页底部同时展示。
  设置页底部居中排列个人版权与 ICP 备案号，使用次级颜色的小号文字，切换分类仍可见。
  识别页的四项请求参数使用显式标签及右对齐的原生带框输入；未保存覆盖时显示当前生效值，
  无环境覆盖时默认超时 180 秒、重试 1 次、页并发 2、全局并发 1。超时以秒编辑（30–3600，
  最多三位小数），读写时转换为内部毫秒值，保留旧配置精度。仅查看不生成覆盖；
  “恢复默认值”只修改这四项草稿，和手动编辑一样需点击“保存”后生效。
- **项目库**：一个原生 List，无图标底座、斜纹或箭头；窗口标题即项目库名称，双击或 Return 打开。

### 功能区动效（2026-10-23）

- **功能区切换采用局部揭示**：主侧栏目的地、工作区三段页签、设置分类共用
  `ContentRevealRegion`。2 s、贝塞尔 `(0.4, 0, 0.2, 1)`；侧栏从内容左缘
  中心揭示，页签从内容上缘对应控件位置的投影揭示。只覆盖当前内容矩形，导航、
  工具栏和持久状态栏保持原位，不使用整窗主题动画的 4 秒节奏。
- **功能区内部采用原稿接力**：配置面板从右侧收展，原稿对照从左侧收展并用单一
  布局进度让结果表让位；原稿翻页在原有图片层中淡化交接并轻移 6 pt，高级设置
  内容淡化展开。时长 2 s，曲线同上，缓起、中段加速、结尾减速。保留原稿、表格、输入框的既有身份，
  不逐行播放表格动画，不给普通编辑、进度刷新或窗口缩放附加转场。
- 初次呈现和自动决定的面板布局直接显示；页面揭示期间不再叠加初始面板展开。
  系统“减少动态效果”直接更新并清除进行中的视觉覆盖。
- 视图只跟随已通过编辑/保存屏障的目的地；最多保留当前和退出两个真实页面，
  共用进度的圆内/圆外互补遮罩只改变可见范围。功能切换不再使用 `cacheDisplay`、
  位图压平、色彩重标记或快照回放；共享原生工作区背景始终位于两页之外。
- 退出页保持启用外观，通过命中控制和透明原生输入屏障阻断编辑，不用 disabled
  使控件变灰；只有当前页面贡献工具栏、标题和辅助功能内容。工具栏/侧栏继续响应导航。
  页面使用稳定身份，快速 A → B → A 复用保留的 A，并在原圆心反向收回同一遮罩，
  不交换圆内/圆外页面或重置半径。切向第三页时保持当前两页直到本段完成，再揭示
  最新请求（中间请求合并丢弃），始终最多挂载两页；导航继续响应，退出页工具栏立即移除。
  排队目标尚未挂载时保留上一标题。缩放、外观变化、卸载及减少动态效果直接落到
  最新请求并清空队列；旧完成任务不能清理新请求。
- `ContentRevealRegion` 保留在原有 SwiftUI 树中，以稳定 ZStack/页面身份承接环境、
  原生编辑器和窗口偏好。`SlateMotion` 共用 2 s 贝塞尔节奏；独立的 4 s 主题外观
  扩散不在此次替换范围。系统侧栏收展仍由分栏容器驱动，列内控件隔离继承动画。

## OpenRouter model choices (2026-10-01)

The built-in OpenRouter service presents Qwen 3.7 Flash, GPT-5.6 Luna and
GPT-5.6 Terra by default. Directory refreshes keep that curated selection.
The shared provider editor adds a visibly labeled model-ID field and a native
Verify and add model button for other OpenRouter models. It reuses existing
field errors, operation feedback and verified default/backup actions; pending
input stays local and is guarded on close. Successful probes retain additional
models across refreshes and restart. No theme or window geometry changes.

## Overview

SlateSync is a professional film-production utility used for long, detail-heavy
sessions. Its visual North Star (2026-10-23) is a quiet native macOS tool:
system structure, system typography, system color, no brand chrome. The only
film-set vocabulary left is the four take states. It must never resemble a
marketing dashboard, neon gaming UI, generic rounded-card SaaS template, or
touch-first iOS port. Dense information stays legible through alignment,
typography and native split-view hierarchy rather than stacked ornament.

## Colors

`SlateSyncTheme` owns the runtime mapping of these semantic roles, and since
2026-10-23 every role is a system color (see the dated section at the top and
the front-matter reference values). Accent is the user's system accent and is
reserved for the current selection, focus and the primary safe action; it is
never status. Status uses the system green/orange/red on symbols, with
contrast-safe text tints where small text must carry a status. Body text and
separators use system semantic colors. Feature views never embed RGB literals.
Native sidebar and window materials remain system-owned. Icons are neutral
secondary gray everywhere.

### 配色调整（2026-09-16，已于 2026-10-23 取代，仅作记录）

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
There is one layout density (2026-10-22): the sidebar and Settings no longer
offer a comfortable/compact choice. `SlateSyncDensity` stays as the internal
metric table at its comfortable values — panel padding 20 pt, section spacing
16 pt, list vertical padding 7 pt and CSV row height 30 pt — and nothing
injects the compact metrics; native controls use the regular control size. A
stale persisted `density` value is ignored.

The copyright notice is restored to the Settings footer (2026-10-27) alongside
the standard About panel: a centered, secondary-color caption above the ICP
filing, below the settings content and any error bar. It is rendered verbatim
from the app bundle's `NSHumanReadableCopyright`. The main window does not show
it, so recognition status and actions own the bottom edge.

The task rail is 210 pt and can be hidden independently. Its native list stays
at 210 pt while one layout translates it and places the adjacent content over
200 ms; Reduce Motion disables this animation. The list and its separator remain
mounted and are clipped at the workspace edge. Both native navigation columns
and task panes clear inherited animations so controls follow their container
without separately interpolating stale frames.
The system sidebar keeps its contents at least 190 pt wide inside a viewport
that can collapse to zero. Branding, the project-group label and the settings
link stay on one line so intermediate reveal widths never change the list's
top/bottom insets. Native column resizing still spans 190–280 pt (ideal 230 pt).
The workspace retains
Input / Recognition Results / Resolve CSV tabs and a current-task heading. The
heading is one compact row (about 64 pt): task name with live facts (pages ·
records · status) on the left, the segmented section picker and the page's
contextual control on the right; when the detail column cannot fit one row the
picker row drops under the title. Input gives the evidence preview the remaining
height, with a 300 pt recognition panel. At workspace detail widths below 900 pt
the panel starts hidden; once visible it docks (the preview makes room) from
700 pt and overlays the preview with a soft edge shadow below that. At 900 pt
and above it starts docked. When provider or model is missing the status bar
offers "Open recognition settings". Default visibility is resolved on the first
input layout and retained, along with explicit toggles, for the life of the
workspace view; resizing either sidebar never automatically opens or closes
this second panel. Advanced prompt settings are collapsed initially.
Local slate CSV stays with input; metadata scanning belongs to Resolve CSV.

Input panel default/dock choices are derived from the detail column through
`onGeometryChange` value types that change only at breakpoints. Original
comparison placement is owned by `WorkspaceResultLayout`, which uses the exact
proposed width without publishing geometry to workspace state. Neither sidebar
feeds a per-frame or quantized width back into the workspace body.

Results keep their table in one structural position. Optional original evidence
uses up to 420 pt (40% at wide sizes), appears inline at 900 pt and above, and
overlays at narrower sizes. Paging never implies a row-to-page mapping. Resizing
changes geometry only; explicit layout changes cross the native editor and
existing autosave barriers before hiding content.

Settings has a 780×620 default and a 700×540 minimum, with scrollable native forms
and a native segmented selector for General / Provider / Recognition / OCR /
MCP / Advanced. A single flexible content host avoids the fixed ideal size imposed by
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
or `thinMaterial` with the same Slate semantic fills and separator edges, plus
a stand-in for the glass look built from public API only (2026-10-22): a soft
top sheen and a 1 pt lit rim (bright upper-left, fading lower-right; a faint
dark return edge in light appearance). The highlights sit behind content so
they never lower text contrast, and are skipped under Increase Contrast and
Reduce Transparency. Refraction and backdrop sampling cannot be reproduced
before macOS 26, so the fallback does not attempt them.

Native `NavigationSplitView`, sidebar, toolbar, Settings scenes, sheets and
lists remain system-owned. Custom glass is reserved for bounded floating
surfaces: recognition and project-opening progress cards, search/filter
strips, status chips and the primary action. Docked, edge-to-edge chrome (the
workspace heading bar, the recognition configuration panel, the library
summary and `SlateStatusBar`) is flat and opaque (2026-10-22): the
`slateDockedSurface` roles `header`/`panel` use the evidence surface,
`summary` the canvas, and `status` the canvas with a 12% tone tint and a top
hairline. The CSV `NSTableView`, Light Table evidence canvas, media canvas and
dense log rows remain opaque/high contrast. Glass is never applied per row in
a large scrolling collection.

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

Project Settings exposes pending slate layouts in the existing grouped form.
Native DisclosureGroup rows preserve candidate-name drafts by observation ID;
native Picker owns assignment to a new or existing layout. Confirmation uses
an ordinary button, shared inline errors and persistent operation feedback.
One candidate initially expands for review; project identity resets row drafts
so identical images in different projects never share temporary input state.
No new palette, window geometry or scrolling surface is introduced.

Appearance changes use `AppearanceTransition` for the Settings picker (the
sidebar icon was removed 2026-10-23). Only a change in the resolved light/dark
appearance reveals the destination: a circle opens at each window's top-right
corner and sweeps to the bottom-left over 4 s (within the 3–5 s budget) with the
cubic Bézier (0.4, 0, 0.2, 1), on every visible app window at once (2026-10-23; it
was 550 ms from the initiating control, then 0.9 s with an ease-out curve that was
over in its first quarter, then 3 s). Inside the circle is the new appearance,
outside it the old. A temporary bitmap of the whole window frame — titlebar and
toolbar included — sits in a click-through borderless child window laid over the
window, so the top-right toolbar corner joins the sweep instead of flipping first;
the live editor hierarchy stays mounted. The overlay clips to a rounded outline
(AppKit publishes no corner radius, so the value errs slightly large). Windows
with an attached sheet change without the sweep. The roots
always pass an explicit `preferredColorScheme`: 跟随系统 resolves to the live
system appearance (`SystemAppearanceMonitor`, which never overrides
`NSApp.appearance`) and is applied like 浅色 / 深色. A nil scheme left the window
following macOS while SwiftUI's content stayed in the old appearance after
浅色 → 跟随系统, splitting the window. Same-looking system/explicit
choices update the preference without motion. Reduce Motion switches directly.
Repeated requests in one window finish the current circle and apply the latest
choice next. A choice from another window first cancels the previous window's
queued write and snapshot, including same-looking system/explicit choices, so
the newest shared preference wins. Resize, display changes and teardown discard
stale snapshot geometry.

The MCP Settings category combines one-click preparation/startup and an offline
guide in the existing grouped form scroller. Status stays first and distinguishes
preparing/building, starting, running, stopping, stopped and errors. Automatic
start remains opt-in. Directory grants are optional at startup and control file
access only. Client buttons call the official Codex / Claude Code CLI and have
separate pending/success/error feedback, preserving accurate broker status.
Advanced source/launcher overrides share one typed native file importer with
directory selection; multiple presenters must not be stacked on the same host.
The app owns startup, build cancellation and Quit drain. Running configurations
stay read-only; errors use SlateInlineError. Manual setup starts collapsed,
retaining selectable examples and existing typography, theme and copy feedback.

`WorkflowDiagnosticsSheet` is the shared complete-report surface for metadata
scanning and CSV reconciliation. Inline summaries remain bounded; a native
sheet contains a scrolling List with complete selectable messages and an
Escape-enabled close action. It reuses system typography and existing density;
no new palette, elevation, or layout identity is introduced. Reports remain
available for overwrite notices even when there are no blocking diagnostics.

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
名称单行截断并提供完整提示；唯一布局使用 20 pt 内边距（原紧凑 / 舒适模式已于 2026-10-22 合并为一种）。
加载期间禁用重复操作，成功和失败均移除进度；失败保留旧项目及现有错误恢复入口。
状态只属于发起打开的窗口；进度不估算百分比，也不绕过编辑保存屏障。

### 运行性能约束（2026-09-11）

预览缓存仅保留当前页图片，换页和素材替换时更新；进度、主题和布局刷新不得重复创建同一图片对象。
预览通过窄 AppKit 显示桥接复用当前页位图图层；缩放只更新等比适配框和显式矩形阴影路径，
不通过 GeometryReader 重建图片与阴影树。LightTable 保留原背景，图片层自行承担同一证据阴影。
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
- SlatePageHeading 用于项目库页首：44 pt 语义图标区域、title2 半粗标题、
  callout 辅助文字；面板仍用 SlatePanelHeading，避免所有区域同等强调。
  （2026-10-22 起工作台页首改为单行紧凑头部，不再使用 SlatePageHeading。）
- 项目库固定概览展示真实活跃/归档数量，下方原生 List 独立滚动与选择。
  行内保留项目识别线，加入 40 pt 图标底座和打开/归档提示符。
- 侧栏显示 SlateSync 品牌与“场记整理工作台”，底部提供原生全局设置入口。
  侧栏底色、选择和键盘行为继续由系统拥有。
- “当前项目”分组标题右侧显示已打开项目名称；名称保持单行、中间截断并提供完整
  悬停提示，未打开项目时不显示占位文字，避免与下方导航项争夺层级。
- 任务栏增加项目任务标题与总数，状态同时使用文字和 SF Symbols；搜索不改变总数含义。
- 保留三段原生工作页、原稿对照、保存屏障、300 pt 配置面板与现有密度规则。
  任务栏与内容区由同一布局完成 200 ms 收展，并遵循减少动态效果；两类侧栏的
  子控件隔离继承动画且裁剪越界绘制，避免中间位置残留。

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
