// Transition marker only. BrowserWindow loads out/preload/index.cjs directly:
// Electron's sandboxed Preload `require` supports selected built-ins but cannot
// load this repository's second local module. Keeping the typed bundle as the
// sole executable path avoids both disabling sandbox and duplicating a bridge.
