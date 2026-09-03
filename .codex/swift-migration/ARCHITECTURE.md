# Native architecture

## Module graph

```text
SlateSync.app (Xcode app target)
  └─ SlateSyncUI
       ├─ SlateSyncWorkflow
       │    ├─ SlateSyncMedia
       │    └─ SlateSyncPersistence
       └─ SlateSyncDomain
```

- `SlateSyncDomain`: Codable/Sendable values, stable errors and service protocols.
- `SlateSyncPersistence`: system SQLite3, Project Library, task/scenario stores,
  configuration, logs and credentials.
- `SlateSyncMedia`: PDFKit/ImageIO preparation, Vision and PaddleOCR.
- `SlateSyncWorkflow`: CSV, metadata, providers and recognition coordination.
- `SlateSyncUI`: SwiftUI feature models/views and narrowly isolated AppKit bridges.
- Xcode app target: `@main`, scenes, commands, resources and dependency composition.

## Ownership

- Mutable storage and long-running operations are actors.
- UI projections are focused `@MainActor @Observable` models; no mega-store.
- AppKit is limited to file panels, window edges and the editable 10k-row table.
- APIs are `async throws`; `SlateSyncError` preserves code/message/retryable.
- Swift 6 complete concurrency checking is mandatory.

## Runtime baseline

- Xcode 26.3 (17C529), Swift 6.2.4, macOS 26.2 SDK.
- Deployment target 15.0; Release builds arm64 and x86_64.
- Bundle identifier `com.slatesync.app`; application data remains under the
  historical `~/Library/Application Support/SlateSync` root.
