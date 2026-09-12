# Phase 03：CSV 后端与导出模型

## 目标

构建统一、可配置且向后兼容的 CSV 导出后端，使预览和最终导出共享同一套逻辑。

## 核心原则

```text
decode source
  → build semantic table
  → apply export options
  → encode output
```

显示表头不能作为字段语义的唯一来源。

## 主要任务

### 1. 编码处理

- `decodeResolveCsv` 支持 UTF-8、UTF-16LE、UTF-16BE。
- UTF-8 严格解码失败后尝试 GBK/GB18030。
- 记录 `sourceEncoding`。
- 输出只允许 UTF-8、UTF-16LE、UTF-16BE。
- 错误信息明确区分源文件编码和导出编码。

### 2. 语义列模型

支持以下 standalone 列：

- `scene`
- `shot`
- `take`
- `comments`
- `takeStatus`
- `cardNumber`
- `videoCode`
- `sourcePage`

默认启用前四列；表格内部保存字段 key、显示表头和启用状态。

### 3. 统一导出构建函数

实现单一的 CSV 表构建入口，供以下路径共用：

- modern 预览
- modern 最终导出
- legacy 预览
- legacy 最终导出
- Resolve CSV 回填
- standalone CSV

### 4. Worker 传输

扩展 CSV Worker 任务 payload，传递：

- `ExportOptions`
- `sourceEncoding`
- 语义列定义
- 当前编辑值
- 文件名模板解析结果

保持现有 Worker 协议兼容，新增字段使用可选属性。

## 重点文件

- `public/resolve-csv.js`
- `public/csv-background-tasks.js`
- `public/csv-worker.js`
- `public/csv-worker-client.js`
- `src/renderer/services/csv-worker-service.ts`
- `src/renderer/state/export-store.ts`

## 验收标准

- 无选项导出与旧版本逐字节一致。
- GBK/GB18030 输入可正确转换为支持的输出编码。
- 自定义表头在任务恢复后仍能映射到正确字段。
- 预览表格和最终文件内容一致。
- Worker 失败时可以返回明确错误且不破坏原数据。

---

## 施工包元数据与执行状态

> **施工包状态：READY FOR IMPLEMENTATION — DOCUMENT ONLY**
>
> 以下是 Phase 03 的详细施工包，不是已完成的施工结果。本次只生成施工包，
> 不执行源码修改、测试、构建、Worker、Electron、真实 CSV、真实 Project Library
> 或 Git 操作。

- 施工分支：feat/electron/accuracy-csv
- 上游门禁：Phase 01 的 ExportOptions、ResolveCsvSourceEncoding 和任务兼容性已完成；
  Phase 02 的 canonical field value、quality、reviewRequiredFields 已完成并交接。
- 本阶段目标：建立唯一的语义表构建、源文件解码、输出编码和 Worker 任务入口，
  让 modern/legacy 预览与最终下载使用完全相同的构建结果。
- 下游交接：Phase 04 只负责界面和配置优先级，不再实现 CSV 规则；Phase 07
  依赖本阶段的 baseline byte、worker parity 和失败回退证据。

## 施工目标与非目标

### 必须完成

1. 支持 UTF-8、UTF-16LE、UTF-16BE，并在严格 Unicode 解码失败时尝试 GBK/
   GB18030；以 sourceEncoding 记录输入事实。
2. 让 format.encoding 只表示最终输出编码，输出仍只允许 UTF-8、UTF-16LE、
   UTF-16BE。
3. 以 ExportColumnKey 为唯一字段身份，构建 standalone 和 Resolve merge 两类
   semantic table；显示表头只负责展示和写文件。
4. 将当前识别记录、CSV source row、CSV sparse edits、field formats、comments
   和 ExportOptions 汇聚到同一个纯构建入口。
5. 扩展 CSV Worker payload，同时接受旧任务 payload；Worker 错误不得清空已加载
   table、编辑值或当前任务。
6. 保证预览 table 与最终 encode 使用相同的 semantic table 和相同的 options。

### 明确不做

- 不在本阶段添加导出选项 UI、项目设置编辑控件或 filename template 输入控件；
  这些属于 Phase 04。
- 不重新实现 Phase 02 的中文数字、混淆字符和字段 quality 算法。
- 不改变 Resolve 现有 source row 的非目标列、素材身份、sourceEncoding 或任务
  快照的兼容形状。
- 不新增 IPC channel、数据库列、Provider 请求或 OCR 行为。
- 不因为启用新语义列而删除 source CSV 中已有列；无选项导出必须保留旧字节行为。
- 不把 GBK/GB18030 塞进最终输出 format.encoding。

## 实施前门禁与保护范围

施工执行者必须先完成以下只读检查；本次只编制文档，不执行：

1. 确认分支为 feat/electron/accuracy-csv，并记录 git status --short。
2. 记录 Phase 01/02 的工作区 diff，保护 Owner 已有改动。
3. 固定 test/fixtures/baseline/csv 下全部 fixture 的原始 bytes 和当前 round-trip
   结果；任何为了通过新逻辑而改写现有 golden 的情况都要停止。
4. 任务持久化、Worker 和编码测试全部使用内存/临时文件，禁止访问默认
   Project Library 和真实用户 CSV。
5. 确认当前 Worker protocol version、renderer fallback 和 modern service 的现有
   失败语义；新增字段必须是可选或在协议版本中有明确兼容分支。
6. 施工完成后才更新 AGENT.md；本次不改 AGENT.md。

允许触及：

- public/resolve-csv.js
- public/csv-background-tasks.js
- public/csv-worker.js
- public/csv-worker-client.js
- src/renderer/services/csv-worker-service.ts
- src/renderer/state/export-store.ts
- src/shared/contracts/index.ts 的 CSV/ExportOptions 类型
- public/task-persistence.js 与对应测试（仅为可选 export snapshot 字段）
- test/baseline-csv.test.mjs、test/resolve-csv.test.mjs、
  test/csv-background-tasks.test.mjs、test/csv-worker-client.test.mjs、
  test/task-persistence.test.mjs 和新增 fixture

禁止扩大：

- electron/IPC、SQLite schema、Project Library 默认路径、真实网络和 release 资源。
- modern/legacy UI 的业务交互；UI 只消费本阶段冻结的 builder 和 Worker contract。

## 当前基线事实

| 位置 | 当前观察 | 施工影响 |
| --- | --- | --- |
| public/resolve-csv.js | decodeResolveCsv 依据 BOM/零字节检测 UTF 编码，失败后直接报错；返回的 sourceEncoding 目前与 detected format 绑定。 | 增加严格 UTF-8 → GBK/GB18030 fallback，并保持 format.encoding 为输出语义。 |
| public/resolve-csv.js | buildStandaloneResolveTable、mergeSlateIntoResolveTable、encodeResolveCsv 各自参与字段格式化。 | 抽出唯一 semantic builder；旧导出函数只保留兼容包装。 |
| public/csv-background-tasks.js | Worker 保存 metadataTable，已有 decode/prime/merge/export 任务；export 只接收 fieldFormats、comments 和 edits。 | 增加可选 exportOptions、resolvedFilename/sourceEncoding/semantic columns，不破坏旧 payload。 |
| csv Worker client/service | public client 与 modern CsvWorkerService 都有独立请求边界，现代 protocol marker 为 1。 | 任务类型增加字段；保留 Worker 错误命名和重建行为。 |
| WorkspacePage | 当前 modern export 只使用 settings.resolve.fieldFormats/comments，文件名由页面临时拼接。 | 本阶段只提供 backend 接口，Phase 04 再接 effective options 和 UI。 |
| contracts | ExportColumnKey、ExportOptions、ResolveCsvSourceEncoding、ResolveCsvTable 已由 Phase 01 定义。 | 不通过 header 字符串扩大语义；类型变更必须保持旧 snapshot 可读。 |

## 语义模型与不变量

### SemanticColumn

每个导出列在内存中必须由以下信息描述：

~~~text
key: ExportColumnKey
header: string
enabled: boolean
value source: record / source row / derived status
~~~

固定合法顺序：

1. scene
2. shot
3. take
4. comments
5. takeStatus
6. cardNumber
7. videoCode
8. sourcePage

规则：

- 同一个 key 只能出现一次；非法、空白、含换行或控制字符的 header 走共享
  ExportOptions 归一化。
- standalone table 严格按 enabled columns 输出；默认仍为 Scene、Shot、Take、
  Comments 四列，顺序和旧版本一致。
- Resolve merge table 默认保留 source CSV 的全部列和顺序；仅在既有逻辑需要
  的目标字段不存在时追加。关闭的可选语义列不能新建，但 source 中本来已有的
  列不能删除，以保护无参数 round-trip。
- key 决定匹配、编辑、恢复和取值；header 只决定展示/导出文字。
- takeStatus 是业务状态值；comments 是按 comments 配置生成的 Resolve marker。
  两者不是同义字段，不能通过 header 相互推断。

### 统一 builder 入口

实现一个唯一的纯构建入口，职责等价于：

~~~js
buildSemanticExportTable({
  mode: "standalone" | "resolve",
  sourceTable,
  records,
  csvEdits,
  options,
  fieldFormats,
  comments,
  resolvedFilename,
})
~~~

返回值至少包括：

~~~text
table: { headers, rows, format, sourceEncoding? }
semanticColumns
changes
warnings
statuses
matchedRecordCount
exportableCount
resolvedFilename
~~~

实现要求：

1. 输入对象全部按不可变方式读取；sourceTable、records、edits 不得被修改。
2. builder 只负责语义表和值，不负责打开保存对话框、不负责写入任务、不负责
   修改 UI store。
3. standalone 和 resolve 分支共享字段取值、format、comments 和 warning helper；
   仅 source row 合并策略不同。
4. encodeResolveCsv 只接受 builder 产生的 table，或对旧 table 做兼容归一化；
   不能在 preview 与 export 之间再执行另一套字段变换。
5. 对同一输入调用两次必须深相等；对已 canonical value 再调用不得生成重复
   changes/warnings。

## 编码处理施工设计

### 检测优先级

固定以下顺序：

1. UTF-16LE BOM、UTF-16BE BOM、UTF-8 BOM。
2. 无 BOM 时按现有零字节密度识别 UTF-16LE/BE，并用 fatal decoder 验证。
3. 尝试 UTF-8 fatal 解码；成功则 sourceEncoding=utf-8。
4. UTF-8 失败后尝试 GBK 与 GB18030 的 fatal 解码。
5. 两者都失败时返回源文件解码错误；不得退回 replacement character。

GBK 与 GB18030 对多数中文文件不可从字节完全区分。实现必须使用确定的检测
策略并记录来源，例如：

- 能被 GBK 严格解码时优先标记 gbk；
- 只有 GB18030 能解码时标记 gb18030；
- 若应用提供显式 source encoding override，则 override 优先并在结果中标记
  detection=explicit；
- 不要把“能够解码”误写成来源绝对确定；可选增加 sourceEncodingDetection
  字段供诊断，但不能改变既有 ResolveCsvTable 必需字段。

### decodeResolveCsv

- 成功结果：sourceEncoding 保存输入编码；format.encoding 设置默认输出编码
  或已有兼容输出设置，不再将 gbk/gb18030 写入最终输出类型。
- 解码失败错误必须区分：
  - source decode：源 CSV 不是支持的输入编码、字节截断或内容损坏；
  - output encode：目标输出编码不支持、表格值无法编码或配置非法。
- 解析表头、delimiter、line ending、final newline 的行为沿用当前逻辑。
- 读取到的 source table 只在内存中加 sourceEncoding；恢复旧 snapshot 时若没有
  sourceEncoding，使用旧 format.encoding 作为兼容 fallback，不自动改写快照。

### encodeResolveCsv

- 最终输出 encoding 只允许 utf-8、utf-16le、utf-16be。
- BOM、delimiter、line ending、final newline 完全由 options/table.format 决定；
  defaults 必须与现有无选项导出一致。
- GBK/GB18030 只作为输入解码事实；不能被选择为输出编码。
- 编码失败时保留原 table 和编辑状态，抛出带稳定 name/code 的输出错误。

## Worker 协议与失败回退

### 可选 payload 字段

保留现有任务 type 和 protocol marker，新增字段使用可选属性：

- exportOptions
- sourceEncoding
- semanticColumns
- resolvedFilename
- filenameContext 或已经解析好的 filename
- outputFormat

旧 payload 没有 exportOptions 时，Worker 必须按 DEFAULT_EXPORT_OPTIONS 和旧
fieldFormats/comments 执行；旧任务不能因为缺少新字段而失败。

### 任务行为

- decode-metadata 返回 sourceEncoding；prime-metadata 给旧 table 补 sourceEncoding
  只发生在 Worker 内存副本。
- merge-preview 与 export-resolve 必须调用同一个 builder；preview 只返回 table，
  export 由同一 table 进入 encode。
- export-standalone 同样调用 builder，不能保留另一套 standalone 拼行逻辑。
- Worker 每个请求保留 request id；过期回复不得覆盖当前 store。
- Worker 失败时，CsvWorkerService 只清理 Worker 和 pending request；当前
  export-store.table、previewTable、edits、source file name 不得被清空。
- renderer fallback 只在现有允许的基础上重跑同一 builder；不应 silently 改变
  输出列或编码。
- Worker 内存中的大 source table 不通过 React 状态重复复制；只回传必要的
  preview table/bytes。

## 测试与施工顺序

### 推荐顺序

1. 冻结 baseline CSV bytes、format 和当前 round-trip 结果。
2. 增加 source encoding decoder/fatal error helper。
3. 增加 semantic column normalizer 与 unified builder。
4. 让旧 resolve-csv 函数委托 builder，保持导出 API。
5. 扩展 Worker task union、processor、client/service，覆盖旧 payload。
6. 接入 task snapshot 的可选 sourceEncoding/export metadata。
7. 增加 failure/worker recreation/renderer fallback 测试。
8. 交给 Phase 04 接 UI；本阶段不添加 UI 控件。

### 必测 fixture

- UTF-8 with/without BOM。
- UTF-16LE/BE with/without BOM。
- 简体中文 GBK。
- 含 GB18030 四字节字符的 CSV。
- 截断字节、非法 UTF-8、无法按 GBK/GB18030 解码的字节。
- 自定义 header、重复 header、空 header、未知语义列。
- 默认四列 standalone、全部八列、只启用可选列、空 records。
- Resolve source table 已有目标列、缺少目标列、额外非目标列、重复 Camera #。
- sparse edits 清空单元格、编辑未知列、越界 row/column。

### 验收断言

- 无选项导出逐字节等于 baseline。
- preview table encode 后的 headers/rows/format 与最终 export 完全一致。
- GBK/GB18030 输入可转为三个允许的输出编码，中文不出现 replacement character。
- sourceEncoding 与 format.encoding 永远分离。
- 自定义 header 恢复后 key 映射不变，改变显示文字不改变字段语义。
- Worker 报错时旧 table、edits 和任务快照保持不变。
- Node direct、public Worker、modern CsvWorkerService 的结果深相等。

推荐命令在施工阶段执行：

~~~sh
npm run check
npm run typecheck
npm run test:node
npm run test:modern
npm run validate:modern
git diff --check
~~~

## 停止条件、回滚边界与交接

出现以下任一情况必须停止：

- baseline CSV 字节变化且无法证明来自明确的新选项；
- GBK/GB18030 被写入 format.encoding 或输出错误与输入错误混淆；
- preview/export 使用不同 builder，或 Worker/fallback 结果不一致；
- 自定义表头被当作字段身份，导致恢复/匹配错列；
- Worker 失败清空用户数据、旧 payload 无法读取或过期回复覆盖当前任务；
- 需要新增 IPC、数据库迁移或访问真实 Project Library。

回滚只允许撤销 Phase 03 的源码、fixture 和测试改动，不得 reset/checkout 清理
Owner 的其他改动。

交给 Phase 04 的接口：

- buildSemanticExportTable 是 preview/export 的唯一数据入口；
- ExportOptions、sourceEncoding、resolvedFilename 的 Worker payload 已冻结；
- 旧任务和旧 Worker payload 可继续读取；
- default export bytes、semantic key 映射和失败回退均有证据；
- Phase 04 不得在 Renderer 中重新拼 CSV。
