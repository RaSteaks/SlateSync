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
