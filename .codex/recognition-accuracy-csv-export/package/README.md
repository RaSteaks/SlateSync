# SlateSync 识别质量与 CSV 导出增强：阶段包

本目录将主方案拆分为可独立实施、验证和回滚的阶段文档。

## 实施顺序

```text
Phase 01 契约与兼容性
        ↓
Phase 02 中文归一化与复核标记
        ↓
Phase 03 CSV 后端与导出模型
        ↓
Phase 04 modern/legacy 导出界面
        ↓
Phase 05 OCR 质量增强
        ↓
Phase 06 high accuracy crop recheck
        ↓
Phase 07 集成验证与发布
```

Phase 05 可以在 Phase 04 完成后开始，但 Phase 06 必须等待 Phase 05 的 OCR 输出契约稳定。

## 阶段文档

- [Phase 01：契约与兼容性基础](./phase-01-contracts-compatibility.md)
- [Phase 02：中文归一化与复核标记](./phase-02-normalization-review.md)
- [Phase 03：CSV 后端与导出模型](./phase-03-csv-backend.md)
- [Phase 04：modern/legacy 导出界面](./phase-04-export-ui.md)
- [Phase 05：OCR 质量增强](./phase-05-ocr-quality.md)
- [Phase 06：high accuracy crop recheck](./phase-06-crop-recheck.md)
- [Phase 07：集成验证与发布](./phase-07-validation-release.md)

## 全局不变量

- 无参数导出必须保持原有字节结果。
- v1 项目设置必须可读取，保存时不能丢失新增字段。
- modern 和 legacy 的导出结果必须一致。
- 预览和最终导出必须使用同一份导出构建逻辑。
- 自动归一化不能覆盖原始 OCR 证据。
- OCR 或复核失败时必须保留原结果并可继续完成任务。
- 每次代码修改都要同步补充或更新相关代码注释。

## 最终门禁

```text
npm run check
npm run typecheck
npm test
npm run validate:modern
npm run test:electron:smoke
```

每个阶段完成后应单独提交，提交前先执行该阶段文档中的验收项。
