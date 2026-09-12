# Phase 02：中文归一化与复核标记

## 目标

提升中文数字和混淆字符处理准确性，同时保留可追溯的原始识别结果。

## 处理位置

归一化应发生在：

```text
模型识别/高精度合并完成
  → 统一字段归一化
  → 写入 reviewRequiredFields
  → 持久化和展示
```

不能在不同 Renderer 或不同导出路径中重复实现。

## 主要任务

### 1. 共享归一化函数

在 `public/metadata-common.js` 中实现 Node 和浏览器均可调用的纯函数：

- 逐字中文数字：`二〇三` → `203`
- 单位数字：`十一`、`一百零五`
- 已有范围限制和非法值处理
- 字段专用归一化：scene、shot、take、cardNumber、videoCode
- 混淆字符只在明确的数字上下文中转换

归一化结果应包含：原值、结果值、是否变更、警告原因和是否需要复核。

### 2. 接入识别和 CSV

- `lib/schema.mjs` 使用共享归一化。
- `public/resolve-csv.js` 使用同一套字段规则。
- 不覆盖原始 OCR 文本和证据。
- 关键字段自动修复时加入 `reviewRequiredFields`。
- 不确定时保留原值，只增加复核标记。

### 3. 结果界面

modern 和 legacy 结果表格增加：

- 字段级复核标记
- 复核字段筛选
- 复核数量提示
- 不影响原有编辑和 confidence 操作

## 重点文件

- `public/metadata-common.js`
- `lib/schema.mjs`
- `public/resolve-csv.js`
- `src/renderer/features/recognition/RecognitionResultPanel.tsx`
- `public/app.js`
- `src/shared/contracts/index.ts`

## 验收标准

- `二〇三`、`十一`、`一百零五` 等测试通过。
- Node、modern、legacy 的归一化结果一致。
- 复核标记能随任务保存、恢复和重新打开。
- 未被修复的字段不会被误改。
- 原始 OCR 证据保持不变。

---

## 施工包元数据与执行状态

> **施工包状态：READY FOR IMPLEMENTATION — DOCUMENT ONLY**
>
> 本节及以下内容是 Phase 02 的详细施工包，不是施工结果。本次请求只生成
> 施工包，不执行源码修改、测试、构建、Electron 启动、真实 Project Library
> 读写、真实 provider/OCR 调用、Git 暂存、提交、推送、切分支或清理。

- 施工分支：feat/electron/accuracy-csv
- 当前分支基线：已确认与 origin/feat/electron/accuracy-csv 对齐；执行时仍须重新做分支门禁。
- 上游交接：Phase 01 契约与兼容性基础施工包，尤其是 targetId、字段质量元数据、
  reviewRequiredFields、任务恢复和 ProjectSettings v2 规则。
- 本包目标：把中文数字、字段专用数字归一化、混淆字符处理和字段级复核标记
  收敛为一套 Node/modern/legacy/CSV 共用的规则。
- 本包完成后交接：交付带 quality 与 reviewRequiredFields 的最终识别记录给
  Phase 03 CSV 源编码/读取施工，以及后续 Phase 04–06 的展示、导出和复核流程。

## 施工目标与非目标

### 必须完成

1. 将中文数字、全角数字、字段专用格式、有限混淆字符转换和非法值处理统一到
   public/metadata-common.js 的纯函数中。
2. 让 Node 主流程和浏览器 CSV/结果流程调用同一套规则；已有的 schema 或
   resolve-csv 导出函数可以保留兼容包装，但不能再保留独立算法。
3. 在最终高精度合并完成后只执行一次面向最终记录的字段归一化，生成可追溯的
   originalValue、normalizedValue、changed、warnings、reviewRequired。
4. 对安全但可能改变识别含义的自动修复设置字段级复核标记；不确定时保留原值，
   只增加 warning 和复核标记。
5. modern 与 legacy 结果表格都能显示字段级复核标记、只看待复核记录的筛选和
   复核数量，并且不破坏原有编辑、置信度调整、任务自动保存和恢复。
6. 保持 OCR 原始证据、识别诊断、targetId 和已有人工复核标记可追溯，且普通
   CSV fixture 的导出字节不发生无关变化。

### 明确不做

- 不改 OCR provider、提示词、OCR 坐标结构、图像裁剪或 high-accuracy 的模型策略。
- 不实现 Phase 03 的 GBK/GB18030 源文件读取、编码探测策略扩展或新的 CSV 导入 UI。
- 不实现 Phase 04 的导出列编辑器、文件名模板编辑器或最终导出交互。
- 不改变 targetId 的生成格式、顺序语义或 crop recheck 接口。
- 不新增 IPC channel，不改变现有 Result/AppError envelope，不修改 SQLite schema。
- 不以卡号、视频码、场次、镜、次推导稳定身份，不因归一化而排序、去重或合并记录。
- 不在 legacy 和 modern 中各自实现一套中文数字或混淆字符算法。
- 不因为 UI 展示“复核”就自动清除 reviewRequiredFields；本阶段不引入隐式的
  “编辑即确认”行为。

## 实施前门禁

执行者在改动源码前必须按以下顺序完成并记录结果；本次生成施工包不执行这些门禁。

1. 重新确认 git branch --show-current 为 feat/electron/accuracy-csv。
2. 记录 git status --short，并把已有用户改动视为不可覆盖内容；不得为了通过
   测试重置、清理或覆盖未相关文件。
3. 确认 Phase 01 已完成其交接条件：共享契约已经存在，RecognitionRecord 有
   targetId/可选 quality，任务恢复保留旧 reviewRequiredFields，ProjectSettings
   v1/v2 兼容已通过上游证据。
4. 检查 Phase 02 涉及文件的当前 diff，确认没有把用户已有改动当成施工结果。
5. 新增或修改的任务/项目持久化测试必须使用临时数据库和临时任务目录，不能触碰
   默认 macOS Project Library、用户真实任务、provider credential 或真实网络。
6. 固定现有 baseline recognition、persistence 和 CSV fixture 的原始内容；任何需要
   重写 golden 才能通过的情况都必须停止并记录原因。
7. 施工完成后才允许更新根目录 AGENT.md，记录实际改动和验证事实；本次只生成
   施工包，不改 AGENT.md。

## 当前代码基线与设计约束

执行者仍须在施工开始时复核代码；以下是本次编制施工包时观察到的事实：

| 区域 | 当前事实 | Phase 02 要求 |
| --- | --- | --- |
| shared helper | public/metadata-common.js 已有 cleanValue、parseChineseNumber、chineseNumeralsToArabic；当前中文数字解析只覆盖零/一至九/两/十/百，逐字数字中的 〇 尚需纳入。 | 扩展同一 helper，并在其上提供带质量结果的字段归一化，不再把算法复制到别处。 |
| Node schema | lib/schema.mjs 当前在 normalizeSlateResult 与 formatSlateResultFields 内分别执行卡号、视频码、scene、shot、take 的字段处理。 | 保留旧导出名作为适配入口，字段规则改为委托 shared helper；最终 quality 只在合并完成后生成。 |
| CSV renderer | public/resolve-csv.js 既有 normalizeSceneValue、normalizeShotValue、normalizeTakeValue 和 normalizeMetadataField；buildStandaloneResolveTable、mergeSlateIntoResolveTable、encodeResolveCsv 都会触及字段归一化。 | 包装函数保留，内部全部调用 shared helper；源 CSV 行的变化继续进入 changes/warnings，不覆盖识别记录的 OCR 证据。 |
| high accuracy | lib/ai-client.mjs 在 mergePageResults 后调用 formatSlateResultFields；已有 sequence repair 会通过 reviewRequiredFields 标记 shot/take。 | 不移动 targetId 生成或改变 repair 判定；让最终字段质量与既有 reviewRequiredFields 合并。 |
| modern | RecognitionResultPanel.tsx 目前只有文本搜索，字段直接编辑，只有整行 low confidence 属性，没有质量字段标记。 | 增加 all/review 筛选、字段 badge、warning 说明和数量提示；编辑及 confidence select 仍保持原行为。 |
| legacy | public/app.js 当前有 detail-search、renderTable、normalizeEditedField 和任务恢复；结果单元格是直接编辑控件。 | 增加同等的复核筛选/标记；结果默认仍显示全部，编辑不隐式清除复核。 |
| restore | modern WorkspacePage 已把 quality.fields 中的 reviewRequired 合并到 reviewRequiredFields；legacy 恢复路径还须核对同样的投影。 | 两个 Renderer 都使用稳定的兼容投影，旧任务没有 quality 时仍可读取旧字符串标记。 |

## 允许修改的路径

### 规则和数据流

- public/metadata-common.js：共享纯函数、中文数字 token 解析、字段专用归一化、
  warning 生成、复核投影 helper。
- src/shared/contracts/index.ts：必要时补充 Phase 02 warning code 或质量投影
  helper 的类型；不得删除 Phase 01 已有字段或把 reviewRequiredFields 收窄为
  只接受新格式。
- lib/schema.mjs：结构校验与最终字段归一化的接线；保留既有对外导出函数名。
- lib/ai-client.mjs：只调整“合并完成后归一化”的调用顺序和比较 helper 接口；
  不改模型请求、重试和 targetId 规则。
- public/resolve-csv.js：把现有 CSV 字段包装器接到 shared helper，并把变化、
  warning、复核信息放入已有 merge output 结构的兼容扩展。

### 展示、恢复和测试

- src/renderer/features/recognition/RecognitionResultPanel.tsx。
- 对应 modern recognition 样式文件；只增加复核 badge、筛选控件和可访问性样式。
- public/app.js、public/index.html、public/styles.css。
- src/renderer/features/workspace/WorkspacePage.tsx：仅在 legacy/modern 恢复投影
  需要统一时修改，不改变 task payload 版本。
- test/metadata-structure.test.mjs、test/resolve-csv.test.mjs、
  test/ai-client.test.mjs、test/task-persistence.test.mjs、
  test/baseline-recognition.test.mjs、test/csv-background-tasks.test.mjs、
  test/recognition-target.test.mjs、test/refactor/ip-03-08/virtual-table.test.tsx
  及新增的 Phase 02 fixture/test 文件。
- AGENT.md：只在真正施工并验证后记录实际事实。

### 禁止扩大的路径

- electron/、preload/ 和 IPC channel 定义，除非发现现有 contract 无法传递已经
  存在的 quality 字段；若确实需要，先停止并请求重新授权。
- 数据库迁移、任务 schema version、默认 Project Library。
- provider、credential、真实 CSV 文件、发布产物和 Git 历史。

## 共享归一化 API 设计

### 单字段结果形状

在 public/metadata-common.js 中建立一个 Node 与浏览器均可调用的纯函数。名称可
沿用项目已有命名风格，但职责必须等价于：

~~~js
normalizeRecognitionField(field, value, options)
~~~

返回值固定为以下结构，不因字段不同而返回不同 shape：

~~~js
{
  field: "scene",
  originalValue: "二〇三",
  normalizedValue: "203",
  changed: true,
  confidence: "high",
  reviewRequired: true,
  warnings: [
    {
      code: "chinese-numeral-converted",
      field: "scene",
      message: "已将中文数字归一化为阿拉伯数字，请人工确认",
      originalValue: "二〇三",
      normalizedValue: "203"
    }
  ]
}
~~~

具体约束：

- originalValue 是进入 Phase 02 统一归一化闸门时的字段值；空值统一为 null。
- normalizedValue 是供识别记录、CSV matching 和展示使用的值；不确定时必须回填
  originalValue，而不是回填 null 或猜测值。
- changed 只表示原值与结果值不同；warning 是否存在不能由 changed 推断。
- confidence 由调用者传入记录级 confidence；纯 helper 不自行提升或降低模型置信度。
- warnings 必须是新数组，不能复用输入对象；同一 warning 不重复追加。
- helper 不修改 value、record、quality 或任何全局状态；同一输入和 options 必须
  得到深相等结果。
- field 只能是 Phase 01 RecognitionFieldKey 中的字段。Phase 02 重点施工
  scene、shot、take、cardNumber、videoCode；其他字段必须明确走“原值+无 warning”
  或已有专用处理，不能误套数字规则。

### 记录级 API

在 shared helper 或 lib/schema.mjs 提供记录级薄封装，职责等价于：

~~~js
normalizeRecognitionRecord(record, options)
normalizeRecognitionSheetFields(result, options)
reviewFieldsFromQuality(record)
~~~

记录级封装必须：

1. 按固定字段顺序处理 cardNumber、videoCode、scene、shot、take。
2. 将字段结果写入 quality.fields；没有 warning 且没有变更的字段仍可省略
   quality.fields，但已有 quality 必须保持原结构。
3. 保留已有 record.reviewRequiredFields，并与新字段的 reviewRequired 合并、去重、
   按固定字段顺序输出；不能删除未知旧字符串。
4. 只把 normalizedValue 写入业务字段；originalValue 只写 quality，不覆盖 raw OCR
   evidence 或诊断块。
5. 不改变 id、targetId、sourcePage、records 顺序或记录数量。
6. 对已存在 quality 的恢复记录保持旧 originalValue/warnings；只有识别合并后的
   新记录才创建新的归一化质量结果。

### warning code 约束

Phase 01 已冻结的 warning code 必须继续支持：

- ambiguous-numeric-token
- invalid-numeric-token
- out-of-range
- conflicting-value
- confusable-character
- missing-value

Phase 02 为了让“中文数字转换”可追溯，允许在 shared contract 中增加
chinese-numeral-converted。新增 code 必须同步更新 TypeScript union、Node 测试、
modern/legacy 展示映射和文档；不能使用含义不匹配的 ambiguous-numeric-token
冒充中文数字转换。

## 归一化算法施工规则

### 统一预处理

按以下顺序执行，顺序不可由调用方改变：

1. null、undefined、空字符串和只含空白的输入归一为 null。
2. 对字符串执行 NFKC，去除首尾空白；保留中间分隔符，不能无条件删除所有
   标点或字母。
3. 识别字段上下文后，才允许在候选数字 token 内执行混淆字符替换。
4. 将中文数字 token 解析为整数；失败时不继续猜测。
5. 做字段范围、格式和多 token 规则校验。
6. 通过字段专用 formatter 生成 normalizedValue；若任何校验不确定，返回原值
   加 warning/review，而不是返回部分修复结果。

### 中文数字规则

#### 逐字数字模式

下列字符在连续的逐字数字模式中按单个数字处理：

- 零、〇 → 0
- 一、壹 → 1
- 二、两、贰 → 2
- 三、叁 → 3
- 四、肆 → 4
- 五、伍 → 5
- 六、陆 → 6
- 七、柒 → 7
- 八、捌 → 8
- 九、玖 → 9

因此必须得到：

| 输入 | 结果 | review | 说明 |
| --- | --- | --- | --- |
| 二〇三 | 203 | 是 | 逐字数字转换，保留 warning |
| 一〇五 | 105 | 是 | 逐字数字转换，保留 warning |
| 〇七 | 07 后再按字段位宽处理 | 是 | 0 是有效数字，不得丢失语义 |

#### 单位数字模式

支持当前需求范围内的 十、百 两个单位，以及零占位：

| 输入 | 结果 | review | 说明 |
| --- | --- | --- | --- |
| 十一 | 11 | 是 | 缺省十位按 1×10 处理 |
| 二十三 | 23 | 是 | 二×十+三 |
| 一百零五 | 105 | 是 | 一×百+零+五 |
| 一百二十 | 120 | 是 | 一×百+二×十 |
| 二百〇三 | 203 | 是 | 〇 作为零占位 |

解析器必须拒绝或标记不确定的重复单位、逆序单位、混合未知字符、负号、小数和
跨 token 粘连，例如 十百、百十十、十点五、十一二。结果必须保留输入原值并加
invalid-numeric-token 或 ambiguous-numeric-token。

#### 范围与安全边界

- 延续现有 FIELD_NUMBER_LIMIT：整数必须满足 0 <= value < 1,000,000。
- 不接受小数、指数、负数、Infinity、NaN 或超出安全整数的值。
- shot/take 只有一个数值 token；scene 可以有多个场次 token，但每个 token
  都必须独立通过范围校验。
- 位宽只补前导零，不截断超出位宽的合法数字。

### 字段专用规则

| 字段 | 接受的规范化形态 | 可自动修复 | 必须保留原值并复核 |
| --- | --- | --- | --- |
| scene | 单个数字、数字+字母后缀、多个场次以 canonical  /  连接 | 中文数字、全角数字、明确的已知“第/场”包装、后缀大写、单一数字按 fieldFormats 补零 | 多个解释、未知字母夹在数字中、范围/小数/越界、后缀可能是误识别数字 |
| shot | 单个整数，按 fieldFormats.shot 补零 | 中文数字、全角数字、明确的“镜”包装、补零 | 多个数字、含不明字母/符号、越界、不能确定数字边界 |
| take | 单个整数，按 fieldFormats.take 补零 | 中文数字、全角数字、明确的“次”包装、补零 | 多个数字、含不明字母/符号、越界、不能确定数字边界 |
| cardNumber | 摄影机字母 + 数字卷号；字母大写、卷号按现有 3 位规则 | NFKC、空格/连字符清理、明确数字 token 的中文数字、字母大小写 | 缺摄影机字母、多个候选卷号、数字越界、疑似把视频码/文件名后缀当卡号 |
| videoCode | C + 三位数字，现有 C0XX 规则 | NFKC、已知 C 前缀空格、明确数字 token 的中文数字、前导零补齐 | C115、C1234、多个编号、范围、未知前缀、confusable 映射后仍有歧义 |

字段规则必须复用现有 fieldFormats；默认 scene 至少 3 位、shot/take 至少
2 位，项目自定义位宽仍由调用方传入。cardNumber/videoCode 的 canonical key
逻辑不能因为展示位宽变化而改变。

### 混淆字符规则

混淆字符只允许发生在已经确认的数字上下文：

1. 先做 NFKC；ASCII/full-width 的确定等价形式不计作跨字符猜测。
2. 已确认的 C 前缀、摄影机字母之后的数字后缀、scene/shot/take 单一数字候选
   中，才允许使用有限 allowlist：
   - O/o/О/о → 0
   - I/i/l/|/丨 → 1
   - S/s → 5，仅限相邻已有数字且不会与 scene 字母后缀混淆的 token
3. 不得在整个字符串上执行 O→0、I→1、S→5 的全局 replace。
4. 不把 B、Z、G、D、Q 等字母默认转换成数字；需要新映射时必须增加独立 fixture
   和 warning 规则。
5. 如果一个字符既可解释为数字也可解释为 scene/card 的合法字母后缀，则保留
   原值并报 ambiguous-numeric-token，不得选择看起来更整齐的一种。
6. confusable-character 的 warning 必须标记 reviewRequired=true，即使转换后的
   值通过了范围校验。

示例：

| 输入 | 字段 | 预期 |
| --- | --- | --- |
| C O 1 | videoCode | 只有在 C + 数字上下文明确时才可得到 C001，并标记复核 |
| A O 1 | cardNumber | 可得到 A001，并标记复核 |
| 1O | shot | 可得到 10，并标记复核 |
| 12O | scene | O 可能是后缀或 0，保留原值并标记歧义 |
| B001 | cardNumber | B 是合法摄影机字母，不得变成 8001 |
| A1B | cardNumber | B 是不确定尾缀，保留原值并标记复核 |

### reviewRequired 判定矩阵

| 情形 | normalizedValue | changed | reviewRequired | warning |
| --- | --- | --- | --- | --- |
| trim/NFKC/合法大小写/纯补零 | canonical | 是 | 否 | 无 |
| 二〇三、十一、一百零五 | canonical | 是 | 是 | chinese-numeral-converted |
| 明确上下文中的 O/I/l/S 映射 | canonical | 是 | 是 | confusable-character |
| 解析失败、越界或多种解释 | original | 否或仅 NFKC | 是 | invalid/ambiguous/out-of-range |
| 缺失值 | null | 否 | 否；除非原有 review 标记 | missing-value 可选，仅当调用方需要解释缺失 |
| 原值已经 canonical | original | 否 | 否 | 无 |

已有 high-accuracy 冲突、sequence repair 或人工标记产生的
reviewRequiredFields 必须保留；不能因为本次字段没有发生改变而清掉旧标记。

## 最终识别流水线与接线顺序

Phase 02 的唯一归一化闸门必须位于“模型识别/高精度合并完成”之后：

~~~text
模型页响应
  → normalizeSlateResult：只做 shape/null/status/confidence 防御性校验
  → mergePageResults：合并、high-accuracy 冲突处理、sequence repair、targetId
  → normalizeRecognitionSheetFields：调用 shared helper，生成最终字段质量
  → formatSlateResultFields：保留旧导出名，内部只委托统一归一化/格式适配
  → task snapshot / modern store / legacy state
  → 展示与 CSV merge/export
~~~

实施要点：

1. normalizeSlateResult 不得在每个 provider page 上提前生成最终 quality，也不得
   在 page-local index 上生成稳定 targetId。
2. mergePageResults 的 sequence 检查若需要数字比较，使用 shared helper 的
   非写入比较结果；不要再复制中文数字、范围和混淆字符规则。
3. targetId 必须在现有最终 records 顺序上保持不变；归一化不能改变数组顺序、
   数组长度、id 或 targetId。
4. formatSlateResultFields(result, formats) 继续作为已有调用方的兼容出口，但
   最终质量必须在该出口之前或其中由同一 shared helper 一次产生，不能在
   ai-client、schema、Renderer 各生成一份互相覆盖的 quality。
5. 归一化失败时把原字段值写回 record，字段质量记录 warning/review；后续
   canonicalMaterialKey/CSV matching 仍可判定该值无效并给出已有缺失 key 警告，
   不能为了匹配而猜一个新的 card/video。
6. result.warnings 可以增加面向用户的汇总 warning，但字段级 details 必须留在
   quality.fields[field].warnings 中，不能只拼成一段文本后丢失结构。

## CSV 接线设计

### shared 与 resolve-csv 的关系

public/resolve-csv.js 中的 normalizeSceneValue、normalizeShotValue、
normalizeTakeValue、normalizeMetadataField 继续导出以兼容现有调用方，但只做
参数适配：

- 输入 field/formats，调用 public/metadata-common.js 的字段专用 helper。
- 将 shared 的 null 映射成 CSV 层既有的空字符串；不得把不确定值改为另一个
  canonical 数字。
- CSV 层不修改识别 record.quality；它可以把 source row 的 previous/next、
  warning code 和 reviewRequired 加入 changes/merge warnings。
- encodeResolveCsv 可以做最后一次幂等防线，但必须证明第二次调用不会追加重复
  warning、不会改变原始不确定值，也不会改变普通 fixture 字节。

### buildStandaloneResolveTable

- 对 scene/shot/take 使用 shared 规则生成 Resolve 四列。
- record.comments 继续按现有 comments 配置写入，不把 description 或 OCR 原文
  写入 Resolve Comments。
- 不完整或不确定的 scene/shot/take 继续跳过 standalone 行，并沿用现有 warning；
  不得用 review 标记掩盖缺失。
- 若 record 已有 quality，输出只读取 normalized record value，不重建或覆盖
  quality.originalValue。

### mergeSlateIntoResolveTable

- 识别记录先按 canonicalMaterialKey 进行匹配，card/video 的不确定值不得被
  自动猜成有效 key。
- 对已有 Resolve source row 的 Scene/Shot/Take 仍执行整表 canonicalization；
  每个变化继续记录 rowIndex、field、header、previous、next，并补充可选的
  warningCode/reviewRequired。
- 归一化 source row 不得改写 sourceEncoding、format.encoding、delimiter、
  lineEnding 或 finalNewline。
- 已有 CSV 的非目标列、原始文件名、素材目录、备注之外的字段必须保持原值。

## 持久化、恢复与编辑语义

### quality 与兼容投影

持久化 record 继续允许新字段缺失：

~~~text
旧任务：record + reviewRequiredFields?
新任务：record + reviewRequiredFields? + quality?
~~~

- 新识别结果：quality.fields 保存发生变更或需要解释的字段；reviewRequiredFields
  保存 quality.reviewRequired=true 与既有算法标记的兼容投影。
- 旧任务：没有 quality 时照常读取；已有 reviewRequiredFields 不得丢失。
- 恢复时：quality.fields 中 reviewRequired=true 的字段重新并入投影，去重且按
  固定字段顺序输出。
- quality 中 originalValue 为空与“没有 quality 字段”是两个状态，不能把前者
  当作旧任务而删除。
- 保存/恢复不需要 SQLite migration；任务 payload 只增加可选 JSON 字段。

### modern 与 legacy 编辑

- 普通字段编辑仍只更新该字段及任务 dirty 状态。
- confidence select 仍只更新 confidence；不得因为改置信度而重跑归一化或清除
  reviewRequiredFields。
- 用户编辑不会隐式删除 quality 或 reviewRequiredFields；originalValue/warnings
  保留以便审计，新的手工值由现有 editedRecords 持久化。
- 手工新增记录沿用 manual targetId 规则；没有 OCR 原值的字段不要伪造
  chinese-numeral warning。
- 删除记录不得重排或重写其余记录的 targetId。

## modern 结果界面施工设计

### 控件和状态

在 RecognitionResultPanel.tsx 增加：

- filter 状态：all（默认）和 review。
- 现有 search 与 filter 同时生效；搜索范围继续覆盖现有可编辑字段。
- reviewRecordCount：至少一个字段待复核的记录数。
- reviewFieldCount：所有记录中待复核字段的总数，计数口径在 UI 文案中固定，
  不因筛选而含糊。
- 顶部状态提示示例：N 条记录 · M 个字段待复核；无复核时不显示错误色。

### 字段标记

- 每个字段单元格从 record.reviewRequiredFields 与 record.quality.fields[field]
  共同计算 reviewRequired。
- 标记放在字段 label/输入框旁，不遮盖输入值；不禁用输入、不改变 tab 顺序。
- title 和 aria-label 至少包含“需复核”、字段名、originalValue（如存在）和
  warning message 的摘要；原始值要经过现有 escape/React 文本节点处理。
- 只在字段级标记 warning，不把整行渲染为不可编辑；整行仍可由 confidence、
  删除和已有编辑操作处理。
- 复核筛选只影响 visibleRecords，不修改 store，不修改记录顺序。

### modern 测试要求

- 默认筛选显示全部记录。
- 仅复核筛选显示带任一 review field 的记录，不误把 low confidence 但无
  reviewRequiredFields 的记录纳入。
- 同一记录多个字段只计一条 review record，但字段数按字段分别计数。
- 输入编辑、Enter/Escape、IME composition 和 confidence select 的既有测试仍通过。
- 恢复带 quality 的任务后 badge、filter 和数量与保存前一致。

## legacy 结果界面施工设计

### HTML/CSS/JS 接线

- public/index.html 在 detail-search 附近增加可访问的 filter select 或等价控件，
  默认 value=all；保留原有搜索框 id 和布局。
- public/app.js 在 state 中增加 detailReviewFilter；visibleDetailRecords 同时
  应用 search 和 review predicate；clear-search/新建记录/重置结果时恢复 all。
- renderTable 的 textCell 或字段单元格渲染需带 data-field 和 review badge；
  badge 的文本、title、aria-label 不得直接插入未经 escape 的原值/warning。
- public/styles.css 只增加紧凑、可换行且不影响表格横向滚动的标记样式；移动宽度
  下 badge 不得覆盖编辑输入。
- renderResultSummary 增加复核数量，沿用现有 warning/status 区域，不重复打印
  每个 warning 全文。

### legacy 恢复要求

restoreTask 之后执行与 modern 相同的 quality → reviewRequiredFields 投影；旧
任务没有 quality 时直接使用原 reviewRequiredFields。state.records 的字段值不能
因为展示而再次变换或丢失原 quality。

## 测试夹具与验证矩阵

本节列出的测试在真正施工阶段执行；本次生成施工包不执行。

### 共享 helper 单元测试

新增或扩展 metadata-common 相关测试，至少覆盖：

| 输入 | 字段 | expected normalizedValue | review | 必要 warning |
| --- | --- | --- | --- | --- |
| 二〇三 | scene | 203（再按 scene width 处理） | 是 | chinese-numeral-converted |
| 十一 | shot | 11（再按 shot width 处理为 11） | 是 | chinese-numeral-converted |
| 一百零五 | take | 105 | 是 | chinese-numeral-converted |
| 二百〇三 | scene | 203 | 是 | chinese-numeral-converted |
| ３７a / 58 | scene | 037A / 058 或按现有多场次 canonical 规则 | 否或按转换来源复核 | 仅在发生中文/混淆转换时 |
| 9 | take | 09 | 否 | 无 |
| 100 | take | 100 | 否 | 无 |
| 十百 | shot | 原值 | 是 | invalid/ambiguous |
| 1000000 | scene | 原值 | 是 | out-of-range |
| O8 | shot | 08 或原值，取决于上下文 | 是 | confusable-character 或 ambiguous |
| 12O | scene | 原值 | 是 | ambiguous-numeric-token |
| null | videoCode | null | 否 | 可选 missing-value |

每个用例还要断言输入对象未被修改、warnings 为新数组、重复调用幂等。

### Node schema / ai-client 测试

- provider page 的原始中文值在 page-local normalize 后仍可追溯，最终合并后才
  出现 normalizedValue/quality。
- merge 后记录顺序、id、targetId、sourcePage、记录数量完全不变。
- high-accuracy conflict、sequence repair 产生的旧 reviewRequiredFields 与
  Phase 02 自动标记合并，不发生覆盖。
- 二〇三、十一、一百零五在最终 result 中分别得到预期值和 quality。
- 不确定 card/video 保留原字段值，canonicalMaterialKey/CSV status 仍明确提示
  不可匹配，不得生成另一张“修复后”记录。
- raw OCR evidence、bbox、diagnostic snapshot 与归一化前 fixture 深相等。

### CSV 测试

扩展 test/resolve-csv.test.mjs、test/csv-background-tasks.test.mjs：

- buildStandaloneResolveTable、mergeSlateIntoResolveTable 和 encodeResolveCsv
  对同一 field fixture 产生与 shared helper 一致的 canonical Scene/Shot/Take。
- Node 识别结果和 browser CSV worker 结果对二〇三、十一、一百零五、full-width
  digits、confusable context 的 normalized values 一致。
- source row 不确定时保留原 cell，changes/warnings 有明确说明。
- 所有 baseline CSV 的默认编码、BOM、delimiter、line ending、final newline 和
  普通数据行字节保持不变；不得通过改 golden 绕过失败。
- resolve comments 的现有 allowlist 规则、非目标列和 sourceEncoding 继续通过。

### 持久化与跨 Renderer 测试

- test/task-persistence.test.mjs：带 quality 和 reviewRequiredFields 的任务保存后
  重新读取深相等；无 quality 的旧 fixture 仍可读。
- modern WorkspacePage：quality review 投影不重复、不丢旧字符串。
- legacy restoreTask：同一 fixture 恢复后 review badge/filter 输入状态与字段值一致。
- test/recognition-target.test.mjs：归一化前后 targetId 完全一致，编辑 card/video
  后 targetId 不变。

### UI 测试

扩展 test/refactor/ip-03-08/virtual-table.test.tsx：

- 渲染字段 badge、复核数量、默认 all filter 和 review filter。
- 编辑带 review 的字段不会删除 quality/reviewRequiredFields。
- confidence select 仍可操作，低置信度和待复核是两个独立维度。
- warning/originalValue 使用可访问文本，不产生未转义 HTML。

legacy 至少增加 DOM/静态行为测试；若当前测试环境没有 legacy DOM harness，
必须用现有的 browser/e2e 测试入口覆盖 filter、badge、编辑保存和恢复，不得只以
手工点击作为验收证据。

## 推荐施工顺序

每一步完成后先做该步最小验证，再进入下一步；本次只编制顺序，不执行。

1. **基线与 fixture**：保存 status、现有 fixture 检查结果，新增 Phase 02 输入
   矩阵，不修改 baseline 内容。
2. **shared helper**：实现 token 解析、范围保护、字段规则、warning/quality
   结果和 review 投影；补齐职责注释，说明 Node/browser 共用和“不确定保留原值”。
3. **shared contract**：同步新增 warning code/类型注释，保持旧任务字段可选和
   reviewRequiredFields 兼容。
4. **schema 接线**：把旧 schema normalizer 改成 shared wrapper，拆分 page shape
   校验和最终字段归一化；确保既有导出名不被删除。
5. **ai-client 最终闸门**：在合并、复核、sequence repair 和 targetId 之后接入
   统一记录级归一化；修正比较 helper 只调用 shared parser，不复制规则。
6. **CSV renderer 接线**：替换 resolve-csv 的重复算法，扩展 changes/warnings
   的结构化信息，验证 encode 的幂等性和 baseline bytes。
7. **持久化/恢复**：统一 modern/legacy quality 投影，保留旧 task snapshot、
   手工编辑和 confidence 行为。
8. **modern UI**：增加字段 badge、review filter、计数、aria/title 和样式；先跑
   virtual-table 测试。
9. **legacy UI**：增加 HTML 控件、state predicate、badge、summary 和样式；验证
   搜索、排序、编辑、保存和恢复没有回归。
10. **全量验证与文档**：运行验收命令，记录真实结果，更新 AGENT.md 和本阶段交接
    记录；不得自动进入 Phase 03。

## 验收门槛

只有以下条件全部满足，Phase 02 才能标记完成：

- 二〇三、十一、一百零五、〇、全角数字和已有非法值测试都通过。
- Node schema、modern result store、legacy renderer、CSV worker 对同一 fixture
  的 canonical values 和 review 判定一致。
- 统一归一化确实发生在最终高精度合并之后，没有 page-local quality 覆盖 final
  quality，也没有重复 warning。
- 关键字段自动修复都能追溯 originalValue、normalizedValue、warning 和 review。
- 不确定字段保留原值，未修复字段没有被误改，raw OCR/evidence/diagnostics 不变。
- reviewRequiredFields 可与 quality 双向兼容投影，旧任务可读，新任务可保存/恢复。
- modern/legacy 结果表都能筛选待复核记录、显示字段标记和数量，编辑/confidence
  行为不受影响。
- targetId 在归一化、CSV merge、编辑、保存、恢复前后保持稳定。
- 现有 baseline CSV、Resolve comments、source/output encoding 契约没有无关变化。
- 所有测试和静态检查均有真实命令输出；没有以“未运行”或手工观察替代必需证据。

推荐验收命令：

~~~sh
npm run check
npm run typecheck
npm run test:node
npm run test:modern
npm run validate:modern
git diff --check
~~~

若仓库已有更窄的 test:node/test:modern 分片命令，执行者可先运行受影响分片，
但最终交接必须保留上述全量命令或等价完整证据。不得启动 Electron GUI、真实 OCR、
真实 provider 或默认 Project Library 作为本阶段自动验收条件。

## 停止条件、回滚边界与风险控制

出现任一情形必须停止继续施工，保留失败证据并回报，而不是放宽断言：

- shared helper 需要访问 DOM、window、Node 专有 API 或 mutable singleton，导致
  Node/browser 不能共用纯函数。
- 不确定输入被转换为另一个有效数字、被静默置 null，或原始 OCR/evidence 被覆盖。
- 二〇三、十一、一百零五在任一层结果不一致，或 warning/review 在层间重复/丢失。
- 需要依赖 card/video/scene/shot/take 改写 targetId、排序 records 或新增数据库列。
- 需要新增 IPC channel、改变 task envelope、改写已有历史任务或访问真实 Library。
- 普通 baseline CSV 字节、BOM、delimiter、line ending、非目标列发生变化。
- legacy 或 modern 为了显示 badge 直接重建 record，导致 quality、targetId 或旧
  reviewRequiredFields 丢失。
- 需要大范围重写 public/app.js 或不相关 UI 才能接入筛选。

回滚只允许撤销 Phase 02 实际改动的源码、fixture 和测试；不得使用 git reset --hard、
git checkout --、删除整个工作区或清理 Owner 的未相关改动。施工包文档本身可保留
失败记录，便于下一次继续。

## 交付物与 Phase 03 交接

Phase 02 施工完成后应交付：

1. 一份 Node/browser 共用的 metadata normalization helper 及职责注释。
2. schema/ai-client/resolve-csv 的统一接线，最终识别记录带可追溯 quality。
3. modern/legacy 字段复核标记、筛选和数量提示。
4. 新增 normalization、CSV parity、persistence round-trip、targetId stability、
   UI interaction 的测试与 fixture。
5. baseline CSV/任务兼容和 raw evidence 不变的验证证据。
6. 更新后的 AGENT.md 与 Phase 02 完成记录，明确没有实现 Phase 03–06。

交给 Phase 03 时，必须明确以下接口已经可用：

- 识别记录字段已经是 canonical value，或带有原值和明确 review warning。
- CSV 层可以取得 source row 的 canonical change/warning，而不会丢 sourceEncoding。
- reviewRequiredFields 是稳定兼容投影，quality.fields 是详细审计信息。
- targetId 与归一化无关，后续 CSV export/crop recheck 不得重新生成。
- Phase 03 可以直接消费这些结果，不需要在 Renderer 里重新实现中文数字或混淆
  字符规则。
