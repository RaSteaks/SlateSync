# Release and support / 发布与支持

## Local validation / 本地验证

Run `./script/phase_gate.sh SM-09` from a clean commit. The Gate produces one Universal
macOS 15+ app and round-trips ZIP and DMG payloads. It also launches the ZIP's Release app
through the same isolated XCUI scenarios. Preserve the Gate result, manifest and checksums.

在干净提交上运行完整 Gate。产物位于该轮结果目录的 `artifacts/`，ZIP、DMG 和 release notes
由 `SHA256SUMS` 覆盖；JSON manifest 记录 commit、版本、架构、签名 lane 与 app 内容哈希。
运行 `shasum -a 256 -c SHA256SUMS` 核验下载内容。不要只根据文件名判断来源。

## Distribution boundary / 分发边界

The default dispatch workflow remains an ad-hoc local validation lane with read-only repository
permissions. It does not publish a release. Formal distribution uses the separate
`.github/workflows/release-developer-id.yml` workflow, which imports a Developer ID certificate
into a temporary keychain, archives with a secure timestamp, notarizes, staples, packages and
uploads a GitHub Release.

正式分发必须使用 `Developer ID Application`、hardened runtime、secure timestamp、Apple
notary `Accepted`、staple/validate 和 Gatekeeper assessment。不要用 Apple Development 或
ad-hoc 候选包直接对外发布，也不要为了绕过 Gatekeeper 关闭安全检查。

The distribution workflow reuses the repository's existing secrets: `APPLE_ID`,
`APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, `CSC_KEY_PASSWORD`, `CSC_LINK`, and
`CSC_NAME`. `CSC_LINK` must contain the base64-encoded encrypted Developer ID `.p12`,
`CSC_KEY_PASSWORD` decrypts that p12, and `CSC_NAME` must be the full Developer ID Application
identity. The Apple ID and app-specific password are stored in a temporary keychain profile for
`notarytool`; none of these values are written to the repository.

本次本机验证已确认 Developer ID identity、Universal archive、hardened runtime、secure
timestamp 和 `verify_bundle.sh ... developer-id` 通过；尚未取得 `notarytool Accepted`，不宣称
已完成公开分发。证书、私钥和密码不得写入命令日志、manifest 或 Git；外部 tag/Release 创建
需要通过受保护 workflow 进行。

## Mac App Store archive / Mac App Store 归档

The shared Xcode scheme now archives with the `AppStore` configuration. That configuration
uses automatic Apple Distribution signing and embeds App Sandbox, outgoing network, and
user-selected file read/write entitlements. The existing `Release` configuration and scripted
Developer ID ZIP/DMG workflow remain separate. After exporting the App Store `.pkg`, run
`./script/verify_app_store_sandbox.sh /absolute/path/to/SlateSync.pkg` before upload; the check
reads the signed executable inside the package. An earlier `.pkg` cannot gain entitlements
without a new archive and export.

共享 Xcode scheme 的 Archive 使用 `AppStore` 配置；导出 App Store `.pkg` 后先运行上述
校验脚本。该检查只验证签名与沙盒权限，不代表完整商店审核通过。沙盒版仍需在目标签名下
验证旧版数据迁移、项目库重开、文件导入/导出，以及依赖外部 Python 的 PaddleOCR 功能。

## Data upgrade and rollback / 升级与回退

The format stays at Library/project SQLite v1. Native tests import genuine pre-cutover
project and library exports, edit data, reopen, export and reimport while preserving unknown
fields and the import source. Back up the Library before installing a replacement app.
Restoring an earlier app does not restore data; restore a separate backup when needed.
Future schema upgrades need their own rollback decision.

自动验证使用独立临时安装与数据目录，不替换 `/Applications/SlateSync.app`。保留旧安装包和
应用导出的独立备份。导入失败时保留原包，通过日志定位错误，不删除源数据尝试修复。
Keychain 迁移仅在写入并回读核验后清理旧凭据来源；测试使用隔离/fake 凭据。

## Troubleshooting / 故障定位

- Verify checksums and manifest version/build before testing a candidate.
- Inspect `codesign --verify --deep --strict` failures for missing or changed bundle resources.
- Inspect the application Logs route and the exact Gate check log; avoid sharing credentials.
- For Paddle, check the configured interpreter, pinned requirements and optional model setup.
- If a candidate fails, stop distribution and build a new version rather than overwriting an
  already published artifact or silently replacing its checksums.

遇到打开失败时先核对包的版本、checksum 和签名 lane；设置中检查 Provider/OCR 配置，
帮助与运行日志可离线访问。不要将完整 Provider 请求或含凭据的日志上传。候选包异常时
停止分发，保留失败证据；不要覆盖既有发布产物。
