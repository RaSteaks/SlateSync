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
