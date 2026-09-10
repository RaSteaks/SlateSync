# SlateSync 识别质量与 CSV 导出增强实施方案

## 1. 实施分支

`codex/feat/recognition-accuracy-csv-export`

## 2. 实施目标

在保持现有项目、任务和默认 CSV 兼容性的前提下：

- 提高中文数字、混淆字符和低置信度字段的可用性
- 增加可配置的 CSV 导出列、表头和文件名
- 支持 GBK/GB18030 源文件读取
- 提供字段级人工复核提示
- 在 high accuracy 模式下增加受控的 OCR 复核能力

## 3. 不在本次范围内

- 不新增 OCR 服务商
- 不改变无参数导出的默认字节结果
- 不增加 delimiter 配置 UI
- 不增加 standard 模式额外图片视图
- 不把 review 状态加入 CSV 导出列
- 不改变 SQLite、任务格式和已有 IPC 协议的基本语义

## 4. 核心数据流

统一为：

```text
图片准备
  → OCR
  → 模型识别与 high accuracy 合并
  → 中文/混淆字符归一化
  → 字段级复核标记
  → 任务持久化与界面展示
  → 统一 CSV 构建与导出
```

预览和最终导出必须调用同一个 CSV 构建函数，避免预览结果与实际文件不一致。

## 5. 阶段一：契约和兼容性基础

涉及文件：

- `src/shared/contracts/index.ts`
- `lib/project-settings.mjs`
- `AGENT.md`

实施内容：

- 增加统一的 `ExportOptions`
- 增加语义列定义，不通过显示表头推断字段
- 在 CSV 表格中区分 `sourceEncoding` 和最终导出编码
- ProjectSettings 支持 v1 读取、v2 写入
- 旧设置保存时保留 `export` 分支和未知字段
- 增加稳定的 `targetId`，供 crop recheck 使用
- 为跨层函数补充职责、生命周期和兼容性注释

验收条件：

- v1 项目可以正常打开
- v1 保存后不会丢失新增配置
- 默认设置行为与当前版本一致

## 6. 阶段二：中文归一化和复核标记

涉及文件：

- `public/metadata-common.js`
- `lib/schema.mjs`
- `public/resolve-csv.js`
- modern 和 legacy 结果界面

实施内容：

- 在共享模块实现纯函数归一化
- 支持逐字数字和单位数字，例如 `二〇三`、`十一`、`一百零五`
- 按字段处理视频号、卡号后缀中的混淆字符
- 不确定时保留原值并增加复核标记
- 自动修复字段加入 `reviewRequiredFields`
- 保留原始 OCR 证据，不覆盖原始识别文本
- modern 和 legacy 界面显示字段级复核提示

验收条件：

- 归一化结果在 Node、modern、legacy 三处一致
- 复核标记可持久化，重新打开后仍存在
- 未被修复的字段不会被意外降级或覆盖

## 7. 阶段三：CSV 后端和导出选项

涉及文件：

- `public/resolve-csv.js`
- `public/csv-background-tasks.js`
- `src/renderer/services/csv-worker-service.ts`
- `src/renderer/state/export-store.ts`

实施内容：

- `decodeResolveCsv` 增加 UTF-8 失败后的 GBK/GB18030 尝试
- 导出仍只允许 UTF-8、UTF-16LE、UTF-16BE
- standalone 支持语义列：scene、shot、take、comments、takeStatus、cardNumber、videoCode、sourcePage
- 支持默认表头、中文表头和自定义表头
- 自定义表头保存为“字段 key → 显示名称”
- 支持 `{project}`、`{source}`、`{date}`、`{time}` 文件名 token
- 统一实现代码默认值、项目默认值和当前会话覆盖值

优先级：

```text
会话覆盖值 > 项目默认值 > 系统默认值
```

验收条件：

- 无参数导出与旧版本逐字节一致
- GBK 源文件可以正确读取并导出为 UTF-8/UTF-16
- 自定义表头在预览、导出和任务恢复后保持一致
- 文件名会过滤路径分隔符和非法字符

## 8. 阶段四：modern 和 legacy 导出界面

涉及文件：

- `src/renderer/features/workspace/WorkspacePage.tsx`
- `src/renderer/features/settings/ProjectSettingsPage.tsx`
- `src/renderer/features/export/ExportOptionsPanel.tsx`
- `public/index.html`
- `public/app.js`

实施内容：

- 两套 Renderer 使用同一份 `ExportOptions`
- 增加导出选项面板
- 支持当前会话临时覆盖
- 支持保存为项目默认
- 预览刷新时传入完整导出选项
- 最终导出使用与预览完全相同的构建逻辑
- 两套 UI 的字段、默认值和文件名行为保持一致

验收条件：

- modern 与 legacy 生成的 CSV 内容一致
- 修改选项后预览立即反映变化
- 旧项目保存时不会丢失新的 export 配置

## 9. 阶段五：OCR 质量增强

### 9.1 Vision alternatives

涉及文件：

- `scripts/vision_ocr.swift`
- `lib/ocr/vision.mjs`
- `lib/ocr/paddleocr.mjs`
- `electron/global-settings.mjs`

实施内容：

- Vision OCR 从单候选扩展为最多 3 个候选
- 归一化结果支持 optional alternatives
- 缓存 key 加入 alternatives 开关和输出版本
- OCR evidence 优先保留低置信度数字块
- runner 构建脚本和发布流程同步更新

### 9.2 图像增强

拆为两个小版本：

1. 对比度/锐化
2. deskew

第一版先使用隐藏开关或灰度发布，确认样本集无回归后再默认启用。legacy 处理大图时必须限制图像尺寸并记录处理耗时，避免界面阻塞。

## 10. 阶段六：high accuracy crop recheck

实施内容：

- 仅在 high accuracy 模式触发
- 只选择低置信度或已标记复核的数字字段
- 同时传入原始 core 图片、裁剪图、`targetId`、字段名和裁剪坐标
- 限制目标数量、调用次数、超时和取消
- 复核失败时保留原结果
- 只更新空字段或已经标记复核的字段
- 不覆盖已确认的字段

首次发布建议：

- `SLATESYNC_CROP_RECHECK=false`
- `SLATESYNC_CROP_RECHECK_MAX_TARGETS=12`
- 通过准确率、耗时和费用验证后再默认启用

## 11. 测试计划

必须新增：

- 中文数字及混淆字符归一化测试
- v1 → v2 ProjectSettings 迁移测试
- 旧配置保存不丢字段测试
- GBK、GB18030、UTF-8、UTF-16 输入测试
- 默认 CSV 字节快照测试
- 自定义表头和语义列恢复测试
- modern/legacy CSV 一致性测试
- `reviewRequiredFields` 持久化测试
- crop recheck 无目标、超限、超时、取消、失败回退测试
- OCR 增强前后对照测试

最终门禁：

```text
npm run check
npm run typecheck
npm test
npm run validate:modern
npm run test:electron:smoke
```

## 12. 完成标准

- 默认识别和默认 CSV 行为保持兼容
- v1 项目可读写
- modern/legacy 功能一致
- 预览与最终导出一致
- 中文归一化不会扩大误识别
- OCR 增强失败时可回退
- crop recheck 不会覆盖可信结果
- 大图处理不会造成明显界面阻塞
- `AGENT.md` 已记录最终架构和开关策略

建议每个阶段独立提交，便于回滚和定位回归。
