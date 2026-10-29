# 场记识别离线探针

`SlateSyncRecognitionProbe` 是同一工具包中的独立命令行入口，调用生产媒体、OCR、布局与结构提示代码。它不会启动 App、访问正式项目库或调用 Provider。`SlateSyncEvaluation` 的版式评测职责保持不变。

当前入口已完成严格构建与仓库合成样本烟测；真实样本评测仍需按授权范围执行：

```sh
swift run --package-path Tools/ScenarioEvaluation SlateSyncRecognitionProbe /absolute/private/manifest.json /absolute/private/new-run
```

输出目录必须不存在，其父目录需已存在。输入相对清单目录解析，禁止通过绝对路径、父目录或符号链接逃出该目录。源码、构建配置与运行环境版本由执行者同时保存在实验目录，避免把不同版本的报告当成配对结果。

最小清单如下。`features` 为空时走现有路径；按需要添加 `dynamicCrops`、`structureEvidence`、`losslessLocalOCR`、`targetedReview`。每次只比较本项变化，不能将不同精度模式作为同一对照。

```json
{
  "features": ["dynamicCrops", "structureEvidence"],
  "saveImages": true,
  "samples": [
    { "id": "sample-01", "path": "input/sample.pdf", "accuracy": "high" }
  ]
}
```

报告包含冻结输入摘要、策略版本、系统与 Vision 配置、OCR 观察、结构、回退诊断和耗时；源码版本可通过 `SLATESYNC_EVALUATION_REVISION` 传入，未提供时保持未知。可选保存全页与局部 JPEG 以核查覆盖。每次运行最多 30 个文件，每份仍遵循生产 20 页和输入大小上限。成功后写入 `completed.txt`；缺少该标记的目录只代表部分产物。

本地探针不能证明最终场镜次准确率，也不会实际触发云端冲突裁决。若需评分最终业务字段，可为样本提供 `recognizedResult`，指向生产流程导出的 `RecognitionSheet` JSON，并提供 `labels`。标签不会进入 OCR 输入；该模式是结果重放评分，报告中的 OCR 耗时不包含被导入的云端识别耗时。

```json
{
  "id": "sample-01",
  "path": "input/sample.pdf",
  "recognizedResult": "results/sample-sheet.json",
  "completeRecordCoverage": false,
  "labels": [
    { "materialKey": "A001C001", "fields": { "scene": "037", "shot": "01", "take": "02", "takeStatus": "" } }
  ]
}
```

只评分明确列出的 `scene`、`shot`、`take`、`takeStatus`；空字符串表示人工确认的空值，未列字段不评分。重复素材键单列为重复，不挑选其中一个结果评分；缺少有效素材键的记录单独计数。仅当人工确认标签覆盖全部纸面记录时，才设置 `completeRecordCoverage: true` 并统计额外素材。评分只做双方一致的 Unicode 与首尾空白规范化，保留前导零与字母，不用真值修正识别结果。
