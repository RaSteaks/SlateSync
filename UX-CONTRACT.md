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
- Global settings open in the dedicated macOS Settings scene with `Cmd-,`.
- Project settings remain project-scoped and never replace machine settings.
- Switching project/task flushes the single autosave writer before publishing
  the next projection. Failed flush keeps the user in the current context.

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

- All migration phases require Chinese language and Chinese IME acceptance only.
  Other languages do not require dedicated acceptance coverage. Existing file-format
  aliases and Unicode compatibility remain part of data compatibility.
- Target WCAG 2.2 AA and native macOS keyboard conventions.
- All icon-only actions have Chinese accessibility labels and help tooltips.
- Theme follows system by default, respects increased contrast and reduced motion.
- Chinese IME composition must not trigger Enter shortcuts, autosave commits,
  search dispatch or table cell completion prematurely.

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
