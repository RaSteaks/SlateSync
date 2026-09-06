# SM-09 WP-0 决策记录（2026-09-07）

按 `packages/SM-09.md` WP-0 第 4 条冻结的发布/版本/分发决策。每项都标注了
默认依据；Owner 可推翻任何一项，推翻后必须先更新本文件再进入对应 WP。

## 1. 产物格式

保留默认：**同一个已验证 Universal `SlateSync.app` 同时生成 `.zip` 与 `.dmg`**，
文件名 `SlateSync-<version>-macOS-universal.{zip,dmg}`，二者来自同一 audited
app payload lineage，附 `SHA256SUMS` 与 JSON manifest。

## 2. 版本映射（WP-0 冻结）

| 维度 | 值 | 来源 |
| --- | --- | --- |
| tag | `v1.0.0` | 本决策记录（首次 native release） |
| `CFBundleShortVersionString` / `MARKETING_VERSION` | `1.0.0` | `SlateSync.xcodeproj`（已核对） |
| `CFBundleVersion` / `CURRENT_PROJECT_VERSION` | `1`（单调整数，本次不递增） | `SlateSync.xcodeproj`（已核对） |
| 最低系统 | macOS 15.0 | `MACOSX_DEPLOYMENT_TARGET`（已核对） |

无合法 tag 或三者不一致时 release fail-closed；不允许脚本静默改写 tracked
project 后打包。

## 3. 签名与分发 lane

本阶段只做 **Local/PR ad-hoc lane**：Release Universal + hardened runtime +
最小 entitlements + ad-hoc 签名 + `codesign --verify --deep --strict`。

- Developer ID / notarytool / staple / spctl / GitHub Release：**本次不执行**
  （本地无 Developer ID credential；按治理记 `BLOCKED_ENV` 或由受保护 CI 提供
  同 commit 等价证据，不得降级 ad-hoc 后声称 notarized）。
- 不创建 tag、不上传 GitHub Release（外部发布需 Owner 另行明确授权）。
- release notes：中英双语，随 WP-5 产出；不发布 dSYM（如需再单独决策）。

## 4. 工具链与 runner

- Xcode 26.3 / Swift 6.2.4 / macOS 26.2 SDK（与 `CURRENT_STATE.json` 一致）。
- CI runner `macos-14`（与现有 workflows 一致，WP-4 只做步骤切换）。

## 5. decision-required 清单处理（recommendation 待 Owner 确认）

| 路径 | 建议 | 理由 |
| --- | --- | --- |
| `scripts/vision_ocr.swift` | 删除（WP-6） | 默认引擎为原生 Vision；显式 `VISIONOCR_BINARY` 兼容车道若保留需 Owner 明确要求 |
| `scripts/setup-paddleocr.sh` | 删除（WP-6） | SM-08 原生 `PaddleOCRInstallerService` 已完全替代 |
| `build/entitlements.mac.plist` | 删除（WP-6） | Electron 打包专用 entitlements，与原生无关 |
| `.env.example` | 删除（WP-6） | SM-03 原生 GlobalConfig/Keychain 已覆盖其全部非敏感项 |
| `premium-ui.json` | 归档删除 | 历史 UI 审计工件，无 runtime 引用 |
| `slatesync.config.json` | 待引用核查 | 以 inventory referencers 为准，确认无入口读取后删除 |

以上建议在 WP-6 实施前需 Owner 一次性确认；未确认前这些文件保持原样。

## 6. 覆盖映射（WP-0 第 5 条）状态

`sm09-coverage.json`（旧 Node/Electron test family → Swift/fixture/history-only
的逐项映射）是 `legacy-remove` 的前置条件，将在 WP-1 baseline 执行期间随
family 枚举一并产出并落盘 `Tests/SlateSync*Tests/Fixtures/SM09/`（终态位置）。
本文件记录该未完成项，防止在映射冻结前发生任何删除。
