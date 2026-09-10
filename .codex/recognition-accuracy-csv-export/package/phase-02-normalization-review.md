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
