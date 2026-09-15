---
version: alpha
colors:
  primary: "#3F50BA"
  accent-soft: "#8C9CFF"
  canvas-light: "#F1F4F7"
  canvas-dark: "#151D29"
  evidence-light: "#FFFFFF"
  evidence-dark: "#1C2735"
  success: "#18794E"
  warning: "#865B0A"
  danger: "#B33A32"
  success-dark: "#79D5A5"
  warning-dark: "#EBC572"
  danger-dark: "#FF9A91"
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
one restrained indigo signal color. The signature is a subtle slate-stripe edge
on project identity surfaces; decoration elsewhere stays quiet.

The product must never resemble a marketing dashboard, neon gaming UI, generic
rounded-card SaaS template, or touch-first iOS port. Dense information remains
legible through alignment, typography and native split-view hierarchy rather
than stacked ornament.

## Colors

`SlateSyncTheme` owns the native runtime mapping of these semantic roles.
Accent uses #3F50BA in light appearance and #8C9CFF in dark appearance;
canvas uses #F1F4F7 / #151D29 and evidence uses #FFFFFF / #1C2735.
Success, warning and danger have explicit light/dark pairs. Body text and
separators use system semantic colors. Feature views never embed RGB literals. Native sidebar and
window materials remain system-owned. Accent is reserved for current selection,
focus and the primary safe action. Warning and danger remain distinct.

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
`SlateBadge`, `TakeMark`, `LeaderProgress`, `LightTable`, `CredentialChip` and
`WarnRow` extend the shared kit for the 2026-09-14 workspace direction (dated
section below); every color comes from `SlateSyncTheme`, and each stays quiet
outside its owning business state.
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
