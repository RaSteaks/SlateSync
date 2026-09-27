# SlateSync UX Contract

This contract owns observable behavior. Visual intent is defined in `DESIGN.md`.

## Canonical UI Map

| Capability | Canonical owner | Source of truth | Allowed variants | Verification |
| --- | --- | --- | --- | --- |
| Table Selection | Native `List`/`NSTableView` selection | `ProjectLibraryView`, `TaskRailView`, and `EditableCSVTableRepresentable` | Single stable project/task/CSV row identity | UI workflow plus 500/1,000/10k scale tests |
| Select/Listbox | Native SwiftUI `Picker` | `SettingsRootView` | System menu or segmented style when the value set is bounded | Keyboard and VoiceOver behavior remains platform-owned |
| Form | Shared SwiftUI form composition | `CreateProjectSheet` and `SettingsRootView` | Sheet form or Settings form | Visible labels, default/cancel actions and focus order in UI tests |
| Toast | `SlateStatusBar` with feature-owned operation state | `WorkspaceComponents` and `AppRootView` | Inline error/recovery or persistent cross-route recognition status; no toast timers | Native UI workflow and error/export regression tests |
| CRUD | Feature model backed by workflow façade | `ProjectLibraryModel`, `ProjectSettingsModel`, and UI workflow protocols | SM-08 project/task/settings mutations; views never open Persistence directly | SwiftPM ownership tests plus Xcode workflow/UI tests |
| Navigation | `NavigationSplitView` shell | `AppRootView` and `SidebarView` | Dedicated macOS Settings scene for global settings | App-launch UI test and native keyboard navigation |

## Navigation and scenes

- The primary window uses stable sidebar selection for Project Library,
  Workspace, Logs and Help.
- When a project is acquired, the Current Project section header shows its
  saved name beside the localized label; closing the project removes the name.
- Global settings open in the dedicated macOS Settings scene with `Cmd-,`.
- Project settings remain project-scoped and never replace machine settings.
- Switching project/task flushes the single autosave writer before publishing
  the next projection. Failed flush keeps the user in the current context.
- Workspace segments acknowledge selection synchronously while keeping the
  current editor mounted until saving succeeds. Repeated clicks during that
  save select the latest destination; failure restores the current segment.

## Canonical operations

| Operation | Pending | Success | Failure | Focus |
| --- | --- | --- | --- | --- |
| Create project | stable busy button | open workspace + announce | inline form error | workspace heading |
| Save settings | disable duplicate save | remain + announce | inline summary/field | first invalid field |
| Archive | confirmation, warning intent | move to archive + announce | keep dialog/context | next project |
| Delete project | typed name, danger intent | return to library | keep dialog with retry | library heading |
| Recognize | named stage + cancel | editable results | persistent recovery | result heading |
| Export CSV | stable progress | save location announcement | inline retry | export action |

## Data and async state

- Initial loading, empty, no-results, degraded, error and retry states have
  stable geometry and explicit text.
- Stale requests and late recognition/probe responses cannot overwrite a newer
  selection or operation token.
- Progress is determinate only when total work is known; otherwise show named
  indeterminate stages. Completion never steals focus.
- Provider/network errors are redacted and actionable. Secrets never appear in
  UI copy, logs, notifications or diagnostics.

## Forms and destructive actions

- Every field has a visible label and text error; preserve non-secret input.
- Native Picker is canonical for bounded single select. Search fields expose an
  explicit clear action and are IME-safe.
- Archive is recoverable warning behavior. Permanent project deletion is danger
  behavior, names the object, requires exact typed confirmation and offers no Undo.
- Destructive dialogs remain open while work is pending and after recoverable failure.

## Tables and files

- The CSV editor owns its internal scroll region; the surrounding workspace
  does not gain a second fixed-height scroller.
- `NSTableView` is canonical for the editable 10,000-row CSV grid; SwiftUI Table
  remains suitable for smaller read-oriented results.
- File selection and drag/drop share the same validation, progress, cancel and
  error behavior. Every drag action has a button/menu alternative.

## Accessibility and locale

- Application language is selected in Global Settings → General using
  `applicationLanguage` (`zh-Hans` / `en`). `L10n` owns launch-scoped product copy;
  the same locale reaches all windows and Help. Save updates `AppleLanguages`
  in the same preference suite for native menus/panels on the next launch.
  A restart notice is shown; switching never recreates an active editor.
- Both Chinese and English product interfaces require coverage. Chinese IME and
  all existing Unicode/file-format compatibility requirements remain unchanged.
- Authored messages use `English.json`; domain errors and stored diagnostic events
  are translated only for display. Unknown service/system messages stay verbatim.
  User project/provider names, recognized text, prompts, CSV contents, canonical
  take-status values and persisted route IDs must not be translated.
- The old `helpEnglish` flag no longer controls any screen. Help always follows
  the application language; it continues to search both bundled languages offline.
- Target WCAG 2.2 AA and native macOS keyboard conventions.
- All icon-only actions have accessibility labels and help tooltips in the selected language.
- Theme follows system by default, respects increased contrast and reduced motion.
- Chinese IME composition must not trigger Enter shortcuts, autosave commits,
  search dispatch or table cell completion prematurely.

## Liquid Glass presentation contract

- `SlateGlass.swift` is the only shared implementation point for custom glass;
  feature views select semantic roles and do not construct independent blur or
  opaque chrome.
- macOS 26 uses native `glassEffect`, `GlassEffectContainer`, and glass button
  styles. macOS 15–25 retain the same layout and behavior through material and
  semantic-color fallbacks; the package deployment target remains macOS 15.
- Native sidebar, toolbar, Settings, Sheet, `List`, and `NSTableView` behavior
  remains platform-owned. Custom glass is limited to bounded application
  surfaces and is never applied per row in dense or 10,000-row collections.
- Adjacent custom surfaces share one glass container. No first-pass glass
  morphing IDs or new transitions may bypass the existing editor/save barrier.
- Reduced Transparency switches custom surfaces to opaque Slate fills;
  increased-contrast system settings and Differentiate Without Color strengthen
  edges; Reduced Motion disables interactive glass motion. Existing labels,
  identifiers, focus behavior, IME rules and status text remain canonical.

## Native UI refresh (2026-09-11)

- `SlateSearchField` owns clearable task/help/category input; clearing preserves
  selection and returns keyboard focus to the field.
- Task rail, recognition configuration and original comparison have named,
  accessible toggle controls. Hidden panels are excluded from hit testing and AX.
- Layout changes first call the window-local `WorkspaceEditorBoundary`, then
  `WorkspaceModel.flush`. Marked text or failed saving keeps the old layout.
- Result table identity remains stable while comparison changes or windows resize.
  Density changes adjust row geometry without reloading data, and defer until
  an active native field editor finishes.
- Existing file import/export, deletion confirmations, actor ownership and
  secret-handling rules are unchanged by presentation updates.


### Project opening feedback

- Native List primary action owns double-click/keyboard opening of active project rows; archived rows retain restore actions.
- AppSessionModel owns the single pending open. The app-wide centered rounded progress panel shows the project and real loading stage without moving list geometry or estimating percentages.
- Success enters the workspace; failure removes the panel and retains the previous project. Duplicate opens remain blocked throughout the save/load barrier.

### Liquid Glass review corrections (2026-09-15)

- Informational surfaces remain neutral, matching their foreground semantics.
- Increase Contrast updates mounted surfaces through workspace accessibility notifications.
- Credential badges retain capsule geometry; custom outlines appear only for accessibility modes.
- Search owns its focus/separator outline; the configuration panel owns its full-opacity leading rule, avoiding duplicate helper borders.
- The library summary uses a canvas-backed fallback, including reduced transparency, distinct from the evidence-surface list.


## Model service setup and immediate role changes (2026-09-27)

- `ProviderConfigurationSheet` owns both built-in and custom setup. `ProviderModelList` owns searchable model selection; `ProviderOperationFeedback` owns discovery/probe feedback and recovery. Native Picker, Toggle, Button, SecureField and the existing theme/search primitives remain canonical.
- Setup saves in stages. Save and fetch models persists configuration and any supplied credential before discovery; save-only performs no network discovery. Success stays in the editor. Closing preserves completed saves and guards only unsaved changes.
- Config, credential and projection-refresh outcomes remain separate. A committed key is cleared from the input even if refresh fails; retry does not re-submit the successful key. Draft credentials never enter observable feature-model state, logs or ordinary config.
- Discovery is not recognition proof. Declared/inferred models display as pending; only current verified proof permits default/backup activation. Cancellation does not persist partial probe results. Failed/partial batches must not render as all-success.
- A custom missing models endpoint permits manual IDs only for 404/405/501; authentication, quota, connection and malformed-response failures retain their categories. Offline catalogs never claim a confirmed connection.
- Default, backup additions/removals/reordering and service deletion commit immediately against the latest persisted snapshot, preserve unrelated setting drafts, and publish only on success. Controls block duplicate submissions. Destructive service confirmation stays mounted on recoverable failure.
- Request-affecting changes invalidate proof and remove affected roles according to existing revision rules. Restoration is explicit, requires valid proof and a matching role baseline, and never overwrites intervening role choices. Display-only metadata edits retain proof.
- Native acceptance now covers nine XCUI scenarios plus the four combinations inside the locale/theme/keyboard matrix at 700×540. The real native controls, keyboard path and AX state are verified with synthetic Provider responses and isolated persistence. This is not a live-vendor integration or a standalone VoiceOver speech audit.
- Model rows use data-driven identities and independent view bodies so moving from pending to verified refreshes both text and enabled state. Default/backup/restore actions remain in the fixed footer; the backup disclosure header is a full native Button with expanded/collapsed accessibility value.
- The existing native window probe reapplies the Settings resize affordance after effective-appearance changes, while SwiftUI continues to own frame constraints.


### Review hardening (2026-09-27)

- Starting discovery clears transient probe feedback, not durable proof. Current operation feedback and current capability proof have separate lifetimes. API `unsupported` survives static/manual candidates; only valid current proof overrides it. Persisted builtin proof includes its bounded diagnostic and check time.
- Credential replacement/removal can revoke roles before a failing key write. The editor retains an operation-local expected baseline derived from original selections minus the affected service, and best-effort projection recovery exposes committed revocations. Retries never replace that baseline with a stale snapshot or blindly accept intervening role changes.
- Canceling discovery/probing as part of deletion terminates its UI state even when deletion cannot persist. The service stays visible and editable; new network work is blocked while a configuration write is running.
- All picker and save eligibility checks use the same current-proof implementation, including legacy aliases and draft revisions. Credential gating follows the provider requirement; anonymous custom services remain valid.
- Endpoint-looking Base URL suffixes are advisory. Raw URL validation occurs once before draft credential lookup and transport construction. Isolated synthetic Provider operations require explicit opt-in plus both injected transport factories; installer/real external operations remain disabled.
