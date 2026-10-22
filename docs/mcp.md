# Local MCP integration

SlateSync exposes six workflow tools through a local **stdio** executable. It
shares recognition, OCR, material matching, reconciliation and CSV encoding
with the native application. It does not launch the app or edit its project
library, tasks, global settings or provider credentials.

## Build and connect

In SlateSync, open **Settings → MCP** and click **Start MCP**. The app finds
its source checkout, runs an incremental Release build, then starts the helper.
No directory selection is required. The UI shows preparation/build, startup,
running, stopping, stopped and failure states; an unexpected exit is detected.
Preparation can be canceled, and quitting cancels and drains a pending build.

The first build requires the project's Xcode / Swift toolchain and internet
access to resolve the pinned SDK. The helper is still not shipped in the current
App/DMG. If the source checkout moved or is unavailable on this machine, use
**Advanced settings → Choose source directory** once. It must contain
`MCP/Package.swift` and `script/run_mcp.sh`. A manually selected built executable
bypasses building; selecting `run_mcp.sh` retains automatic incremental builds.

### Start and stop with SlateSync

Automatic start is off initially. Enabling **Start and stop automatically with
SlateSync** prepares and starts immediately and on future launches. Quitting or
disabling it stops the service and all sessions. Closing Settings keeps it alive.
Manual Stop preserves the next-launch preference and allows another Start.

Directory grants are optional for startup, connection, tool discovery and model
listing. Without grants, **all file reads and exports are denied**. Add the
required media/output directories and restart before using file tools. Model
requests require separate opt-in. Stop before editing paths, grants or consent.

### Add to Codex / Claude Code

Click **Add to Codex** or **Add to Claude Code**. If needed, the app first builds
and starts the helper, then runs the installed official CLI with separate argv:

```sh
codex mcp add slatesync -- /absolute/path/script/run_mcp.sh --connect /absolute/socket/path
claude mcp add --transport stdio --scope user slatesync -- /absolute/path/script/run_mcp.sh --connect /absolute/socket/path
```

Codex adds/updates only `slatesync`, preserving other servers. Claude Code treats
an identical user entry as already added and preserves a conflicting entry with
an actionable error. The UI reports the CLI result separately from service
state. Reconnect MCP or start a new client session after adding. Registration
means configuration is saved; it does not assert that an existing client session
has connected. Missing CLIs leave the service running and offer the copyable
managed configuration as a fallback. The app never installs a client for you.

The CLI commands and scope follow the official
[Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)
and [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp).
No client configuration is changed until its Add action is clicked; copying only
changes the clipboard. Build/client diagnostics are in `logs/mcp-build.log` and
`logs/mcp-client.log`; service diagnostics remain in `logs/mcp-service.log`, all
under SlateSync's settings directory. External processes remain disabled in
isolated UI fixtures and the App Store sandbox.

The app owns a broker (`--managed-socket PATH`). Each same-user connection gets
an independent stdio MCP process using the app-configured grants, with at most
eight sessions. Its private directory/socket use 0700/0600 permissions and an
exclusive lock prevents two app instances from replacing a live service. App
control-pipe EOF, SIGINT, and SIGTERM stop admission and cancel/drain sessions.
Before forwarding client data, the bridge verifies the connected broker's UID
using kernel peer credentials, rejecting another user's process even if it
occupies the expected socket path. Responses and progress notifications share
one complete-message writer so concurrent large replies remain valid JSON under
backpressure. Canceling a queued send removes it; a started frame finishes unless
the session disconnects. A partial write failure closes the session.
The bridge never starts a server on its own; a stopped service reports an error.

### Direct client-owned stdio

Requirements are the repository's Swift/macOS toolchain. From the repository:

```sh
./script/build_mcp.sh
```

The first build downloads the official MCP Swift SDK and its dependencies.
`MCP/Package.swift` pins SDK `0.11.0`; `MCP/Package.resolved` pins the dependency
graph independently of the app's offline package. Keep the generated executable
and SwiftPM resource bundles together. `script/run_mcp.sh` finds the Release
executable and the repository's canonical Paddle runner regardless of the
client's working directory. Rebuild after moving or updating the repository.

Example client configuration (replace the three absolute paths):

```json
{
  "mcpServers": {
    "slatesync": {
      "command": "/absolute/path/SlateSync-Swift/script/run_mcp.sh",
      "args": [
        "--allow-directory", "/absolute/path/shoot",
        "--allow-directory", "/absolute/path/exports",
        "--allow-model-requests"
      ]
    }
  }
}
```

`--allow-directory` is optional and repeatable. Without grants the server starts
but denies every file operation. Inputs, scan directories and new
exports must stay within these grants, including after resolving symlinks.
Grant only the material/output directories needed by the client.

The server reads the same local provider configuration as SlateSync. Configure
and verify a model in the app first; restart the MCP process after changing
global settings. Do not put API keys in client arguments or tool calls.
`--settings-directory /absolute/path` selects a separate settings/credential
root for isolated use. There is no credential-write tool.

Model requests are disabled unless `--allow-model-requests` is present. Enabling
it permits page images, OCR text and supplied prompt context to be sent to the
configured provider and can incur that provider's charges. Local CSV tools
remain usable without it. Merely starting the server makes no model request.

The official SDK release used here implements the initialization-based
`2025-11-25` MCP protocol. This integration does not claim the newer stateless
`2026-07-28` protocol. Clients must support the initialization handshake.
See the [official Swift SDK](https://github.com/modelcontextprotocol/swift-sdk/tree/0.11.0)
and [MCP compatibility rules](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).

## Tools

| Tool | Input | Result |
| --- | --- | --- |
| `slatesync_list_models` | none | Local provider/model catalog; no remote discovery or credentials |
| `slatesync_recognize` | `path`, optional `providerID`, `modelID`, `accuracyMode`, `customPrompt`, `slateCSVPath`, `resolve` | Records usable by merge tools, warnings, OCR summary and token usage |
| `slatesync_import_slate_csv` | UTF-8 CSV `path` | Local recognition records without model calls |
| `slatesync_scan_metadata` | `csvPath`, `directoryPath`, optional `edits` | All supported sidecars, warnings, missing keys and scan statistics |
| `slatesync_preview_merge` | `csvPath`, `records`, optional `metadata`, `edits`, `resolve`, `offset`, `limit` | Reconciliation summary and bounded pages of rows, warnings, statuses and changes |
| `slatesync_export_csv` | Merge inputs plus `outputPath`, optional `allowWarnings` | New CSV path and the same reconciliation summary |

All paths are absolute. `tools/list` is the complete machine-readable schema.
Records use `cardNumber`, `videoCode`, `scene`, `shot`, `take`, `takeStatus`
(`过`, `保`, `废条`, or null), and optional `reviewRequiredFields`.
Pass those review markers forward rather than silently removing them.
Metadata uses canonical `materialKey` such as `A:1:15`, `sensorFps` and `shootDay`.
CSV edits use zero-based `rowIndex`, `columnIndex` and a literal `value`.

The `resolve` object accepts the app's `fieldFormats` and `comments` settings.
Omitting it uses the current native workflow defaults, not an open GUI task's
settings. Example:

```json
{
  "fieldFormats": {"scene": "XXX", "shot": "XX", "take": "XX"},
  "comments": {"goodTake": "_OK", "holdTake": "_KP"}
}
```

## Recommended workflow

1. Recognize a PDF/image, or import a local slate CSV.
2. Optionally scan the material directory using the original Resolve CSV.
3. Pass records and scan `metadata` into `slatesync_preview_merge`.
4. Review incomplete/conflicting records, unmatched material, identity errors
   and automatic corrections. Update records or supply explicit cell edits.
5. Export to a **new filename**. If review issues remain, export returns
   `MCP_REVIEW_REQUIRED`; only a deliberate retry with `allowWarnings: true`
   proceeds. This does not bypass `CSV_NO_EXPORT`.

Preview does not require an exportable record. Export requires a nonempty
record list plus a complete matched record or a valid manual cell edit.
Independent FPS/date updates alone do not bypass that guard. Identity edits
participate in matching; other field edits override automatic backfill.
Encoding, BOM, separator and newline conventions are retained.

`offset`/`limit` page each diagnostic collection separately (default 0/50,
maximum limit 200). Totals distinguish each returned slice from the full merge.
Use subsequent offsets to inspect the remaining rows, statuses, changes and
warnings. Export always writes the full table, independent of the preview page.

Requests support MCP cancellation. Recognition forwards progress when a client
provides `_meta.progressToken`. EOF/SIGINT/SIGTERM cancel and drain active work.
Exports publish an atomically complete file and never replace an existing file.
Cancellation arriving after publication can leave the completed new file;
inspect it before retrying with another filename.

## Scope and limits

- Local stdio, optionally bridged over a same-user Unix socket; no listening
  network port, HTTP transport, or remote auth.
- PDF/image limit 20 MiB / 20 pages; CSV inputs 64 MiB; tool arguments 16 MiB.
- At most eight admitted tool calls per stdio session; recognition uses that
  session's configured global concurrency limit and page concurrency.
- Default sidecar support is Kinefinity `slate.txt`, as in the native app.
- Headless recognition does not reuse/save project-scoped Scenario Profiles or
  task history. It uses the shared default recognition pipeline and supplied
  settings. Desktop task editing is not exposed, avoiding a second autosave
  writer against an open GUI project.
- The MCP executable is an optional source-build product, not yet included in
  the notarized app/DMG. Keep the native release acceptance gate unchanged.

## Verification

```sh
swift test --package-path MCP
python3 -B script/tests/mcp_stdio_smoke.py \
  --binary MCP/.build/release/slatesync-mcp \
  --report /tmp/slatesync-mcp-stdio.json
python3 -B script/tests/mcp_stdio_smoke.py \
  --binary script/run_mcp.sh --managed \
  --report /tmp/slatesync-mcp-managed.json
```

Tests use disposable files and injected provider responses. The real stdio
smoke checks initialization, tools, structured errors, filesystem grants,
byte-exact CSV output, no-overwrite behavior and clean EOF exit. It never calls
a live provider. Managed-mode checks also cover two independent sessions, private
permissions, duplicate-start rejection, app-control EOF/SIGTERM cleanup, stopped
connections, stale sockets and preservation of ordinary endpoint files.
`.github/workflows/mcp.yml` retains these logs and both protocol transcripts on
the macOS runner. No app or foreground UI test is started by these checks.
