# Phase 07：集成验证与发布

## 目标

验证各阶段组合后的兼容性、准确性、性能和回退能力，并准备分批发布。

## 自动化测试

必须覆盖：

- 中文数字、中文单位和混淆字符归一化
- v1 → v2 ProjectSettings 迁移
- 旧配置保存不丢字段
- UTF-8、UTF-16、GBK、GB18030 输入
- 默认 CSV 字节快照
- 语义列、自定义表头和任务恢复
- modern/legacy 导出一致性
- `reviewRequiredFields` 持久化
- alternatives 缓存隔离
- crop recheck 无目标、超限、超时、取消和失败回退
- 图像增强前后 OCR 对照

## 手工验证矩阵

### 输入类型

- 普通图片
- 低对比度图片
- 有倾斜的表格扫描
- 中文数字和混淆字符
- UTF-8、UTF-16、GBK CSV

### 运行模式

- standard
- high
- crop recheck 开启/关闭
- alternatives 开启/关闭

### Renderer

- modern
- legacy

## 性能检查

- 大图预处理耗时
- legacy 主线程是否阻塞
- OCR runner 启动和复用耗时
- high accuracy 额外调用次数
- crop recheck 取消响应时间

## 最终门禁

```text
npm run check
npm run typecheck
npm test
npm run validate:modern
npm run test:electron:smoke
```

## 发布策略

1. 先发布 Phase 01–04，保持 OCR 算法不变。
2. 单独灰度 Vision alternatives 和图像增强。
3. crop recheck 默认关闭，收集准确率、耗时和失败数据。
4. 通过验收后再调整默认开关。
5. 每个阶段保留独立回滚点。

## 完成标准

- 默认识别和默认 CSV 行为保持兼容。
- v1 项目可读写。
- modern/legacy 功能一致。
- 预览与最终导出一致。
- 自动归一化不会扩大误识别。
- OCR 增强和 crop recheck 失败时可回退。
- 大图处理不会造成明显界面阻塞。
- `AGENT.md` 已记录最终架构、开关和迁移策略。

---

## 施工包元数据与执行状态

> **施工包状态：READY FOR IMPLEMENTATION — DOCUMENT ONLY**
>
> 以下内容是 Phase 07 的详细施工包。本次只生成最终验证与发布施工文档，不执行
> 测试、构建、Electron、真实 OCR/provider、签名、发布或 Git 操作。

- 施工分支：feat/electron/accuracy-csv
- 上游门禁：Phase 01–06 必须各自完成、拥有独立回滚点和真实验证证据。
- 本阶段目标：验证阶段组合后的兼容性、准确性、性能、取消/失败回退和发布策略，
  形成可审计的 go/no-go 决策包。
- 发布原则：默认行为先保持兼容；OCR alternatives、图像增强和 crop recheck
  分开灰度；crop recheck 首发保持关闭。

## 最终验证范围与非目标

### 必须完成

1. 运行 Node、modern、legacy、Electron smoke、Worker、native ABI 和构建验证，
   不允许以单个局部测试代替全量门禁。
2. 对 Phase 01–06 的契约做跨阶段组合测试：ProjectSettings、归一化 quality、
   semantic CSV、任务恢复、OCR evidence/alternatives、preprocess、crop target。
3. 验证默认路径的 CSV bytes、v1 project/task compatibility、默认识别和关闭开关
   行为与基线一致。
4. 验证 modern/legacy 同一输入、同一 effective options、同一 normalized record
   的结果一致。
5. 用固定样本和固定配置记录处理耗时、调用次数、取消响应、失败回退和资源占用；
   对任何 regression 做明确 go/no-go。
6. 生成不含密钥/原图的验证报告、发布配置报告、回滚说明，并在实际完成后更新
   AGENT.md。

### 明确不做

- 不在本阶段顺手修复与本方案无关的 UI、OCR 或数据库问题。
- 不为通过验收删除、放宽、skip、todo 或重写既有 golden。
- 不在没有 Owner 明确授权时签名、notarize、publish 或上传 release artifact。
- 不把 mock provider、mock runner、截图占位物当成真实 smoke/准确率证据。
- 不改变默认开关只为了提升单个样本分数。

## 实施前门禁与证据规则

开始验证前必须：

1. 确认分支为 feat/electron/accuracy-csv，记录 git status --short、commit、Node/
   Electron/Swift/Python 版本和平台架构。
2. 确认 Phase 01–06 的 package completion records、测试日志和回滚点存在。
3. 读取当前 package.json 真实 scripts；若命令名与本文档不同，以 package.json
   为准并在报告中记录等价命令，不修改脚本只为迎合文档。
4. 所有任务/项目/CSV 数据使用临时目录；默认 macOS Project Library、真实
   credential、真实用户文件和生产 endpoint 禁止作为自动化输入。
5. 固定 baseline manifest：源 fixture bytes/hash、v1 settings JSON、旧 task JSON、
   OCR output/cache fixture、Electron smoke profile。
6. 每条证据记录命令、开始/结束时间、exit code、摘要和生成文件路径；日志中
   redaction provider key、Authorization、完整 data URL 和原始扫描图。

验证过程中的工作区已有改动属于 Owner；不得 reset、checkout、clean 或覆盖。

## 阶段交接门槛

### Phase 01

- v1 ProjectSettings 可读写，v2 export defaults 稳定；
- unknown top-level/nested fields 保留；
- targetId 不依赖 editable field；
- sourceEncoding 与 output encoding 分离；
- 旧 IPC/task shape 可读取。

### Phase 02

- shared normalization 只在 final merge gate 产生最终 quality；
- 二〇三、十一、一百零五、全角/混淆和非法值跨 Node/modern/legacy/CSV 一致；
- originalValue/warnings/reviewRequiredFields/raw evidence 可追溯；
- UI marker/filter 不影响编辑/confidence。

### Phase 03

- decode 支持 UTF-8/UTF-16/GBK/GB18030 输入；
- encode 仅支持 UTF-8/UTF-16LE/UTF-16BE；
- semantic builder 是 preview/export/Worker/legacy/modern 唯一来源；
- default CSV bytes 与 source table 非目标列不变；
- Worker error/fallback 不丢 table/edits。

### Phase 04

- session > project > system priority；
- task/project switch 生命周期明确；
- ProjectSettings v1/unknown fields 不丢；
- modern/legacy options、filename resolver、preview/export 一致。

### Phase 05

- alternatives=0 旧结构/旧 cache 隔离；
- alternatives 1–3、evidence 上限、summary 和 runner fallback 稳定；
- contrast/sharpen/deskew 关闭或灰度，失败回退原图；
- preprocess metadata/duration 可观测。

### Phase 06

- high-only、explicit flag、max target、stable targetId+field；
- 无候选零调用，超限、timeout、cancel、provider/runner failure 保留原结果；
- 已确认字段不覆盖，crop result 走 shared normalizer；
- 默认 false，首发预算和回滚开关明确。

任一上游交接条件不满足，Phase 07 只能报告 blocked，不能跳过依赖继续签发 release。

## 自动化测试矩阵

### 契约与迁移

- v1→v2 ProjectSettings 深相等、保存不丢 export/unknown fields；
- future version rejection；
- invalid export columns/header/format fallback；
- old task snapshot without targetId/quality/sourceEncoding/export session；
- modern/legacy restore projected fields and targetId stability。

### 归一化与证据

- common helper purity/idempotency；
- Chinese digit/unit/confusable/range/ambiguous matrix；
- final merge order only；
- quality original/normalized/warnings/review projection；
- OCR evidence/bbox/diagnostics byte or deep equality where applicable。

### CSV

- UTF-8 BOM/no BOM、UTF-16LE/BE、GBK、GB18030；
- malformed source and explicit source encoding error；
- default four columns/semantic key/all optional columns/custom headers；
- preview/final/Worker/fallback parity；
- sparse edits and empty-cell edit；
- default CSV output byte snapshot；
- sourceEncoding never enters output format.encoding。

### modern/legacy UI

- effective option priority and reset on task/project switch；
- settings save preserves future branches；
- custom header/key mapping after task restore；
- filter/preview refresh does not accept stale request；
- export error preserves table/edits；
- filename tokens/filter/fixed clock；
- modern and legacy generated table/bytes equal。

### OCR alternatives and preprocessing

- Vision alternatives off/on 1/2/3；
- old cache miss and output schema version；
- invalid alternative isolation；
- OCR optional/required/failure/timeout/cancel；
- preprocess no-op/contrast/sharpen/deskew/fallback/coordinate preservation；
- modern Worker and legacy bounded path parity。

### crop recheck

- standard/off/no-target zero call；
- high enabled target selection/dedup/max limit；
- persistent Worker and one-shot parity；
- timeout/cancel/provider/runner failure；
- targetId+field matching and stale guard；
- empty/review/confirmed field write policy；
- normalization and review provenance after writeback；
- max calls, batches, concurrency, duration summary。

### Electron and build

- development modern load；
- legacy default load；
- CSV Worker URL/dev URL/packaged URL；
- temporary profile task/project create/save/restore；
- packaged directory starts and reads required resources；
- native ABI lifecycle for Node/Electron；
- Vision bridge check/build contract on macOS if the host supports it。

## 手工验证矩阵

每个组合至少执行一次；样本、配置和结果必须进入报告。

| 输入 | standard | high | high + alternatives | high + crop |
| --- | --- | --- | --- | --- |
| 清晰普通图片 | baseline | baseline | off/on compare | default off |
| 低对比度图片 | no-op/legacy | enhanced off/on | evidence compare | target budget |
| 倾斜表格扫描 | baseline | deskew off/on | evidence compare | crop coordinate |
| 中文数字/混淆字符 | normalized/review | audit/review | alternatives visible | field write guard |
| UTF-8/UTF-16 CSV | preview/export | preview/export | not applicable | not applicable |
| GBK/GB18030 CSV | source label/output | source label/output | not applicable | not applicable |

Renderer 维度：

- modern workspace：options panel、result marker、preview、export、restore；
- legacy workspace：等价控件、结果表、CSV preview、export、restore；
- packaged Electron：最小 startup/Worker/resource smoke。

重点检查：

- 导出前后表头、列顺序、行值和编码；
- 复核 badge、review filter、quality/original value；
- task switch 不泄漏 session options；
- cancel 后原 result 和 task 状态仍可保存；
- OCR/runner/provider 失败显示可解释 warning，不出现空白结果。

## 性能、资源和预算门禁

### 基线方法

在同一机器、同一 Node/Electron 版本、同一 fixture、冷/热两种状态分别记录：

- CSV decode/semantic build/encode；
- preparation rasterize/enhance/deskew；
- OCR runner startup/warm/cached；
- primary/audit/review provider calls；
- crop target selection/local crop/provider calls；
- task save/restore；
- legacy main-thread long task；
- memory peak 或至少大 table/image 的 retained size proxy。

每个指标至少记录 median、P95、最大值和样本大小；只报告相对 baseline，不用不同
机器的绝对时间互相比较。

### Go/no-go 规则

- 默认关闭的新功能路径不得使旧 baseline 发生输出变化。
- 默认路径性能相对 baseline 超过 20% 的 P95 回归，必须 stop 进入 Owner 决策；
  不能以放宽测试或改默认样本隐藏。
- CSV Worker 不能把完整大 table 不必要复制到 React；
  preview/export 的内存峰值须与现有 retained-table 设计相符。
- legacy 不得在主线程处理原始超大图；如无法证明不卡顿，保持增强关闭。
- crop provider call 数不得超过 maxTargets 定义的 target/batch budget；默认
  maxTargets=12 的运行必须报告实际 calls/concurrency。
- cancel 应在当前 operation 的既有 bounded timeout/grace 内结束；不能启动下一
  batch，迟到结果不得回填。
- alternatives、enhancement、crop 的额外耗时/费用必须分开统计，不能并入默认
  baseline 造成误判。

## 发布分批策略

### Batch 1：Phase 01–04

- 发布契约、归一化、CSV backend、modern/legacy export UI；
- OCR provider、alternatives、image enhancement、crop recheck 保持原行为；
- 默认 CSV bytes、v1 project/task 读取和双 Renderer parity 作为 release blocker。

### Batch 2：Vision alternatives

- VISIONOCR_ALTERNATIVES 默认 0；
- 先在开发/内部样本启用 1–3，验证 cache isolation、evidence 长度、候选质量；
- 发现候选 schema/缓存问题立即关闭开关，不回滚主识别和 CSV。

### Batch 3：contrast/sharpen/deskew

- contrast/sharpen 先灰度；deskew 独立开关/独立 commit；
- 以清晰、低对比、倾斜、表格线样本做前后对照；
- 未达到性能/准确率/无裁切门禁时保持关闭。

### Batch 4：crop recheck

- SLATESYNC_CROP_RECHECK=false；
- SLATESYNC_CROP_RECHECK_MAX_TARGETS=12；
- 只对内部样本开启，收集准确率、P95 延迟、实际调用数、费用、取消成功率；
- 达到单独批准的 go/no-go 后才可调整默认值，且必须新建发布/回滚记录。

## 构建、Smoke 与发布命令

施工阶段由执行者根据真实 package.json 运行并保存输出；本次不执行：

~~~sh
npm run check
npm run typecheck
npm test
npm run validate:modern
npm run test:electron:smoke
npm run test:electron:package-smoke
npm run test:native:abi
~~~

Electron/package 顺序：

~~~sh
npm run electron:build:dir
npm run test:electron:package-smoke
~~~

这些命令应使用临时 profile 和 unsigned/local build。签名、notarization、发布
服务器、GitHub release 和 npm publish 不属于无审批的本地门禁。

真正 macOS release 命令，如 npm run release:mac，只能在 Owner 明确授权、版本和
签名策略确认后执行；不要用 release 命令替代本地 smoke，也不要加入 publish
参数来“顺便”上传。

## 发布报告与证据包

建议在不纳入产品运行时的验证目录保存：

- environment.json：平台、架构、版本、开关（无 secret）；
- baseline-manifest.json：fixture/hash/expected bytes；
- node-test.log、modern-test.log、electron-smoke.log、package-smoke.log；
- csv-parity.json、settings-migration.json、ocr-cache.json、crop-budget.json；
- performance.json：median/P95/max/样本数量；
- manual-matrix.md：输入、模式、Renderer、结果、截图/日志引用；
- release-go-no-go.md：风险、已知限制、回滚开关、Owner decision。

原图、data URL、Authorization、API key、用户目录绝不进入证据包。若必须引用样本，
使用脱敏 fixture/hash。

## 最终 Go/No-Go 清单

### Go 必须全部为真

- 全量自动化命令成功，没有 skip/todo/only 或隐藏失败；
- baseline default CSV/project/task/recognition 行为兼容；
- v1 project、旧 task、旧 cache、旧 Worker payload 可读取；
- Node/modern/legacy semantic output 和 filename/options parity；
- alternatives/preprocess/crop 的开关、缓存、取消、回退均可解释；
- targetId/quality/review/raw evidence 不丢失；
- performance/费用/调用次数在预算内；
- packaged smoke 通过并包含所需 bridge/Worker/PDF 资源；
- AGENT.md 已记录最终架构、开关默认值、迁移和回滚策略；
- Owner 已确认 release artifact、版本和发布范围。

### 任一为真则 No-Go

- 默认 bytes 或默认识别结果发生未解释变化；
- v1/旧任务/旧 cache 读取失败；
- preview/export、modern/legacy、Worker/fallback 结果不一致；
- OCR/crop 失败覆盖原结果、取消不响应或超过预算；
- 已确认字段被 crop 覆盖、targetId 不稳定、raw evidence 被改写；
- 需要删除/放宽 golden 或新增未授权数据库/IPC；
- 发布构建、资源、native ABI 或 Electron smoke 不可复现；
- 没有真实日志而只有手工口头结论。

## 回滚与完成标准

回滚顺序从最新开关向前：

1. 关闭 crop recheck；
2. 关闭 deskew；
3. 关闭 contrast/sharpen；
4. 关闭 alternatives；
5. 保留 Phase 01–04 的契约/CSV/UI 兼容层；
6. 若 Phase 01–04 也出现兼容问题，回到独立 commit 的上一发布点，不删除旧
   task/project 数据。

Phase 07 只有在所有 Go 条件、证据包、Owner decision 和 AGENT.md 更新完成后才
能标记完成。完成后只交付发布结果，不自动继续下一轮开发或改变默认开关。
