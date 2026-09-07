# SlateSync 1.0.0 local validation candidate

This candidate switches the build, archive, and packaging path to the native
Swift macOS application. It contains one Universal app for arm64 and x86_64,
targets macOS 15.0 or later, and includes the managed PaddleOCR source and
pinned requirements in the app resources.

The ZIP and DMG are ad-hoc signed local validation artifacts. They have not
been signed with Developer ID, notarized, assessed by Gatekeeper for public
distribution, tagged, or published as a GitHub Release.

# SlateSync 1.0.0 本地验证候选包

此候选包把构建、归档和打包入口切换为原生 Swift macOS 应用。它只包含一个同时支持
arm64 与 x86_64 的 Universal 应用，最低支持 macOS 15.0，并在应用资源中携带受管的
PaddleOCR 源码与固定版本依赖清单。

ZIP 与 DMG 仅为 ad-hoc 签名的本地验证产物。它们尚未使用 Developer ID 签名、未经过
Apple 公证或面向公开分发的 Gatekeeper 评估，也未创建 tag 或发布到 GitHub Release。
