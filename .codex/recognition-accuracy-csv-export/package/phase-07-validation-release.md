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
