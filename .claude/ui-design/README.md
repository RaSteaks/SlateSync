# SlateSync 新版前端 UI 设计（优化版）

> 本文件夹是 **Slate Workbench** 方案的设计档案(视觉 + 交互 + 可点击原型)。
> **2026-09-14 起第一轮已实施落码**:组件与 Token 进入 `SlateSyncUI`(见 AGENT.md 顶部实施记录与偏差清单),
> 本文件夹保留为规范与原型来源。深色与浅色只是同一主题的外观模式，
> 不是两套独立的视觉语言。运行时 Token 由根目录 `DESIGN.md` 与 `SlateSyncTheme` 共同定义。

## 文件导览

| 文件 | 内容 |
| --- | --- |
| [prototype.html](prototype.html) | **可点击交互原型**(推荐从这里开始)。覆盖 项目库 → 打开项目 → 工作台(原稿/识别结果/Resolve CSV)→ 对账告警 → 导出 的完整闭环,外加 全局设置、日志、帮助、保存屏障、危险操作确认。深浅两套外观、舒适/紧凑两档密度都可切换。 |
| [design-system.md](design-system.md) | 设计系统规范:设计主张、色彩 Token(深浅成对)、字阶、间距/圆角/密度、组件规范、动效、与现行 `DESIGN.md` 的关系。 |
| [interaction-map.md](interaction-map.md) | 交互逻辑地图:信息架构、界面状态机、门卫(guard)规则、五条核心流程、跨界面一致性规则、键盘与无障碍。 |

## 查看原型

```sh
open .claude/ui-design/prototype.html
```

或直接在浏览器打开该文件。建议按这条路线点一遍(约 2 分钟):

1. **项目库** → 《雾河》行点「打开」→ 观察打开进度覆盖层
2. **原稿页** → 灯箱里的真实场记单(铅笔圈与油笔划线是纸面证据的质感)→ 右侧选择 Provider →「开始识别」→ 观察真实识别进度与逐页反馈
3. 识别完成后保持当前页面；结果 Tab 显示圆点，状态栏提供进入结果页的动作 → 点击状态徽章循环 待定→好条→保条→作废,好条触发铅笔圈描边 → 点任意行,右侧原稿对照同步翻页 →「合并识别结果」
4. 切到 **Resolve CSV 页** → 先「导入 Resolve CSV」→ 三类告警(未匹配/条号缺失/次序异常)→ 逐个「校对」处理 →「导出 CSV…」→ 导出确认 → 状态栏确认反馈
5. 左下角齿轮打开**全局设置**;月亮/行距图标切换外观与密度
6. 试试图:切换任务(第3拍摄日是空态路线)、⌘1/2/3、Esc、搜索任务、带未保存修改切换任务(保存屏障)

原型支持深链,便于评审定位:

```
prototype.html#w=workspace&p=wuhe&t=d02&tab=input    # 直接打开工作台
prototype.html#w=library&theme=light                 # 项目库 · 浅色外观
```

## 设计一页纸

- **主张**:从纸面到数据 —— 界面是 DIT 推车上的校准工作台:碳素仪架 + 灯箱证据 + 把场记单的表单几何映进数字表格。
- **单一主题**:Slate Workbench 是唯一视觉语言；深色/浅色只改变语义 Token 的明暗映射，不改变层级、形状、组件和交互含义。
- **签名系统**(按场景单点出现):输入页突出灯箱证据；结果页使用铅笔圈/油笔划线；识别进行中才显示 LeaderProgress；项目身份只保留低调斜纹边缘。
- **色彩**:沿用现行 `DESIGN.md` / `SlateSyncTheme` 语义色对(靛蓝 accent `#3F50BA/#8C9CFF` · 蓝冷 canvas/evidence · 现行 success/warning/danger),不另立色板；原型里的中性阶梯只作实现参考，不成为第二套主题。
- **形状**:圆角采用 SwiftUI 连续圆角和现有 Token：small 6pt、control 8pt、panel 12pt、sheet 16pt；视图不得出现自定义 7/9/10pt 圆角。
- **字体**:系统 SF + 苹方(正文与展示)+ SF Mono(时间码/条号/CSV 数据);`Caveat` 仅用于场记单 mock 的手写笔迹(内容,非 UI 字体)。
- **交互原则**:guard 用空态说明"缺什么、去哪补";所有异步操作由共享 `SlateStatusBar` 发言,不用 toast;tab 圆点提示"那边有新东西"但不抢焦点;危险操作才用模态(删除需输入项目名)。

## 实施衔接(给未来编码会话)

> **决定(2026-09-14)**:保持单一 Slate Workbench 主题，配色与圆角沿用现行体系，不改框架、不改既有语义色；
> 布局与组件按本提案方向，以**扩展 UI 库**的方式实施(详见 `design-system.md` §六)。

- 新组件(TakeMark、LeaderProgress、LightTable、SlateBadge、CredentialChip、WarnRow 等)落在
  `Sources/SlateSyncUI/Components/`,与 `SlatePanelHeading` / `SlateEmptyState` / `SlateStatusBar` 并列。
- 原型中的 `raised / inset / line-strong` 不直接复制为页面 CSS；优先映射到 SwiftUI 的
  `.regularMaterial`、`.quaternary`、`Color.separator` 和现有主题 Token。只有多个共享组件确实需要时，
  才在 `SlateSyncTheme` 中新增静态项，并同步 `DESIGN.md`。
- 交互逻辑(空态文案、guard、保存屏障、状态栏词汇)以 `interaction-map.md` 为合同,
  与 `UIWorkflowContracts.swift` 对齐后再落码;未获用户明确确认前不改 Swift 运行时代码。

## Figma 预览计划

Figma 用于评审页面层级、密度、证据对照宽度和深浅外观，不替代 SwiftUI 的运行时 Token 或原生控件行为。
预览文件按以下范围建立：

1. `00 Foundations`: 单一主题 Token、圆角/间距/状态色、字体与证据纸面原则。
2. `01 Project Library`: 原生列表取向的项目库，避免 KPI 卡片化。
3. `02 Workspace · Input`: 灯箱证据 + 识别配置 + 空态/处理中状态。
4. `03 Workspace · Results`: 结果表、TakeMark、原稿对照和未保存状态。
5. `04 Workspace · Resolve CSV`: 告警行、校对动作和导出确认。

Figma 页面只保留一套组件命名和 Token 映射；当前先完成 Light 画板，变量命名按同一组
Light/Dark 语义设计，不创建第二个品牌主题或独立的圆角体系。后续切换到支持多 mode 的
workspace 后，可直接补齐 Dark mode，不需要重做页面结构。
