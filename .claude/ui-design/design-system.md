# SlateSync 新版前端 UI · 设计系统

> 状态:**已实施(2026-09-14 第一轮)**。六个共享组件落于 `SlateSyncUI/Components/WorkbenchComponents.swift`,
> 圆角 Token 增补进 `SlateSyncTheme`,工作台/外壳/设置整合见 `AGENT.md` 顶部 2026-09-14 实施记录。
> 与原型的有意偏差(行→页映射、表内 TakeMark、徽章过滤)同样记录在 AGENT.md。本文档保留为该视觉语言的规范来源;
> 可交互预览见 [prototype.html](prototype.html),界面之间的流转规则见 [interaction-map.md](interaction-map.md)。

---

## 一、设计主张:从纸面到数据

### 单一主题：Slate Workbench

Slate Workbench 是 SlateSync 唯一的视觉语言。深色与浅色是同一组语义 Token 的两个外观 mode，
不代表两套品牌主题；密度只改变空间节奏，不改变组件层级、圆角或状态含义。

视觉目标是**克制的片场证据工作站**，不是片场主题乐园：真实证据优先，片场痕迹只在对应的业务状态出现，
所有操作控件仍保持 SwiftUI 原生 macOS 的清晰度与可预测性。

SlateSync 处理的信任链是:**纸质场记单 → 结构化数据 → 已校验的 Resolve CSV**。
新版界面让这条链在视觉上可感知——界面是一个 **DIT 推车上的校准工作台**:

- **碳素仪架**:蓝冷石墨色底盘、发丝级分隔线、密排的等宽数据。长时间暗房环境使用,不炫光。
- **灯箱证据**:场记单原稿永远放在"看片灯箱"上预览——它是界面中唯一的"亮部",像胶片时代
  在灯箱上核对底片一样核对识别结果。
- **片场痕迹**(签名系统):界面上每个确认状态都借用一个真实的片场动作——
  | 痕迹 | 借用的片场动作 | 应用位置 |
  | --- | --- | --- |
  | **场记板斜纹** | 打板 | 项目身份卡左缘 3px 斜纹、品牌标记 |
  | **铅笔圈** | 场记用铅笔圈掉好条 | 识别结果中"好条/保条"的确认标记(手绘椭圆,微倾斜) |
  | **油笔划线** | 作废条目划掉 | "作废"条目的删除线 |
  | **识别进度** | 学院 leader 扫掠 | 识别进行中的真实页面进度 |

一句话给评审:**别的工具把场记单当"上传的文件",SlateSync 把它当"钉在灯箱上的底片"。**

明确不做:营销式 dashboard、霓虹游戏风、通用圆角卡片 SaaS 模板、iOS 触屏移植风、大面积渐变。

---

## 二、色彩

> **决定(2026-09-12)**:配色沿用现行 `DESIGN.md` / `SlateSyncTheme` 的语义色对,
> 本设计**不另立色板**。下表是原型 CSS 变量与现行体系的映射关系。
> **更新(2026-09-16)**:全局配色调整为冷灰阶梯 + 钨丝琥珀(见 DESIGN.md「配色调整(2026-09-16)」),
> 下表与中性阶梯已同步。

### 语义 Token(dark 优先,成对给出 light;唯一来源为 DESIGN.md / SlateSyncTheme)

| Token | Dark | Light | 来源 |
| --- | --- | --- | --- |
| `accent` | `#F59E0B` | `#B45309` | DESIGN.md `accent-soft` / `primary` |
| `canvas` | `#1E2229` | `#F6F7F9` | DESIGN.md `canvas-dark` / `canvas-light` |
| `evidenceSurface`(原 `panel`) | `#2A2F37` | `#FFFFFF` | DESIGN.md `evidence-dark` / `evidence-light` |
| `ok` | `#7FC9A9` | `#1E7A5A` | DESIGN.md `success-dark` / `success` |
| `warn` | `#E3C36B` | `#7C6A00` | DESIGN.md `warning-dark` / `warning` |
| `danger` | `#E58873` | `#B03A2E` | DESIGN.md `danger-dark` / `danger` |
| `paper` | `#F2EEE3` | `#F2EEE3` | 证据内容色(只属于纸面内容),不属于主题 |

### SwiftUI / Figma 映射

当前 `codex` draft 先交付 Light 预览；变量命名和语义保持 Light/Dark 可切换，Starter 计划
限制只影响 Figma 的 mode 数量，不影响 SwiftUI 运行时的自适应主题。

| 语义 | SwiftUI 运行时 owner | Figma 变量 |
| --- | --- | --- |
| 主背景 | `SlateSyncTheme.canvas` | `Color/bg/canvas` |
| 证据面 | `SlateSyncTheme.evidenceSurface` | `Color/bg/evidence` |
| 当前发生的事 | `SlateSyncTheme.accent` | `Color/semantic/accent` |
| 成功 / 待人工 / 不可恢复 | `SlateSyncTheme.success / warning / danger` | `Color/semantic/success` / `warning` / `danger` |
| 正文 / 次级 / 分隔 | `Color.primary / .secondary / SlateSyncTheme.separator` | `Color/text/primary` / `secondary` / `border` |

Figma 变量只镜像这些运行时语义；它不是新的颜色来源。原型中为了表现冷灰层级而使用的 `raised`、`inset`、
`line-strong`，实现时优先使用 SwiftUI material、系统层级色和现有分隔线，避免复制一套页面专用灰阶。

### 原型层级参考（不作为第二套主题）

HTML 原型和 Figma 预览需要显式表现面板/分隔线层级,以下值只用于预览校准，
不构成新的运行时色板:

| Token | Dark | Light | 实施时对应 |
| --- | --- | --- | --- |
| `raised` | `#2A2F37` | `#FFFFFF` | 系统材质 / `-.quaternary` 系 |
| `inset` | `#171B21` | `#EDEFF2` | 下沉区,如灯箱底 |
| `line` | `#3A4149` | `#DDE1E6` | `Color.separator` |
| `line-strong` | `#4C545E` | `#C4C9D0` | 强分隔/边框 |
| `text` / `text-2` / `text-3` | `#E8EAED` / `#A8B0BA` / `#6E7681` | `#16181D` / `#5C6470` / `#8A919B` | `.primary` / `.secondary` / 系统三级 |

实施原则:能映射到系统语义色(`Color.primary`、`.separator` 等)的优先映射;
确实需要落库的阶梯(如 `inset`、`line-strong`)以**增补 SlateSyncTheme 静态项**的方式进入,
并在同一变更中同步 `DESIGN.md`，视图仍不嵌 RGB 字面量。

### 使用规则

1. **琥珀 accent 是唯一信号色**:选中态、焦点环、主按钮、进度、tab 下划线——
   一切"当前发生的事"。规则与现行 `DESIGN.md` 一致:accent 只用于当前选择、焦点与主安全操作。
   侧栏、工具栏、页首座标与空态图标一律中性次级灰，不参与 accent(2026-09-16 起)。
2. **警告、危险、成功沿用现行语义对**,且始终配图标,不单靠颜色区分;warn(黄铜)
   与 accent(琥珀)保持约 22° 色相差,警告不得读作选中。
3. **中性色只走冷灰阶(微蓝调 slate)**,禁止出现纯黑 `#000` 与纯白 `#FFF` 以外的未锚定灰。
4. **灯箱反转**:工作区里最大的一块亮色永远是证据预览(纸面)。整个界面的明暗结构
   模拟"暗房里的灯箱",而不是"黑底荧光字"。
5. 语义色只能以 `文字 / 图标 / 3px 左缘 / dim 底色` 四种形式出现,禁止大面积色块。
6. 两套外观都必须通过对比度检查:正文 ≥ 7:1,次级 ≥ 4.5:1;accent 图形在 dark 底上 ≥ 3:1。
   `text-3` 只允许用于非关键元数据；说明、错误、恢复动作和会影响判断的时间信息必须使用正文或次级层级。

---

## 三、字体

> **决定(2026-09-12)**:遵循现行 `DESIGN.md` 排版规则——SF + 苹方为正文与展示,
> SF Mono 限于数据。仅保留一个例外:`Caveat` 只用于**纸面证据 mock 的手写笔迹**
> (它是"内容"而非 UI 字体,模拟纸质场记单上的填单笔迹)。

| 角色 | 字体栈 | 用途 |
| --- | --- | --- |
| 正文 / 展示 | `-apple-system`, `PingFang SC` | 全部界面文案(SwiftUI 侧即 `.AppleSystemUIFont` + 苹方,同 DESIGN.md) |
| 数据 | `ui-monospace`("SF Mono", Menlo) | 时间码、条号(`S14 · T3 · A`)、FPS、CSV 单元格、模型 ID、日志 |
| 手写(仅内容) | `Caveat` | 场记单 mock 上的手写笔迹;任何界面控件不得使用 |

### 字阶(紧凑型工作站,基准 13)

| 级别 | 字号/行高 | 字重 | 备注 |
| --- | --- | --- | --- |
| display-num | 32/36 | 600 | 项目库统计大数字 |
| title-1 | 22/26 | 600 | 视图标题 |
| title-2 | 15/20 | 600 | 面板标题 |
| body | 13/18 | 400 | 默认 |
| body-strong | 13/18 | 600 | 表格头、按钮 |
| caption | 12/16 | 400 | 辅助说明 |
| data | 12/16 | mono 400 | 等宽数据 |
| eyebrow | 11/14 | 600 · +0.08em · 大写 | 章节眉标,格式模拟摄影报告字段:`ROLL A03 · CAM A · 23.976` |

**签名排版细节**:所有 eyebrow 一律写成"片场表单字段"的样式(`场景 14 · 镜 3 · 次 2`),
让界面眉标与它正在解析的纸质表单共享同一种语言。

---

## 四、间距 · 圆角 · 密度

- **8pt 基线网格**;组件内 4pt 半格。
- 圆角只保留一套 SwiftUI Token，并使用 `.continuous` 圆角：
  `small = 6pt`(图标按钮/微型控件) · `control = 8pt`(输入与普通控件) ·
  `panel = 12pt`(面板) · `large = 16pt`(设置 sheet 等大弹层)。药丸形**只用于状态徽章**。
  功能视图不得直接写 7/9/10pt 等局部圆角。
- 密度沿用现有双档偏好,映射到新 Token:

| Token | 舒适 | 紧凑 |
| --- | --- | --- |
| 面板内边距 | 20px | 12px |
| 区块间距 | 16px | 12px |
| 列表行高 | 32px | 26px |
| 表格行高 | 30px | 24px |

- 布局骨架:导航栏 208px(可收窄为图标列)· 任务栏 224px(可隐藏)· 工具栏 52px ·
  状态栏 30px · 默认窗口 1440×900 · 最小 960×600。

---

## 五、组件规范

按"谁是它的片场原型"逐一说明(全部组件在 prototype.html 中有可交互实现):

| 组件 | 规范要点 |
| --- | --- |
| **SlateBadge(斜纹身份条)** | 项目身份面左缘 3px 45° 黑白四道斜纹(SVG pattern);仅用于"项目"这一层级的身份,不得用于任务/按钮 |
| **ProjectLibrary(项目库列表)** | 继续使用原生 `List` 的选择、双击和键盘行为;斜纹只作项目身份线;统计是轻量摘要,不做 KPI 卡片网格 |
| **LightTable(灯箱)** | 只承载真实证据预览;纸面区域不放表单或操作按钮;页码、缩放、导入等控件放在相邻控制栏;生产环境不得用 mock 替代真实场记单 |
| **SlateSheetMock(纸面证据)** | 仅用于 Figma/HTML 预览的内容 mock;生产环境使用真实导入场记单,只叠加识别区域高亮 |
| **TakeMark(确认痕迹)** | 好条/保条 = 铅笔灰椭圆(SVG,stroke 微倾斜,确认瞬间 240ms 描边动画);作废 = 油笔红划线;待定 = 空心点 |
| **LeaderProgress(识别进度)** | 仅在识别进行中出现;显示真实的 `第 n/总页数` 进度,总数未知时改用命名阶段;减弱动态效果时退化为原生进度条 |
| **WorkTabs(三段工作页)** | 优先复用 SwiftUI 原生 `Picker(.segmented)`;若未来需要自定义外观,必须保留 selected、键盘、VoiceOver 和 guard 行为;圆点只是“有新结果”提示,不抢焦点 |
| **SlateStatusBar(状态栏)** | 复用现有共享组件,作为异步操作的唯一全局发言人;底部状态不与局部 toast 或第二套状态条竞争 |
| **CredentialChip(凭据状态)** | 四态:已配置(ok)/ 缺失(text-3)/ 需要授权(warn)/ 读取失败(danger);禁止把"取消授权"显示成"缺失" |
| **CapabilityChip(能力状态)** | 四态:已验证(ok)/ 验证失败(danger)/ 未验证(text-3)/ 需要注意(warn);复用 slateGlassSurface 胶囊，始终同时显示符号和文字 |
| **WarnRow(告警行)** | 问题行 = `warn/danger` 的 dim 底 + 3px 左缘 + 行尾"校对"按钮;告警徽章可点击过滤 |
| **ConfirmDialog(确认弹层)** | 危险操作需**输入项目名**解锁按钮(沿用现有文案机制);Esc = 取消 |
| **SlateEmptyState(空态)** | 灯箱变体:中央放一个斜纹小图形 + 一句"去做什么"(如「创建项目后即可导入场记单」)+ 主操作按钮,不放插画 |
| **密度/主题切换** | 常驻导航栏底部:主题(日/夜)、密度(舒适/紧凑)各一个图标钮,带 `title` 提示 |

### 动效

| 动效 | 时长/曲线 | 说明 |
| --- | --- | --- |
| 确认描边(铅笔圈) | 240ms `cubic-bezier(.4,0,.2,1)` stroke-dashoffset | 每次确认一次,不循环 |
| 识别进度 | 跟随真实页面完成节奏 | 完成后停止,不空转,不制造虚假倒计时 |
| 视图切换 | 无位移动画,120ms 透明度 | 工作站气质:切换是"换频道",不是"翻页" |
| 全局 | `prefers-reduced-motion` 时:转盘→进度条、描边→直接出现 | 遵循系统设置 |

### 图标

继续使用 **SF Symbols** 语义(原型中以近似内联 SVG 代替):`doc.viewfinder`(场记单)、
`film.stack`(项目)、`tablecells`(CSV)、`gearshape`(设置)、`sidebar.left`(任务栏)、
`checkmark.circle` / `processing` / `draft` 等任务状态。禁止 emoji 作功能图标。

---

## 六、与现行 `DESIGN.md` / UI 库的关系(决定记录)

> **决定(2026-09-14)**:保持单一 Slate Workbench 主题;配色与圆角沿用现行体系;布局与组件采纳本提案方向。
> 现有 UI 库与框架**不需要替换,走"扩展"路径**。

### 不变的部分

- `DESIGN.md` 仍是唯一设计规范来源,`SlateSyncTheme` 仍是运行时唯一取色来源,
  功能视图禁止内嵌 RGB 字面量的规则继续有效。
- 语义色对原样沿用(primary/`#B45309/#F59E0B`、canvas、evidence、success/warning/danger,
  2026-09-16 冷灰 + 钨丝琥珀方案),本提案**不新增任何主题色**。
- 原生 macOS 三栏骨架、无渐变装饰、中文动词语汇、状态栏反馈制、密度双档、
  保存屏障、Evidence 对照宽度规则(420pt/40%)全部保留。

### 采纳的部分(布局与组件方向)

- 灯箱(LightTable)证据预览、"片场痕迹"签名系统(斜纹身份条 / 铅笔圈 / 油笔划线 / 真实识别进度)、
  三段工作页 tab 结构，以及统一的 SwiftUI 圆角 Token。

### 实施时的 UI 库扩展路径(不改框架)

1. **不换框架**:仍是 SwiftUI + `SlateSyncUI`,不引入任何第三方 UI 依赖。
2. **新增共享组件**(落 `Sources/SlateSyncUI/Components/`,与 `SlatePanelHeading` /
   `SlateEmptyState` / `SlateStatusBar` 并列):`TakeMark`(确认痕迹)、`LeaderProgress`(识别进度)、
   `LightTable`(灯箱)、`SlateBadge`(斜纹身份条)、`CredentialChip`(凭据四态)、`WarnRow`(告警行)。
3. **`SlateSyncTheme` 只增补、不改既有值**:现有语义色与圆角 Token 一律不动;
   派生中性阶梯只有在多个共享组件确实需要时才新增,并同步 `DESIGN.md`,视图不得内嵌 RGB 或局部圆角。
4. **`DESIGN.md` 更新一次**:把新增 Token 与组件名录补进附录,保持"规范—主题—视图"三层一致。
5. 本提案不改动任何数据合同与工作流逻辑;识别完成不自动抢占当前页面,交互合同见 [interaction-map.md](interaction-map.md),
   与 `UIWorkflowContracts.swift` 对齐后再落码。

## 七、Figma 预览设计约束

Figma 预览用于确认构图、密度、证据对照宽度和状态层级，采用与 SwiftUI 相同的命名：

- 变量 mode 只有 `Light` / `Dark`，它们属于同一个 `Slate Workbench` 主题。
- 页面顺序固定为 `Foundations → Project Library → Workspace/Input → Results → Resolve CSV`。
- 组件预览必须同时展示默认、空态、处理中、告警、错误和已保存状态。
- 圆角、色彩、间距和文字样式全部绑定变量；Figma 中不保留页面级临时值。
- Figma 预览不得把纸面 mock 当作真实证据，也不得把自定义网页控件当作 SwiftUI 行为规范。
