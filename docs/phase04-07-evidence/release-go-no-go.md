# Phase 04–07 验证与发布决策

## 当前结论

本地代码门禁为 **GO**：Phase 04–06 的代码、契约、回退逻辑和自动化测试已落地；Phase 07 的发布决策为 **NO-GO**，因为仓库安全规则不允许本次自动启动 Electron 前台/E2E，也没有 Owner 授权真实 Provider/OCR、签名或发布。

这不是自动化测试失败，而是未授权的外部验证门禁仍未完成。

## 已完成的本地验证

| 命令 | 结果 |
| --- | --- |
| `npm run check` | 通过；Node/Python 静态语法检查通过 |
| `npm run typecheck` | 通过 |
| `npm run test:node` | 通过，460/460 |
| `npm run test:modern` | 通过，31 个文件 / 196 项 |
| `npm run validate:modern` | 通过：typecheck + Modern 196 项 + `build:modern` |
| `npm run build:modern` | 通过；只有既有大 chunk advisory |
| `swiftc -typecheck ... scripts/vision_ocr.swift` | 通过 |
| `python3 -m py_compile scripts/paddleocr_runner.py` | 通过 |
| `git diff --check` | 通过 |

Modern 测试中的 `Window's scrollTo()` 是 jsdom 的既有非失败提示；未形成失败项。

## Phase 04–06 交接事实

- Phase 04：Modern/Legacy 共用 `ExportOptions`、同一 Worker builder、session > project > system 优先级、项目默认保存、任务恢复与 basename 文件名解析已接通。
- Phase 05：Vision alternatives 受 0–3 限制并隔离 cache/schema；关闭时省略 alternatives；contrast/sharpen/deskew 使用共享预处理模块，Modern/Legacy 均记录版本、回退和耗时；裁剪图输出仅在 Phase 06 高精度开关启用且预算大于 0 时生成。
- Phase 06：仅 high + 显式开关触发；目标使用 `targetId + field + sourcePage + currentValue + bbox`；默认关闭、`maxTargets=0` 零调用、硬上限 64；批处理、超时、取消、失败保留原值；回填经过 shared normalizer 且保护非复核字段。
- 根目录 `AGENT.md` 已记录本次架构、默认开关、兼容性和回滚策略。

## 未执行门禁

- `npm run test:electron:smoke` / `npm run test:electron:package-smoke`：按仓库规则未启动 Electron 前台/E2E。
- 真实 Vision/PaddleOCR runner、真实 Provider、真实扫描样本准确率/费用/P95：未使用用户凭据或原图自动执行。
- `npm run release:mac`、签名、notarization、publish：无 Owner 授权，未执行。

因此不能宣称真实样本准确率、打包 smoke 或发布产物已通过。Owner 授权隔离 GUI 与真实样本后，应补齐上述证据，再将结论改为 GO。
