# 场记单结构识别实现状态

日期：2026-10-29。状态：代码实现、定向回归与离线集成检查完成。用户已允许离线验证；真实场记单效果、云端评测及远端完整验收尚未执行。默认策略保持关闭，不以离线检查代替真实精度证据。

## 实现与调用入口

| 规划工作 | 当前代码与连接方式 |
| --- | --- |
| 动态裁图 | `RecognitionPageSource` 冻结受限输入，`TableRuleDetector` 提取表格线，`RecognitionLayoutPlanner` 结合既有表头语义生成最多两个局部区域；`OptimizedMediaOCR` 在全页 OCR 后执行局部阶段 |
| 行列与合并格证据 | `RecognitionTableStructure` 保存内部区域、行列、候选合并范围和未分配文字；`RecognitionStructureEvidence` 形成有长度预算的主识别提示，独立查漏不接收该提示 |
| 无损本地输入 | 历史视图编码钩子从同一份缩放像素生成 JPEG／PNG；`LocalOCRImage` 与原 `PreparedImage` 分离，原生 Vision 支持 PNG，Paddle 和外部 bridge 保留 JPEG 并报告回退 |
| 定向复核 | `RecognitionReviewPlanner` 使用唯一卷号、可靠视频码和机位列定位；`RecognitionPagePipeline` 在原裁决阶段使用全页与最多两个新局部图，定位失败回退原图，不新增模型阶段 |
| 生命周期与缓存 | 分阶段引擎沿用同一截止时间、取消令牌与租约；实际字节和格式参与 OCR 缓存，策略及源身份参与模型结果恢复；源图按页解码，不长期持有全部解码页面 |
| 开发入口 | 现有 `Tools/ScenarioEvaluation` 工具包新增 `SlateSyncRecognitionProbe`，使用生产 OCR／布局路径，支持独立导出的 `RecognitionSheet` 评分；不访问 Provider 或正式库 |

调用方通过 `MediaOCRWorkflow(..., policy:)` 或 `RecognitionMediaFactory.make(..., policy:)` 显式传入 `RecognitionOptimizationPolicy`。不传时使用 `.baseline`。本次没有新增产品界面或自动启用策略；已有预处理视图缺少可信原稿映射时，沿用兼容路径并报告原因。

源码边界见[实现演进决定](recognition-contract-evolution.md)，原始要求见[测试收敛版方案](ocr-structure-optimization-plan.md)，开发入口格式见[离线探针说明](../Tools/ScenarioEvaluation/RECOGNITION_PROBE.md)。

## 已编写的回归范围

- `RecognitionOptimizationTests`：独立坐标期望、拼接跨界不分配、显式表格与合并格、跨列文字保留、多卷号回退、同一 JPEG 与累计截止时间、局部阶段取消、required 空文档、历史视图回退，以及复核图与 OCR 坐标一致性。
- `RecognitionPageImagingTests`：已知像素表格线、原图裁剪与 PNG 像素、编码格式缓存隔离及取消。
- 原有媒体、OCR、模型主备、请求预算、恢复与 CSV 兼容测试保持原有断言，没有为新实现改低要求。

上述新增回归已包含在通过的定向及全量检查中。静态审查已修正状态枚举评分、无效素材键计数、截止时间与文档缓存边界、机位分组定位，并避免生成后立即丢弃的额外全页图。

## 离线验证结果

本轮证据目录以 `${SLATESYNC_VALIDATION_ROOT}/` 表示，由执行者指定实际验证目录。未修改源码或放宽断言来消除环境失败。

| 检查 | 结果 | 日志 |
| --- | --- | --- |
| 严格 SwiftPM 编译与定向回归 | 40 项通过，包含新增 9 项回归 | `targeted-01.log` |
| 严格 SwiftPM 全量复验 | 610 项，4 项按既有条件跳过，0 失败 | `full-tests-unrestricted.log` |
| 无窗口预检 | 通过，包含 26 项打包脚本自测和原生功能契约 | `preflight.log` |
| 新探针严格构建 | 通过 | `probe-build.log` |
| 离线探针烟测 | 仓库合成图片经本地 Vision 成功处理；4 个导入字段评分正确，无有效素材键的记录单独计数；输出完成标记和 3 张视图 | `probe-smoke.log`、`probe-smoke/fixture/report.json` |
| Xcode Debug App 构建 | arm64、无签名、Swift 警告视为错误，BUILD SUCCEEDED | `xcode-build.log` |
| 差异空白检查 | 通过 | `git diff --check` |

首次工具沙箱内全量运行有 5 个失败断言／错误，涉及真实 Vision、进程清理及离屏布局；日志另有系统服务被沙箱拒绝的记录。相同代码解除工具沙箱限制后，相关 10 项复核全部通过，随后全量 610 项通过。保留 `full-tests.log`、`vision-unrestricted.log` 和 `environment-recheck.log`，不把首次失败写成通过。

合成烟测走到了布局证据不足时的兼容裁图，不能据此声称真实动态裁图效果达标。真实像素几何、结构分配和定向复核由新增确定性回归覆盖，其真实场记单泛化仍需样本评测。

## 尚未执行的效果与发布验收

- 真实场记单的 4～6 页单项筛选及独立留出集效果验收；无损路径的真实质量、资源开销和收益结论仍未建立。
- 真实 Provider 调用、样本出网与费用评估；执行前需明确授权范围和预算。
- GitHub macOS runner 完整 SM-09／XCUI、打包 UI 及发布验收。

本轮未启动 App、未运行前台性能测试、未调用云端模型、未提交或推送。新增策略继续默认关闭。源码中的表格线与置信度阈值需要用真实数据校准，未知布局与不可靠目标继续回退。
