# Phase 04–07 手工验收矩阵

| 场景 | 自动化状态 | 手工门禁 | 预期结果 |
| --- | --- | --- | --- |
| 项目默认导出配置 | 已覆盖 precedence/normalization 测试 | 待隔离 GUI | ProjectSettings 保存后回到项目默认层 |
| 当前任务导出覆盖 | 已覆盖 Worker/filename contract | 待隔离 GUI | 只影响当前任务；新任务不继承 |
| alternatives 0/1/3 | 已覆盖 Node contract/cache/evidence | 待真实 Vision | 0 保持旧 block 形状，1–3 只保留有界候选 |
| 图像增强关闭/开启/失败 | 已覆盖纯函数、Worker contract、fallback | 待真实扫描样本 | 失败回原图并记录 metadata/duration |
| deskew | 已覆盖扩展画布纯函数 | 待倾斜表格样本 | 不裁切内容，确认质量后再灰度放量 |
| crop recheck 无目标/max=0 | 已覆盖零调用选择与上限 | 待隔离 GUI/Provider mock | Provider call count 为 0 |
| crop recheck 成功/失败/取消 | 已覆盖 target guard 与回退单元 | 待真实 Provider/取消操作 | 原值和 raw evidence 保留，确认字段不被覆盖 |
| packaged Electron/ABI | 未执行 | 待 Owner 授权 | unsigned/local package smoke 通过 |

所有待验收项目均应使用临时 `userData`/`libraryPath`，不接触默认 Project Library；证据中不得保存 API key、Authorization、原图或完整 data URL。
