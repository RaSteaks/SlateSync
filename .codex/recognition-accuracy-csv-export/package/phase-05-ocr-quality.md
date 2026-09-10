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
