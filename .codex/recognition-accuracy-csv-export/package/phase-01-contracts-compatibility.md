# Phase 01：契约与兼容性基础

> **施工包状态：READY FOR IMPLEMENTATION — DOCUMENT ONLY**
>
> 本文档于 2026-09-10 生成。本次请求只编制施工包，不执行其中任何施工步骤；
> 不修改源码、不更新 `AGENT.md`、不运行测试/构建、不启动 Electron、不读写真实
> Project Library，也不进行 Git 暂存、提交、切分支或清理。后续执行者必须先完成
> 本文档的前置门禁，再按施工顺序实施。

## 目标

建立所有后续阶段共用的数据契约，并确保现有项目、任务和 CSV 行为不被破坏。

## 前置条件

- 分支：`feat/electron/accuracy-csv`
- 当前基线检查通过。
- 更新根目录 `AGENT.md`，记录本方案允许修改 OCR、CSV 和 ProjectSettings 的边界。

## 主要任务

### 1. 共享契约

在 `src/shared/contracts/index.ts` 中定义或扩展：

- `ExportOptions`
- `ExportColumnKey`
- 语义列定义及显示表头映射
- `ResolveCsvSourceEncoding`
- `targetId`
- 归一化警告和字段级质量元数据

`format.encoding` 继续只表示最终导出编码，GBK/GB18030 必须放入单独的源文件编码字段。

### 2. ProjectSettings 版本兼容

在 `lib/project-settings.mjs` 中：

- 保持 v1 可读取。
- 将旧设置归一化到内部 v2。
- v2 支持 `export` 分支。
- 保存时保留未知字段，避免旧 UI 丢失新配置。
- 为 export 配置增加默认值和校验。

### 3. 稳定复核目标

定义与页码、记录索引相关的稳定 `targetId`，后续 crop recheck 不得依赖识别出的卡号或视频号进行匹配。

### 4. 注释和文档

为新增的归一化、迁移、导出契约补充职责、兼容性和生命周期注释，并更新 `AGENT.md`。

## 重点文件

- `src/shared/contracts/index.ts`
- `lib/project-settings.mjs`
- `src/renderer/features/settings/ProjectSettingsPage.tsx`
- `public/app.js`
- `AGENT.md`

## 验收标准

- v1 项目可以打开、读取和保存。
- 保存旧项目不会删除 `export` 或其他未知设置。
- 新旧设置归一化结果稳定。
- 默认导出配置与当前版本一致。
- 契约测试覆盖 v1、v2 和异常配置。

---

## 施工包元数据与实施边界

### 施工目标

把当前只描述目标的 Phase 01 落成一个可独立实施、可验证、可回滚的兼容性
基础包。该包只负责定义后续 Phase 02–06 必须共同遵守的类型、迁移规则和
稳定身份，不在本阶段实现中文归一化、CSV 解码/合并、OCR alternatives、图像
增强或 crop recheck 算法。

### 实施前门禁

1. 在开始任何源码改动前，确认实际工作分支是否为
   `feat/electron/accuracy-csv`。本次只读检查已确认当前工作区
   分支与该名称一致；施工包仍不授权切换或重命名分支。
2. 先在根目录 `AGENT.md` 追加本方案的真实授权边界：允许新增 v2
   `ProjectSettings`、CSV 导出配置的类型与持久化字段、稳定 `targetId` 和兼容
   适配；仍禁止改变无参数 CSV 字节语义、IPC 基本语义、SQLite schema、任务格式
   和 OCR 算法。没有这条记录，不得开始实现。
3. 记录初始 `git status --short` 和工作区已有未跟踪的
   `.codex/recognition-accuracy-csv-export/` 内容。不得覆盖、删除或重排 Owner
   已有改动。
4. 所有迁移/持久化测试只能使用新建的临时库路径。禁止访问默认 macOS
   Project Library，也不得复制、哈希、查询、恢复或删除该路径的内容。
5. 先锁定当前默认 CSV 字节 fixture 和 v1 设置 fixture；若基线 fixture 需要
   改写而不是新增兼容 fixture，应立即停止并记录阻塞。

### 允许修改的路径

- `src/shared/contracts/index.ts`：新增共享类型、默认导出契约常量和类型注释。
- `lib/project-settings.mjs`：v1→v2 归一化、默认值、未知字段保留和校验。
- `lib/project-library.mjs`：让项目更新以已持久化 settings 作为兼容 fallback，
  避免旧 Renderer 的 v1 payload 截断未知字段。
- `electron/ipc-handlers.mjs`：移除会在 project-library 之前截断数据的重复设置
  归一化；不新增 IPC channel，不改变 Result/AppError 语义。
- `lib/schema.mjs`、`lib/ai-client.mjs`：只为识别记录补齐稳定 `targetId`；不得
  在本阶段改变模型 schema、提示词、识别排序、归一化结果或重试逻辑。
- `src/renderer/features/settings/ProjectSettingsPage.tsx`、
  `src/renderer/features/settings/projectSettingsActions.ts`、相关 settings store：
  默认使用 v2，并保证未提供导出控件的旧表单不会重建并丢弃 `export` 分支。
- `public/app.js`：legacy 设置表单只更新已展示字段，保留当前项目的 v2/export
  和未知字段；不在本阶段增加导出选项 UI。
- 现有 Node/modern 测试和新增的 Phase 01 fixture/test 文件。
- `AGENT.md`：仅在真正实施并验证后追加方案事实；本次文档生成不改它。

### 保护范围

- `public/resolve-csv.js` 的解码、匹配、归一化、合并、编码、默认字节行为。
  本阶段只定义类型隔离，GBK/GB18030 实际读取放到 Phase 03。
- `public/metadata-common.js` 的中文数字算法和 `lib/schema.mjs` 已有识别归一化
  语义；本阶段只允许最小的 target 赋值接线。
- OCR provider、prompt、runner、缓存 key、图像准备和 high accuracy 算法。
- `window.slateSync`、Preload、IPC channel 名称、Result/AppError envelope。
- SQLite 表结构、Project Library/Task/Scenario/Diagnostic 格式、version-1
  迁移、文件名、排序、时间戳和用户数据位置。
- 默认 Project Library、真实 provider/credential、Electron GUI、发布签名和 Git
  历史。

### 停止条件

出现下列任一情况，停止实现，不通过放宽断言或改写 golden 继续推进：

- 需要新增 IPC 通道、改变已有 IPC payload 基本语义或修改 SQLite schema；
- 需要让 `format.encoding` 接受 `gbk`/`gb18030` 作为导出编码；
- 需要用卡号、视频号、素材 key 或不稳定的随机 `id` 生成 crop 复核身份；
- 旧配置保存必须删除未知字段才能通过类型检查；
- 发现 version 大于 2 且没有 Owner 明确的向前兼容策略；
- 测试需要访问真实 Library、真实 provider、前台 Electron 或生产密钥；
- 任何已有 baseline fixture、默认 CSV 字节 golden 或旧 IPC contract 需要被自动
  接受、跳过、放宽或重写；
- 需要扩大本文档允许的路径，或当前分支/基线归属仍未得到确认。

## 当前基线事实（执行者需以代码复核为准）

本节是编制施工包时的只读观察，不是已完成的施工结果：

1. `ProjectSettings` 当前公开为 v1；`lib/project-settings.mjs` 的
   `normalizeProjectSettings` 只返回已知字段，未知顶层字段和未来分支会被丢弃。
2. `lib/project-library.mjs` 的 `updateProject` 会直接对 Renderer payload 做
   `validateProjectSettings`，`electron/ipc-handlers.mjs` 还会先重复校验一次；
   这两个调用点必须统一为“读取当前值作为 fallback、由 project-library 单一
   入口归一化”。
3. modern `ProjectSettingsPage` 的 fallback 仍写入 `version: 1`；legacy
   `buildProjectSettingsFromForm` 也重新构造 v1 对象，因此新增 `export` 分支会在
   保存时被截断。
4. 当前 Resolve table 的 `format.encoding` 在 decode 结果中承载源文件编码；新
   契约必须把源编码拆到 `sourceEncoding`，但 Phase 01 不改变现有 CSV 实现。
5. 当前识别记录的 `id` 含有时间或 UI 身份语义，不能作为 crop recheck 的稳定
   目标；最终分页合并处已有页码和顺序信息，应在那里生成独立的 `targetId`。

## 共享契约施工设计

### 1. CSV 导出契约

在 `src/shared/contracts/index.ts` 增加下列类型；名称和字段是后续 Phase 03/04
的冻结接口，实施时不得由 UI 文案反推语义：

```ts
export type ExportColumnKey =
  | "scene"
  | "shot"
  | "take"
  | "comments"
  | "takeStatus"
  | "cardNumber"
  | "videoCode"
  | "sourcePage";

export interface ExportColumnConfig {
  readonly key: ExportColumnKey;
  readonly header: string;
  readonly enabled: boolean;
}

export interface ExportOptions {
  readonly columns: readonly ExportColumnConfig[];
  readonly format: ResolveCsvFormat;
  readonly filenameTemplate: string;
}

export type ResolveCsvSourceEncoding =
  | "utf-8"
  | "utf-16le"
  | "utf-16be"
  | "gbk"
  | "gb18030";
```

具体规则：

- `key` 是字段身份，`header` 只是显示/输出表头；任何匹配、编辑、恢复和导出
  逻辑不得通过表头字符串判断字段。
- `columns` 中同一个 `key` 只能出现一次；至少保留一个 `enabled` 列；表头不得
  为空、包含换行或路径控制字符。长度限制和非法字符处理集中在后续共享校验
  函数，不能由 modern/legacy 各自实现。
- 默认启用 `scene`、`shot`、`take`、`comments`，默认表头为 `Scene`、`Shot`、
  `Take`、`Comments`；`takeStatus`、`cardNumber`、`videoCode`、`sourcePage`
  默认关闭。默认顺序必须保持当前 standalone 导出的四列顺序。
- `format.encoding` 只允许最终输出编码
  `utf-8`、`utf-16le`、`utf-16be`；`gbk` 和 `gb18030` 只能出现在源文件字段
  `sourceEncoding`，不能进入最终输出 format。
- `filenameTemplate` 是项目默认值的契约字段，但本阶段不提供编辑控件；文件名
  token 的解析、过滤和固定时间注入测试属于 Phase 04。

`ResolveCsvTable` 保留现有 `format` 兼容字段，并新增：

```ts
readonly sourceEncoding?: ResolveCsvSourceEncoding;
```

新表格必须把检测到的源编码写入 `sourceEncoding`，并把输出编码写入
`format.encoding`。读取旧任务快照时，若没有 `sourceEncoding`，兼容适配器才可
把旧的 UTF 编码字段临时解释为源编码，同时保留相同的 UTF 输出编码，以保持
默认字节结果；不能把 GBK/GB18030 塞回 `format.encoding`。

### 2. 归一化警告和字段质量契约

新增受限的字段集合，不使用任意字符串作为跨层质量字段：

```ts
export type RecognitionFieldKey =
  | "cardNumber"
  | "videoCode"
  | "scene"
  | "shot"
  | "take"
  | "takeStatus"
  | "description"
  | "comments"
  | "shotSize"
  | "cameraPosition";

export type NormalizationWarningCode =
  | "ambiguous-numeric-token"
  | "invalid-numeric-token"
  | "out-of-range"
  | "conflicting-value"
  | "confusable-character"
  | "missing-value";

export interface NormalizationWarning {
  readonly code: NormalizationWarningCode;
  readonly field: RecognitionFieldKey;
  readonly message: string;
  readonly originalValue: string | null;
  readonly normalizedValue: string | null;
}

export interface FieldQualityMetadata {
  readonly field: RecognitionFieldKey;
  readonly originalValue: string | null;
  readonly normalizedValue: string | null;
  readonly changed: boolean;
  readonly confidence: "high" | "medium" | "low" | null;
  readonly reviewRequired: boolean;
  readonly warnings: readonly NormalizationWarning[];
}

export interface RecognitionQualityMetadata {
  readonly fields: Readonly<Partial<Record<RecognitionFieldKey, FieldQualityMetadata>>>;
}
```

把 `RecognitionRecord` 的 v2 live shape 扩展为带 `targetId` 和可选 `quality`；
`PersistedRecognitionRecord` 的这两个字段仍然可选，以便读取旧任务。现有
`reviewRequiredFields` 继续保留，v2 归一化时由 `quality.fields[*].reviewRequired`
生成去重、稳定排序的兼容投影；旧字符串标记不能在恢复时被删除。原始值必须放在
`originalValue`/证据层，归一化值不能覆盖它。

### 3. v2 ProjectSettings 形状

`ProjectSettings` 的公开 v2 形状保持现有识别和 Resolve 字段，并新增：

```ts
readonly version: 2;
readonly export: ExportOptions;
```

`DEFAULT_PROJECT_SETTINGS.export` 应冻结为与当前无参数 standalone 导出兼容的
默认值：

- 列：`Scene, Shot, Take, Comments`，对应四个语义 key，均 enabled；
- 编码：UTF-16LE、BOM、逗号分隔、CRLF、末尾换行；
- 文件名模板：`{source}_场记识别.csv`；
- 其他可选列默认关闭。

不要把 `sourceEncoding` 放入项目默认设置；它属于每个被加载 CSV 的输入事实。
`ProjectSettings` 的 TypeScript 类型只公开已知 v2 字段，未知字段的运行时保留
由 Main 侧归一化负责，不能通过增加 `[key: string]: unknown` 逃避校验。

## ProjectSettings 迁移与保存算法

### 归一化入口

在 `lib/project-settings.mjs` 保留现有导出函数名，扩展其职责：

- `projectSettingsFromWorkflow(workflowConfig)` 返回完整 v2 默认设置；
- `normalizeProjectSettings(value, fallback)` 是唯一纯归一化入口；
- `validateProjectSettings(value, fallback)` 调用同一归一化逻辑并检查最终不变量，
  不再另写一套 export 校验；
- 增加职责、版本迁移、未知字段保留和“不在读取时自动写回”的注释。

归一化顺序必须固定为：

1. 非对象、`null` 或损坏输入按空对象处理；只接受 JSON-safe plain object，拒绝
   原型污染键（至少 `__proto__`、`prototype`、`constructor`）。
2. 缺失 `version` 按 v1 读取；`version: 1` 和 `version: 2` 可读。`version > 2`
   不得静默降级为 v2，应抛出带稳定 code 的不支持版本错误并停止写入。
3. 对已知字段按 `source > fallback > default` 取值并清洗：ID 为空转 `null`、
   prompt 保持现有 2000 字符限制、Resolve 格式/标记沿用当前规则、export format
   只接受允许的最终输出编码。
4. 对未知字段按 `fallback` 后 `source` 的顺序做 JSON-safe 深合并；已知字段在
   最后由规范化值覆盖。不得改变传入对象，不得因为 v1 没有 `export` 就清除
   fallback 中的 `export` 或其他未来分支。
5. 若 v1 没有 `export`，补入冻结默认值；若 v2 的 export 子字段缺失，只补缺失
   子字段，不重置用户已有的合法列、表头、格式或文件名模板。
6. 输出内存对象的 `version` 固定为 2；读取本身不落盘，只有明确的项目保存、创建
   或导入操作才把 v2 结果写回。

未知字段保留的边界必须写清：旧 Renderer 发送不含 `export` 的 v1 payload 时，
Main 以数据库中当前 settings 作为 `fallback`，所以整条现有 `export` 分支和未来
分支原样保留；v2 Renderer 发送完整分支时，只覆盖它明确提交的已知值。数组中的
未来列配置不得由 legacy 表单重新生成，只有 Phase 03/04 的 v2 导出编辑器才可
显式替换该数组。

### 调用点改造

1. `lib/project-library.mjs` 的 `createProject`/`createProjectWithId` 继续校验
   新建或导入 payload；`updateProject` 先读取 `current.settings`，再执行
   `validateProjectSettings(patch.settings, current.settings)`。项目数据库仍只写
   一个 `settings` JSON 值，不新增 SQLite 列或 schema version。
2. `readProjectSettings` 读取 v1 时只在内存中返回 v2；JSON 损坏仍按既有 fallback
   行为恢复并记录现有错误边界，不在打开项目的读路径自动改写文件。
3. `electron/ipc-handlers.mjs` 的 `update-project` 不得先调用不带 fallback 的
   `validateProjectSettings`；把原始 settings payload 交给 project-library 的
   单一入口，保持已有 channel、Result/AppError 和项目写租约不变。
4. 项目导入走同一 v1→v2 归一化入口；导入成功后新项目保存 v2，未知 JSON-safe
   字段仍存在。任务中已有的 `projectSettingsSnapshot` 只在读取时归一化，不因
   Phase 01 自动重写历史任务。

## 稳定 targetId 施工设计

### 身份规则

定义受任务/识别结果作用域内唯一的纯函数：

```text
targetId = "page:" + (sourcePage ?? "unknown") + ":record:" + recordIndex
```

其中 `recordIndex` 是最终 `RecognitionSheet.records` 合并顺序中的 **0-based**
索引，不是卡号、视频号、素材 key，也不是随机时间戳。相同页码和最终顺序在同一
输入下必须得到相同 ID；修改该记录的 card/video/scene/shot/take 值不得改变 ID。

### 赋值位置和兼容规则

- 在 `lib/ai-client.mjs` 的分页结果完成 high-accuracy 合并、确定最终 records
  顺序后生成 target；不要在模型单页临时结果阶段用局部 index 生成最终 target。
- `lib/schema.mjs` 可提供纯格式化/校验 helper，但不得借此改变现有 model schema、
  prompt 或字段归一化结果。补充职责注释，说明 `id` 是 UI/编辑身份，`targetId`
  才是 crop recheck 身份。
- 读取旧任务时，若 `targetId` 缺失，用 `sourcePage + 持久化 records 数组索引`
  一次性派生；若已有合法 target，必须原样保留。绝不从 card/video 重新推导。
- 手工新增记录可使用 `manual:<stable-id>`，但必须显式标记为不可进入 crop
  recheck；只有 `page:*` 且有有效来源页的记录才是 OCR 复核候选。
- 删除/编辑记录不得重写其他记录的 target；新增记录不得让旧记录重新编号。若
  后续需要排序，必须先定义独立的持久化 `recordIndex` 迁移，不得在 Phase 01
  偷换 `targetId` 语义。

### 与后续 crop recheck 的接口约束

Phase 06 的 target payload 必须携带 `targetId`、`sourcePage`、字段 key、原始
core 图片、crop 图片和坐标。复核回填只能按 `targetId + field` 定位，并在原记录
已确认时拒绝覆盖；本阶段只冻结身份格式，不实现复核调用。

## modern / legacy 设置兼容改造

### modern

- `ProjectSettingsPage` 的 `settingsDefaults` 改为 v2 并带完整默认 `export`。
- `updateSettings`、Resolve reset 和 settings store patch 必须以当前 settings
  为基底做不可变浅合并，不能从表单字段重新创建整个对象。
- Phase 01 不增加导出选项控件；页面只需能读取/保存 v2 branch，并让 Phase 04
  后续可以在同一 draft 上追加 export 编辑。
- 保存成功后以 Main 返回的完整 settings 作为新的 baseline；保存失败保留原
  draft，不把本地 v1 fallback 重新写回。

### legacy

- `defaultRendererProjectSettings` 返回 v2 最小默认值。
- `buildProjectSettingsFromForm` 从 `state.currentProject.settings`（缺失时才从
  默认值）开始，仅覆盖当前表单展示的 provider/model/accuracy/scenario/prompt/
  resolve 字段，并保留 `export` 和未知字段。
- Phase 01 不在 `public/index.html` 添加 export UI；旧表单保存后必须由 Main
  fallback 继续保留新配置。
- 添加职责注释，明确 legacy 是兼容输入适配器，不是第二套 ProjectSettings
  迁移真相。

## 测试与证据包

以下是实施后必须新增或扩展的测试，不在本次文档生成中执行：

### Node 迁移/契约测试

扩展 `test/project-settings.test.mjs`，覆盖：

1. v1 无 `export` 读取为稳定 v2 默认；重复归一化结果深相等且不修改输入。
2. v1/v2 的 provider、model、prompt、Resolve 自定义值保持不变。
3. v1 payload 经过“当前 v2 settings 作为 fallback”的保存后，原有 export、
   顶层未来字段、nested future branch、合法自定义表头全部保留。
4. export 缺失/部分缺失/非法编码/重复列/空表头时落到确定默认或稳定错误；
   GBK/GB18030 不能成为 `format.encoding`。
5. `version > 2` 不被降级、不写盘；`null`、数组、损坏 JSON 走既有安全 fallback。
6. `projectSettingsFromWorkflow`、`normalizeProjectSettings` 和
   `validateProjectSettings` 的默认/迁移结果保持幂等。

扩展 `test/project-library.test.mjs` 与 `test/electron-ipc.test.mjs`，仅使用
`mkdtemp` 临时库，覆盖：

- 直接更新项目时 legacy v1 payload 不丢失当前 export/未知字段；
- IPC `update-project` 不再先截断 payload；
- v1 项目打开、保存、重新打开后的 version/export/Resolve 值；
- 项目导入将 v1 设置保存成 v2 且保留未知 JSON-safe 字段；
- 既有 project library manifest、任务、归档和安全边界断言不变。

### targetId 测试

在现有 Node recognition/ai-client 测试中增加：

- 相同 page/index 在两次运行中得到相同 target；不同 page/index 不冲突；
- 修改 card/video 不改变 target；high accuracy primary/audit 合并后仍按最终顺序
  只有一个 target；
- 旧 persisted record 缺 target 时可按 page/index 恢复；已有 target 不被覆盖；
- manual target 明确不进入 crop 候选；不能以 `id`、canonical material key 或卡号
  作为 target lookup。

### modern/legacy 静态与组件测试

扩展 `test/refactor/ip-03-08/project-settings.test.tsx` 及 legacy 静态测试：

- modern 默认 settings 为 version 2；提交旧项目时 request 仍携带完整 export；
- Resolve “恢复默认”只改变 resolve，不清除 export/未来字段；
- legacy 保存构造的 payload 保留当前 export；项目重新加载后仍能看到同样 branch；
- 未提供 export UI 不是丢弃 export 的理由。

### 基线保护

- 保留现有 `test/fixtures/baseline/csv/**`、默认 CSV 字节 golden、baseline IPC
  fixture，不自动更新。
- 新增 fixture 应放在 Phase 01 专用目录，并在 manifest 中说明来源、版本和预期
  迁移结果。
- 测试必须明确“迁移后的内存对象”和“明确保存后的落盘对象”两个时点，避免把
  打开项目误判为自动迁移写入。

## 实施顺序（仅供后续执行者）

1. 先完成分支/工作区/AGENT.md/临时路径门禁和 baseline 快照。
2. 先改 shared contracts 与 Node settings normalizer，再改 project-library 的
   fallback 入口；此时不改 UI。
3. 改 `electron/ipc-handlers.mjs` 的重复校验路径，补 Node migration tests，确认
   v1/v2/未知字段规则闭合。
4. 改 `lib/schema.mjs`/`lib/ai-client.mjs` 的 target 接线，补旧任务恢复和
   primary/audit 稳定性测试；不进入 crop 实现。
5. 改 modern/legacy 设置 fallback，补组件/静态契约测试。
6. 运行本阶段验收命令和完整 baseline；若任何字节、IPC、任务格式或真实数据边界
   发生变化，按停止条件记录并回滚本阶段改动。
7. 通过后才更新 `AGENT.md`、本阶段证据和 Phase 02 的输入说明；等待独立复核，
   不自动开始下一阶段。

## 验收命令与交付物

执行者完成代码后，至少应收集以下真实证据（本次不执行）：

```text
npm run check
npm run typecheck
npm run test:node
npm run test:modern
npm run validate:modern
git diff --check
```

交付物：

- `src/shared/contracts/index.ts` 的 v2/export/sourceEncoding/quality/target 类型
  和职责注释；
- `lib/project-settings.mjs` 的 v1→v2 幂等迁移、默认配置、未知字段保留和版本
  停止策略；
- project-library/IPC 单一归一化入口的调用点修正；
- modern/legacy 旧表单保留新 branch 的代码和测试；
- targetId 稳定性测试与旧任务派生证据；
- 临时库迁移、baseline CSV/IPC 不变和 `git diff --check` 证据；
- 更新后的 `AGENT.md` 方案记录和 Phase 01 完成报告，其中必须明确后续 CSV/OCR
  算法仍未在本阶段实现。

## 完成后的交接边界

Phase 01 只有在 v1 可读写、v2 写入稳定、未知字段不丢、source/output encoding
分离、targetId 不依赖识别字段且所有测试证据真实通过后，才可交给 Phase 02。
交接时必须保留独立回滚点；不得在本包内顺手实现 Phase 02–06，也不得在施工完成
后自行继续执行任何下一阶段动作。
