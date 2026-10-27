# 场记版式离线评测工具

这个开发工具复用生产环境的本地 Vision OCR 和逐页结构匹配器，读取独立标注及冻结模板快照，输出版式匹配结果、覆盖率、正确率、未知版式误接纳率和媒体阶段耗时。它不访问正式项目库、不创建 App 模板，也不调用模型 Provider。

当前评测范围是模板归属，不是最终场镜次和手写内容的端到端准确率。不要用本工具的模板分数代替字段准确率或完整发布验收。

## 运行

从仓库根目录运行，所有构建、缓存、临时文件和结果都放在指定的 1027 目录：

    EVAL_ROOT=/Users/rasteaks/Desktop/SlateSync/1027/scenario-evaluation
    mkdir -p "$EVAL_ROOT/tmp"
    export TMPDIR="$EVAL_ROOT/tmp"
    export RUNNER_TEMP="$EVAL_ROOT/tmp"
    export CLANG_MODULE_CACHE_PATH="$EVAL_ROOT/cache/clang"
    export SWIFTPM_MODULECACHE_OVERRIDE="$EVAL_ROOT/cache/swift"
    export SLATESYNC_EVALUATION_REVISION="$(git rev-parse HEAD)"
    swift run --package-path Tools/ScenarioEvaluation \
      --scratch-path "$EVAL_ROOT/build" \
      --cache-path "$EVAL_ROOT/cache/packages" \
      --config-path "$EVAL_ROOT/cache/config" \
      --security-path "$EVAL_ROOT/cache/security" \
      SlateSyncEvaluation /absolute/path/to/corpus.json "$EVAL_ROOT/run-001"

结果目录必须不存在，避免覆盖旧报告。需要 Swift 6.2 和 macOS 15 或更高版本。原稿走本地 Vision；已记录 OCR JSON 可直接重放，不需要重新调用 OCR。JSON 遵循 ScenarioObservationInput，views[0] 必须为全页；推荐使用工具保存的 observation-N.json。

## 生成独立模板快照

先人工确定训练样本的版式标签，并创建训练清单：

    {
      "schemaVersion": 1,
      "mode": "training",
      "templates": [],
      "matching": { "threshold": 0.85, "ambiguityMargin": 0.05 },
      "samples": [
        {
          "id": "train-a-01",
          "sourceGroupID": "original-sheet-a-01",
          "path": "images/train-a.pdf",
          "expected": [
            { "pageNumber": 1, "templateID": "form-a" }
          ]
        }
      ]
    }

path 相对清单所在目录，原稿和 JSON 都必须位于该目录内；不能通过相对路径或符号链接跳到目录之外。多页输入必须为每页提供标签。训练模式要求 templates 为空且所有页都有非空模板标签。

训练仅构建模板原型，不训练模型权重：按照样本 ID 固定顺序选取原型，后续同标签样本必须在当前匹配规则下与该原型相容，否则报错要求检查标签或版式。sourceGroupID 相同的扫描副本只计一个训练来源。

输出的 snapshot.json 包含冻结的 templates 和 trainingSourceGroupIDs。复制到评测数据目录后，为它填入独立评测 samples，保持 mode 为 evaluation。评测标签由人工给出，不能用 App 的预测结果填回真值。

## 评测

评测清单使用 snapshot.json 中的 templates，不重新生成模板。samples 的格式与训练相同；已知模板填写对应标签，未知版式必须显式填写 templateID: null。省略标签属于输入错误。

    {
      "id": "evaluation-a-01",
      "sourceGroupID": "original-sheet-a-02",
      "path": "images/evaluation-a.png",
      "expected": [
        { "pageNumber": 1, "templateID": "form-a" }
      ]
    }

trainingSourceGroupIDs 与评测来源组不能交叉。分组必须由标注者维护：同一物理原稿的扫描、拍照和增强副本属于同组。缺少训练来源信息时，runtime.json 会注明没有执行分组交叉检查；这不能证明样本相互独立。

每批最多 300 页、128 MiB OCR 证据，单个原稿沿用 App 的输入限制。更大的数据集分批运行。ID 与来源组最长 256 字符；JSON 单文件最多 20 MiB。

## 结果与重放

- report.json：逐页真值、预测、状态、分项匹配诊断及指标。没有自动归属时，正确率不伪装成 100%。
- timing.json：处理原稿时的本地准备及 OCR 耗时；重放 OCR JSON 时没有新的 OCR 计时。
- corpus.json：本次实际使用的输入清单。
- observation-N.json：本地 OCR 观察，便于定位错误和脱离原稿重放。
- replay.json：评测运行的自包含 OCR 重放清单，指向保存的观察文件。
- snapshot.json：训练运行的冻结模板快照，等待填入独立评测样本。
- runtime.json：系统版本、分组检查状态和调用方提供的源码版本。源码版本字段不自动证明工作区干净，正式评测应使用已冻结提交。

运行成功表示评测已执行，不代表产品达到优化方案中的质量目标。原稿、OCR 文字和输出报告属于本地评测资料，按数据集权限保存，不自动上传 CI 或外部服务。
