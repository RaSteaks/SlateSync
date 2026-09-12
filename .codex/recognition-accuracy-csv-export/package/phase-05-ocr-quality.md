# Phase 05：OCR 质量增强

## 目标

在不引入新 OCR 服务商的前提下，提高 Vision OCR 候选信息和输入图像质量。

## 子阶段 A：Vision alternatives

### 主要任务

- Swift Vision 从单候选读取最多 3 个候选。
- 增加 optional alternatives 输出字段。
- Node 归一化和 OCR evidence 支持 alternatives。
- 缓存 key 包含开关和输出版本，避免读取旧缓存。
- 全局设置增加 `VISIONOCR_ALTERNATIVES`。
- runner 构建和发布流程同步更新。

### 验收标准

- 开关关闭时保持旧输出结构。
- 开关开启时候选信息可被 Node 正确消费。
- 旧缓存不会被误认为包含 alternatives。
- Vision 失败时保留原有错误和回退行为。

## 子阶段 B：图像增强

先实现对比度/锐化，再单独实现 deskew。

### 主要任务

- 在共享图像预处理模块实现确定性增强。
- modern Worker 使用增强后的流程。
- legacy 处理限制在已有缩放尺寸内，避免主线程处理原始超大图。
- 增加处理耗时记录。
- 第一版使用隐藏开关或灰度开关，不立即强制全量启用。

### Deskew 特别要求

- 旋转后扩展画布，避免内容被裁切。
- 验证表格线不会导致错误倾斜角。
- 在真实扫描样本上与未增强结果对照。

## 重点文件

- `scripts/vision_ocr.swift`
- `lib/ocr/vision.mjs`
- `lib/ocr/paddleocr.mjs`
- `public/image-preprocess.js`
- `src/renderer/workers/preparation.worker.ts`
- `public/app.js`
- `electron/global-settings.mjs`

## 验收标准

- OCR 候选输出、缓存和 evidence 结构一致。
- 图像增强不会改变未触发增强条件的结果。
- legacy 大图处理没有明显界面阻塞。
- deskew 不造成内容裁切或明显识别回归。
- 增强失败时回退到原始图像。

---

## 施工包元数据与执行状态

> **施工包状态：READY FOR IMPLEMENTATION — DOCUMENT ONLY**
>
> 以下内容是 Phase 05 的详细施工包。本次只生成文档，不执行 Swift/Python runner、
> OCR、图像处理、构建、测试、Electron 或发布操作。

- 施工分支：feat/electron/accuracy-csv
- 上游门禁：Phase 02 的 evidence/quality 结构和 Phase 04 的配置/任务生命周期已
  稳定；Phase 03/04 不得因 OCR 增强重新定义 CSV 或导出配置。
- 本阶段目标：在不增加 OCR provider 的前提下，增大 Vision 候选证据的可用性，
  并以可取消、可回退、可测量的方式增加对比度/锐化/deskew 预处理。
- 下游交接：Phase 06 只能消费本阶段冻结的 OCR block/alternative/evidence 和
  preprocess metadata；Phase 07 依据开关隔离、缓存隔离、失败回退和性能证据放量。

## 施工目标与非目标

### 必须完成

1. Vision OCR 每个文字块在开关开启时最多提供 3 个候选；关闭时保持旧输出结构
   和旧 payload 形状。
2. Node 端、OCR evidence formatter、诊断/任务 snapshot 对 alternatives 采用
   可选字段，不误把旧缓存当成新格式。
3. 将 alternatives 开关纳入 global settings 的校验、展示、runner payload、缓存
   key 和 release build 版本。
4. 在共享图像预处理模块实现确定性 contrast/sharpen；触发条件、参数、版本和
   duration 可观察且失败可回退。
5. modern preparation Worker 和 legacy preparation 路径使用同一数学规则；legacy
   不在主线程处理超出既有缩放尺寸的原始超大图。
6. deskew 作为独立子阶段，旋转扩展画布，保留裁切前内容，并在真实扫描样本上
   与未 deskew 结果对照后才允许灰度启用。

### 明确不做

- 不引入新的 OCR 服务商、云端 OCR 或 Provider API。
- 不改变 OCR evidence “证据而非 ground truth”的语义，不在 Node 端自动选择
  alternative 覆盖模型识别结果。
- 不修改 Phase 02 的字段归一化、reviewRequiredFields 或 targetId。
- 不强制所有用户启用增强；初版保留关闭/隐藏/灰度开关和原图回退。
- 不在 Phase 05 实现 crop recheck 的目标选择或模型复核；那是 Phase 06。
- 不把诊断里的原始图像、API key 或完整外部 payload 记录进日志。

## 实施前门禁与允许路径

执行前必须确认分支、status、Phase 02/04 交接和当前 OCR fixture；本次不执行。

允许修改：

- scripts/vision_ocr.swift、scripts/build-vision-ocr.mjs
- lib/ocr/vision.mjs、lib/ocr/paddleocr.mjs 的共享结果归一化/summary 接线
- public/image-preprocess.js
- src/renderer/workers/preparation.worker.ts
- public/app.js 的 legacy preprocess/OCR setting 接线
- electron/global-settings.mjs
- src/shared/contracts/index.ts
- src/renderer/validation/global-settings-validation.ts
- modern/legacy OCR settings components and tests
- test/image-preprocess.test.mjs、test/vision-ocr.test.mjs、
  test/ocr.test.mjs、test/recognition-request.test.mjs 及新增 fixture

禁止扩大：

- OCR provider、SQLite schema、IPC channel、默认 Project Library、真实用户图片。
- release signing/notarization/publish credentials；只验证 build input/output 契约。

## 当前代码基线与不变量

| 区域 | 当前观察 | 施工要求 |
| --- | --- | --- |
| Swift Vision | OcrRequest 没有 alternatives 数量，recognizeView 使用 topCandidates(1)，Block 只有 text/confidence/bbox。 | 增加可选候选数和 optional alternatives；primary text/confidence/bbox 语义保持。 |
| Node Vision | visionOcrPublicConfig 有 enabled/level/confidence/maxBlocks；cache key 由 image/settings 生成，cache limit 为 8。 | alternatives count 和 output schema version 必须进入 status、payload、cache key、normalize。 |
| OCR evidence | formatOcrEvidence 输出 block order/q/box/text，供 primary/core prompt 使用。 | 只在 alternatives 存在时追加稳定且有上限的候选文本，不改变 primary evidence 行解析。 |
| global settings | electron/global-settings.mjs 使用显式 key、range/enum/default；legacy 与 modern 有自己的表单配置。 | VISIONOCR_ALTERNATIVES 在 Main、contracts、验证和两套 UI 同步。 |
| preparation | image-preprocess.js 负责 dense row crop、detail segments、core width；preparation.worker 负责 rasterize/recompress/encode。 | contrast/sharpen/deskew 接在 rasterize 后、视图 encode 前，失败返回原始视图。 |
| legacy | public/app.js 通过已有 preparation/OCR 设置和缩放流程工作。 | 增强仍限制在既有最大尺寸和 Worker/async 边界，不能让原图进入主线程重处理。 |

## 子阶段 A：Vision alternatives

### 输出契约

在 shared contract 中定义可选类型，职责等价于：

~~~text
OcrAlternative {
  text: string
  confidence: number
}

OcrBlock {
  order, text, confidence, bbox, bboxNormalized
  alternatives?: readonly OcrAlternative[]
}
~~~

约束：

- alternatives 只描述同一 Vision observation 的候选文本，复用 primary block 的
  bbox，不伪造候选坐标。
- primary 仍是 candidates[0]，字段顺序/置信度/过滤阈值保持旧语义。
- alternatives 排除与 primary 相同的 text，去重后最多保留配置数量减一；confidence
  clamp 到 0–1，文本 trim 后为空则丢弃。
- 开关为 0 时完全省略 alternatives 字段，不返回空数组；这样关闭时旧结构仍
  可逐字比较。
- alternatives 不是 RecognitionRecord 字段，不直接写入 scene/shot/take，也不
  自动覆盖模型结果；只通过 OCR evidence/diagnostic 提供给后续阶段。

### Swift 实施

修改 scripts/vision_ocr.swift：

1. OcrRequest 增加可选 alternativesCount，缺省为 0，clamp 到 0–3。
2. recognizeView 使用 topCandidates(max(1, alternativesCount + 1))。
3. 第一个 candidate 继续生成 primary Block；后续候选按上述去重/清洗规则进入
   optional alternatives。
4. 当 alternativesCount=0 时编码结果不出现 alternatives key。
5. request/response invalid input、minimumConfidence、maxBlocksPerView、progress
   和 exit code 保持旧行为。
6. 使用固定 output schema version，例如 vision-ocr-v2-alt；version 只标记输出
   契约，不改变 modelVersion 的用户显示含义。

### Node 归一化与 evidence

修改 lib/ocr/vision.mjs：

- visionOcrPublicConfig 读取 alternatives count，返回 numeric config 和 output
  schema version。
- payload 传入 alternativesCount；旧 custom execute 如果忽略未知字段仍可运行。
- normalizeOcrResult 验证 alternatives shape；非法候选丢弃并保留 primary，不让一
  个坏候选使整页失败。
- formatOcrEvidence 对每个 block 增加有限长度的 alternatives 行，例如
  alt=[text:q,...]；总 evidence 字符上限仍由 maxCharacters 控制。
- summarizeOcrResult 增加 alternativesEnabled、alternativeCount 或等价统计，
  保持旧 summary 字段。
- 诊断/任务 snapshot 只保存可选、可序列化的结果；旧 snapshot 读取时没有
  alternatives 即视为关闭。

### cache 隔离

cache key 必须包含：

- output schema version；
- alternatives count；
- language、recognition level、language correction；
- minimum confidence、max blocks；
- image data digest；
- 必要的 preprocess version/setting。

关闭 alternatives 后不能命中开启 alternatives 的缓存；旧 key 即使相同图片也
不能被误认为含候选。迁移策略为自然 cache miss，不删除用户任务、不读取旧结构。

### 设置与发布

推荐将 VISIONOCR_ALTERNATIVES 定义为整数 0–3：

- 0：关闭，默认；
- 1–3：每个 primary block 最多保留相应数量的备用候选。

同步修改：

- electron/global-settings.mjs 的 INTEGER_RANGES、DEFAULT_VALUES 和 key allowlist；
- src/shared/contracts/index.ts 的 GlobalSettingKey/公开配置类型；
- src/renderer/validation/global-settings-validation.ts；
- public/app.js 与 modern GlobalSettingsPage 的表单 schema、帮助文字和保存；
- scripts/build-vision-ocr.mjs 的 source/build version 检查；
- release 资源清单和 check 只验证源码/编译产物契约，不自动发布。

## 子阶段 B：对比度与锐化

### 共享图像预处理 API

在 public/image-preprocess.js 增加浏览器安全且可单测的函数，职责等价于：

~~~js
analyzeImageQuality(imageData, options)
enhanceImageData(imageData, options)
preprocessImageForRecognition(source, options)
~~~

规则：

- 输入输出尺寸、坐标系和页面顺序不变。
- quality 分析使用固定下采样/亮度规则；不依赖平台字体、时区或随机数。
- contrast 使用明确的线性/局部增强公式并 clamp 到合法像素范围；sharpen 使用
  固定 kernel 或 unsharp 参数，并明确 alpha/白底处理。
- default/off、质量已经足够或分析失败时返回原始图像；标记 applied=false。
- 输出携带 preprocessVersion、operations、sourceWidth/sourceHeight、durationMs、
  fallbackReason 等 metadata，但不把 metadata 混进 data URL。
- 增强只作用于 OCR/模型输入，用户预览和原始任务 imageDataGroups 保留原图。

### 触发条件与可测参数

初版参数必须集中在 shared defaults：

- darkThreshold、contrast score threshold；
- contrast gain/black-white clamp；
- sharpen radius/amount；
- max dimension；
- preprocess version。

参数边界和开关通过 Main/Worker payload 传递，不允许 modern/legacy 各自写常量。
建议默认关闭增强，仅在隐藏/灰度开关和测试环境启用，直到真实扫描样本确认：

- 低对比度文字可见度改善；
- 表格线没有被锐化成更多伪字符；
- 已清晰图像 pixel/output/recognition 输入保持不变。

### Worker 接线

修改 preparation.worker.ts：

1. rasterizeImage/rasterizePdf 得到白底 canvas 后执行 shared enhancement。
2. 再执行既有 dense row crop、detail segment、core column composite 或按固定
   方案先 crop 后 enhance；顺序必须由 fixture 固定，并确保坐标可追溯。
3. 每页返回 optional preprocess metadata 和 duration；原有 result fields 保持兼容。
4. 任何增强异常、内存不足、canvas convert 失败均回退当前页原始 canvas，并
   发送可读 warning；不能丢整份任务。
5. 处理期间尊重取消/页面边界，不能让异常 promise 卡住 Worker。

legacy 侧沿用已有最大尺寸/recompress 路径；原始超大图不在主线程执行新的全
分辨率滤镜。若 legacy 无法安全执行某操作，返回 applied=false 并使用旧输入。

## 子阶段 C：deskew（独立发布门）

deskew 不与 contrast/sharpen 同一提交强制启用：

- 候选角度只从固定范围和固定步长估计；使用表格线/文字行的稳健统计，不能只
  用一条边缘线。
- 估计置信度不足时不旋转。
- 旋转后 canvas 尺寸扩展到完整 bounding box，四角用白色填充；不能裁切任何
  原始内容。
- 记录 angle、confidence、source size、output size 和 fallbackReason。
- 用包含倾斜表格线、页边阴影、空白页和多表格 band 的真实样本对照。
- deskew 失败、角度超限、输出尺寸异常时返回原图；不要把失败转换成 OCR 空结果。

## 测试与验证矩阵

### alternatives

- 开关 0 的 Swift/Node 输出结构与旧 fixture 深相等。
- 开关 1/2/3 最多返回相应数量，primary 永远不变，候选按置信度/原顺序稳定。
- 坏候选、重复候选、低于阈值候选不破坏 primary。
- formatOcrEvidence 在字符上限内保留 primary 和有限 alternatives。
- 开启/关闭/版本不同的 cache key 不相等；旧缓存自然 miss。
- Vision failure、timeout、cancel、required/optional fallback 与旧行为一致。

### image preprocess

- 白底/清晰图像 default/off 是严格 no-op。
- 低对比度 fixture 在启用 contrast 后 metadata/applied 正确且输出尺寸不变。
- 细字 fixture sharpen 后不越界、不改变 alpha 约定。
- canvas、PDF、JPEG/PNG/WebP 路径结果结构一致。
- 异常时回退原图并记录 warning；取消不会留下半成品。
- deskew 角度/扩展画布/无裁切通过像素和人工样本对照。
- modern Worker 与 legacy 受限路径参数一致；legacy 不阻塞原图处理。

### 可观测性

- ocrSummary 记录 alternatives/preprocess 开关、version、duration、fallback。
- 日志只记录计数、耗时、错误 code 和版本，不记录图片内容或密钥。

推荐命令在施工阶段执行：

~~~sh
npm run check
npm run typecheck
npm run test:node
npm run test:modern
npm run validate:modern
git diff --check
~~~

真实 Swift binary、真实扫描样本和 release build 只能在明确的手工验收门中执行，
不能用 mock 结果冒充真实能力。

## 停止条件、回滚与交接

必须停止：

- alternatives=0 改变旧 JSON 结构或旧 cache 被误命中；
- 候选被误当作最终识别值，或原始 evidence/图像被覆盖；
- 图像增强改变未触发条件的输入，或增强失败导致任务丢页；
- deskew 发生裁切、角度不稳定或表格线明显增加误识别；
- legacy 主线程处理原始超大图造成明显阻塞；
- 新增设置无法通过 Main/modern/legacy 的同一校验；
- 需要 provider、IPC、数据库或发布签名授权之外的改动。

回滚按子阶段独立进行：先关闭 alternatives，再关闭 contrast/sharpen，再关闭
deskew；保留输出 schema 和旧缓存兼容，不删除任务数据。

交给 Phase 06 时必须提供：

- alternatives optional contract、output/cache version 和 evidence 规则；
- image preprocessing input/output metadata、coordinates、fallback 规则；
- OCR/图像操作可取消、可超时、可回退；
- baseline 与真实样本对照结果；
- 明确所有新开关的默认值和当前关闭状态。
