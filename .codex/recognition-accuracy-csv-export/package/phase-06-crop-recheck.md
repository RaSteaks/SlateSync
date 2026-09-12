# Phase 06：high accuracy crop recheck

## 目标

仅对 high accuracy 模式下的低置信度数字字段进行受控复核，提升关键字段召回率，同时限制额外成本和延迟。

## 触发条件

满足以下条件时才进入复核：

- accuracyMode 为 high
- 字段置信度低于阈值，或字段已被标记需要复核
- 目标数量未超过配置上限
- 当前任务未被取消

## 复核上下文

每个目标必须带有：

- 稳定 `targetId`
- 原始 core 图片
- 数字字段裁剪图
- 字段名称
- crop 坐标和来源页码

不能只发送孤立裁剪图，也不能通过卡号或视频号反推目标记录。

## 主要任务

- 在 Swift 和 Python OCR runner 中增加 crop 任务能力。
- 同时支持持久 Worker 和 one-shot fallback。
- 选择低置信度数字块并去重。
- 批量发送复核请求，限制调用次数和并发。
- 增加超时、取消和 provider 错误回退。
- 只更新空字段或已标记复核的字段。
- 已确认字段不得被 crop 结果覆盖。
- 增加 `SLATESYNC_CROP_RECHECK` 和 `SLATESYNC_CROP_RECHECK_MAX_TARGETS` 校验。

## 首次发布策略

- `SLATESYNC_CROP_RECHECK=false`
- `SLATESYNC_CROP_RECHECK_MAX_TARGETS=12`
- 完成样本准确率、耗时和费用评估后，再考虑默认开启。

## 重点文件

- `lib/ai-client.mjs`
- `lib/ocr/vision.mjs`
- `lib/ocr/paddleocr.mjs`
- `scripts/vision_ocr.swift`
- `scripts/paddleocr_runner.py`
- `electron/global-settings.mjs`
- `src/shared/contracts/index.ts`

## 验收标准

- 没有候选目标时不产生额外调用。
- 超出上限时只处理允许数量。
- 复核请求超时、取消或失败时原结果保持不变。
- 复核结果能正确回填对应 target。
- 已确认字段不会被覆盖。
- high accuracy 总体延迟和调用次数在设定预算内。

---

## 施工包元数据与执行状态

> **施工包状态：READY FOR IMPLEMENTATION — DOCUMENT ONLY**
>
> 以下是 Phase 06 的详细施工包。本次只生成文档，不执行 OCR runner、模型请求、
> 图像裁剪、测试、构建、真实凭据或 Electron 操作。

- 施工分支：feat/electron/accuracy-csv
- 上游门禁：Phase 01 已冻结 targetId；Phase 02 已冻结 quality/review；
  Phase 05 已冻结 OCR block/alternative/evidence 和图像预处理输出契约。
- 本阶段目标：只在 high accuracy 且明确开启时，针对低置信度/待复核数字字段
  生成有限 crop recheck 请求，并把结果安全回填到同一个稳定 target。
- 首发策略：SLATESYNC_CROP_RECHECK=false；SLATESYNC_CROP_RECHECK_MAX_TARGETS=12。
  本阶段完成并不等于默认开启。

## 施工目标与非目标

### 必须完成

1. 定义稳定的 CropRecheckTarget/Result contract，目标定位使用 targetId + field，
   不使用卡号、视频码或可编辑文本。
2. 仅在 high accuracy、低字段置信度或 reviewRequired、目标数未超限且任务未取消
   时触发。
3. 从带坐标的 OCR block/核心视图中确定性选择候选并去重；没有可靠坐标时不猜
   crop，不产生额外调用。
4. Swift Vision 和 Python PaddleOCR 支持 crop task；持久 Worker 不可用时提供
   one-shot fallback，且两条路径返回相同 canonical 结果。
5. 批量请求限制 target 数、批量大小、并发、deadline、取消和 provider 错误；
   失败只保留原结果并给出诊断。
6. 回填前检查 targetId、sourcePage、field、原始字段快照和 eligibility；只更新
   空字段或已经被标记 review 的字段，已确认字段拒绝覆盖。
7. crop 回填仍走 Phase 02 共享字段归一化和 quality，不直接写未校验的模型文本。

### 明确不做

- 不对 standard accuracy 触发 crop recheck。
- 不在没有 bbox、sourcePage 或 targetId 的记录上猜测目标。
- 不根据 cardNumber/videoCode 重新定位记录，不因为 crop 结果改变 targetId 或排序。
- 不覆盖非空且未标记 review 的字段，不覆盖用户已确认的字段。
- 不把 crop 结果当成无审计的高置信度；成功回填仍保留自动复核 provenance。
- 不在本阶段把开关默认改为 true，不改 ProjectSettings export、CSV backend 或 OCR
  provider 选择优先级。
- 不新增数据库列；可选的 task diagnostics 必须兼容旧 snapshot。

## 实施前门禁与允许路径

执行前必须确认 Phase 05 alternatives/preprocess 已通过 Node/modern/runner 契约
测试，记录当前 branch/status 和上游 diff；本次只编制文档。

允许修改：

- lib/ai-client.mjs
- lib/ocr/vision.mjs、lib/ocr/paddleocr.mjs、lib/ocr/cancellation.mjs
- scripts/vision_ocr.swift、scripts/paddleocr_runner.py
- electron/global-settings.mjs
- src/shared/contracts/index.ts
- 必要的 runner/worker test、ai-client test、target/persistence fixture
- 如需展示进度，只允许复用现有 recognition progress envelope

禁止扩大：

- 数据库 schema、IPC channel、默认 Project Library、用户任务迁移。
- crop 目标的永久外部存储和包含原图的日志。
- Phase 05 之外的图像增强或 Phase 04 导出 UI。

## 当前代码基线与设计约束

| 区域 | 当前观察 | Phase 06 要求 |
| --- | --- | --- |
| ai-client | high 模式当前执行 primary + audit，冲突/查漏再执行 review，最终 merge 后格式化结果；selectCoreImages 只按 page images 选择核心视图。 | 在最终记录可用后增加受控 crop stage；不改变现有 primary/audit/review 语义和 targetId。 |
| targetId | mergePageResults 已按 page number + final record index 生成 page:*:record:*；manual/slate CSV 使用 manual namespace。 | 只有 page namespace、sourcePage 有效且来自 OCR 图像的记录可进入候选；manual targets 永不进入。 |
| OCR evidence | page.views/views.blocks 含 viewIndex、viewType、bboxNormalized、confidence、text；尚无 field-specific crop target。 | 生成显式 target candidate，保存 source view/box；无映射时安全跳过。 |
| OCR runner | Vision/Paddle 已有持久/one-shot、timeout、cancel、cache/worker 机制。 | 新增 crop task 与同样的 generation/cancel/timeout/fallback 语义。 |
| quality | reviewRequiredFields/quality.fields 已能标记 scene/shot/take/card/video；人工可编辑。 | eligibility 使用现有标记，并在回填前再次验证 snapshot，避免 stale response 覆盖。 |

## 共享契约设计

### CropRecheckTarget

在 src/shared/contracts/index.ts 定义可序列化、可限长的结构，职责等价于：

~~~text
targetId
sourcePage
recordIndex
field
currentValue
originalValue
fieldConfidence
reviewReason
coreImage
cropImage
cropBoundsNormalized: [left, top, right, bottom]
sourceViewIndex
sourceViewType
ocrBlockOrder
ocrBlockConfidence
~~~

规则：

- field 只允许 cardNumber、videoCode、scene、shot、take；禁止 description/comments
  等非数字字段进入 crop budget。
- coreImage 是同一来源页的原始核心视图，cropImage 是从该视图坐标裁出的局部；
  两者都要随 target 发送，不能只给孤立 crop。
- bbox 必须满足 0 <= left < right <= 1、0 <= top < bottom <= 1；面积过小、
  超出边界或缺失时拒绝 target。
- originalValue/currentValue 是选择时的快照，用于 stale result guard；不要把
  OCR block text 当作 originalValue。
- targetId、sourcePage、field 和记录索引必须在 batch 内唯一组合；重复候选只保留
  稳定排序后的第一条或置信度最高的一条，选择规则要写入测试。

### CropRecheckResult

每个 target 必须返回一条状态，不以数组缺失表示失败：

~~~text
{
  targetId,
  field,
  status: "confirmed" | "uncertain" | "not-found" | "failed",
  value: string | null,
  confidence: "high" | "medium" | "low" | null,
  warningCode: string | null,
  durationMs
}
~~~

非法 targetId/field、未知状态、过长文本、非法 value 必须丢弃为 failed 并记录
诊断；不能按返回数组位置回填。

## 目标选择算法

### 触发闸门

固定顺序：

1. accuracyMode 必须为 high；
2. SLATESYNC_CROP_RECHECK 必须显式解析为 true；
3. signal 未取消；
4. page/record/field 满足稳定 target 和数字字段 allowlist；
5. record confidence 为 low，或 field 在 reviewRequiredFields 中，或 quality
   warning 明确属于数字/混淆/范围问题；
6. 有有效 OCR block 坐标和对应 core image；
7. 通过 max targets；
8. 再按 batch/concurrency 分组发送。

standard、关闭开关、无候选、maxTargets=0 都必须在 provider/runner 调用前返回
“无目标”结果，并且调用计数为 0。

### field 与 OCR block 的映射

当前 OCR block 不天然携带字段名，因此不能仅凭 block 顺序猜测。实现必须提供
一个显式 mapper，按以下优先级确定：

1. 现有 page/core view layout 元数据明确标记的数字列区域；
2. 同一 block 的 text 经 Phase 02 parser 后与 record.currentValue 或
   originalValue 的 canonical value 相符，且列区域唯一；
3. 记录本身只有一个待复核数字字段，且 block 位于该字段的有效列区域；
4. 以上都不满足则不生成 target。

mapper 输出 field、viewIndex、bbox、reason 和 score。多个 block 命中同一
targetId+field 时按 score 降序、ocrBlockOrder 升序、viewIndex 升序去重。
不能用“第一个低置信度 block”作为默认字段。

### 稳定顺序和上限

- 先按 sourcePage 升序，再按 final recordIndex 升序，再按固定 field order
  cardNumber、videoCode、scene、shot、take。
- maxTargets 在去重之后计算，默认 12；超过上限只处理前 N 个并在 summary/warning
  中报告 skipped count。
- 建议 batch size=4、最大并发=2；若复用 MODEL_PAGE_CONCURRENCY，必须受
  maxTargets 和单次 deadline 双重限制。
- 记录 selectedCount、deduplicatedCount、skippedCount、batchCount、providerCallCount。

## crop 图像和 runner 任务

### crop 生成

使用 source view 的 normalized bbox 生成 crop：

- 先按 source view 实际宽高换算像素；
- 加固定 padding ratio，但 clamp 到图像边界；
- 最小输出尺寸和最大尺寸固定，不能对小字段无界放大；
- 保留原始 core image，不覆盖 imageDataGroups；
- 输出 crop data URL 的 MIME/质量规则与 Phase 05 preparation contract 一致；
- crop metadata 记录原始 bbox、padding、source size、crop size、preprocessVersion。

如果 Node 无法安全解码或裁剪该格式，交给对应 native runner 的 crop task；
两条路径输出同样的 metadata，禁止静默使用不同坐标系。

### Swift/Python runner

增加 versioned task：

~~~text
crop-recheck
  input: target list with coreImage, cropBoundsNormalized, field
  output: per-target crop image and OCR candidates
~~~

- Vision Swift 和 Paddle Python 都接受同一 normalized coordinate contract。
- 持久 Worker 处理批量 target；one-shot fallback 一次只处理当前 batch，不重复
  已完成 batch。
- Worker generation、shutdown、timeout、SIGTERM/SIGKILL 和 cancel 语义沿用当前
  OCR runner；取消后迟到结果不得回填。
- runner 只负责 crop/local OCR candidate；最终 provider review 的 structured
  result 仍由 Node 校验。
- runner failure 不让整次 high accuracy 失败，除非原有 OCR required policy
  明确要求失败即终止；crop stage 默认是 optional。

## provider 复核请求与回填

### 请求

使用现有 provider/request timeout/auth/retry 边界，增加专用 crop review schema：

- targetId、field、sourcePage 是只读定位上下文；
- coreImage 和 cropImage 都发送；
- OCR alternatives/candidates 作为 evidence，不是答案；
- 明确要求只回答给定 target + field，不输出新记录、不修改其它字段；
- 一批只放有限 targets，request body 受现有 MAX_BODY_MB 和 timeout 约束。

provider call 失败、timeout、取消、JSON 无效或返回未知 target 时，当前最终
识别 result 完全保持不变，只附加 crop summary/warning。

### 回填 guard

应用每个结果前按以下顺序检查：

1. signal 未取消且 operation id 仍是当前识别任务；
2. result.targetId 精确匹配待处理 target；
3. result.field 与 target.field 一致且在数字 allowlist；
4. record.targetId/sourcePage/recordIndex 仍匹配；
5. record[field] 仍等于 target.currentValue；
6. 当前字段仍为空，或 reviewRequiredFields/quality.reviewRequired 仍为 true；
7. result.status=confirmed 且 value 通过 Phase 02 shared normalizer；
8. 归一化结果不是 ambiguous/invalid/out-of-range；
9. 写入 normalizedValue，保留原 quality.originalValue，并合并 crop provenance。

任一 guard 失败即 skip，原因进入 diagnostics，不抛出覆盖错误。

成功的自动 crop 回填也不能把字段标记成无须人工确认：保留原 review flag 或
新增明确的 crop-rechecked warning/source，让 UI 可追溯。不得自动提升 record
confidence，除非另有冻结的质量策略。

## 开关、预算与进度

### 环境设置

在 electron/global-settings.mjs、contracts、校验和必要的 settings status 中增加：

- SLATESYNC_CROP_RECHECK：enum true/false，默认 false；
- SLATESYNC_CROP_RECHECK_MAX_TARGETS：integer 0–64，默认 12。

首次发布只允许 0–12 的产品配置；上限 64 是防止手工环境注入无限调用的硬边界。
global setting 不进入 ProjectSettings.export，不随 CSV 任务复制。

### 进度

复用现有 recognition progress phases，推荐增加：

- crop-select：扫描候选/已选数量；
- crop-recheck：batch completed/total；
- crop-complete：confirmed/uncertain/failed/skipped。

进度只报告计数、页码和耗时，不报告原图/候选文字/密钥。cancel 应在单个
batch deadline 内响应，不等待整个 max target 队列。

## 测试与施工顺序

### 推荐顺序

1. 冻结 CropRecheckTarget/Result contract、allowlist、坐标和 guard helper。
2. 写纯 target selection/dedup/stale guard 单元测试，不调用 OCR/provider。
3. 增加 Swift/Python crop task 的 protocol fixture 和 one-shot/Worker parity。
4. 接入 ai-client，先以 no-target/disabled path 验证不增加调用。
5. 接入 batch/concurrency/deadline/cancel/provider fallback。
6. 接入 quality/normalizer 回填和 diagnostics summary。
7. 接入 global settings 校验和 progress。
8. 以真实样本做手工准确率/耗时/费用对照；本次不执行。

### 必测场景

- standard、high+disabled、high+enabled；
- 无候选、只有无 bbox 候选、重复 block、同 field 多 block；
- maxTargets=0、1、12、超过上限、非法环境值；
- 空字段、review 字段、非 review 非空字段、已确认字段；
- provider confirmed/uncertain/not-found/failed/unknown target；
- runner persistent success/failure/restart、one-shot fallback；
- timeout、cancel before selection、cancel during batch、cancel after response；
- stale record value、stale operation id、targetId mismatch、field mismatch；
- crop 坐标边界、padding、最小/最大尺寸、内容不裁切；
- normalize 返回 ambiguous/invalid/out-of-range；
- original quality/review/targetId、raw evidence 和 record order 不变。

推荐命令：

~~~sh
npm run check
npm run typecheck
npm run test:node
npm run test:modern
npm run validate:modern
git diff --check
~~~

真实 provider、真实 Swift/Python runner 和样本评估必须单独记录调用数、耗时、
费用和失败；mock 只能证明 contract，不能冒充准确率。

## 停止条件、回滚与交接

必须停止：

- target 没有稳定 targetId/field 仍被发送；
- 只发送孤立 crop、坐标系不一致或 crop 内容被裁切；
- 已确认非空字段被覆盖，或 stale response 写入当前任务；
- 关闭开关/无目标仍产生 provider/runner 调用；
- 超出 maxTargets、取消不响应、Worker 和 one-shot 重复执行；
- provider/runner 失败破坏原识别结果；
- crop 结果未走 Phase 02 normalizer 或删除原 review provenance；
- 默认值被改为 true 或需要数据库/IPC migration。

回滚优先关闭 SLATESYNC_CROP_RECHECK；保留 Phase 05 OCR alternatives/preprocess
和原 high accuracy primary/audit/review。不得删除 targetId、quality 或历史诊断。

交给 Phase 07 的证据：

- 无目标零调用、上限和并发预算；
- timeout/cancel/failure 原结果不变；
- targetId+field 精准回填和已确认字段保护；
- runner/provider 调用数、P95 延迟、费用和样本准确率；
- 默认关闭且可独立回滚的配置记录。
