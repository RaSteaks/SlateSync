// Electron native file dialogs (save CSV, pick media/library directories).
//
// The sandboxed renderer cannot show native dialogs itself; the main process
// exposes these through IPC so the UI can ask the user for a save path or a
// material root directory.
import { dialog } from "electron";
import { writeFile } from "node:fs/promises";

export function createFileDialogs(getMainWindow) {
  return {
    async saveFile(defaultFilename, data) {
      const window = getMainWindow();
      if (!window) throw new Error("主窗口不可用");

      const result = await dialog.showSaveDialog(window, {
        defaultPath: defaultFilename,
        filters: [{ name: "CSV 文件", extensions: ["csv"] }],
      });

      if (result.canceled || !result.filePath) {
        return { saved: false };
      }

      // Accept binary structured-clone payloads without routing through a
      // memory-heavy plain number array; keep arrays for legacy saved clients.
      const buffer = ArrayBuffer.isView(data)
        ? Buffer.from(data.buffer, data.byteOffset, data.byteLength)
        : Buffer.from(data);
      await writeFile(result.filePath, buffer);
      return { saved: true, filePath: result.filePath };
    },

    async selectDirectory() {
      const window = getMainWindow();
      if (!window) throw new Error("主窗口不可用");

      const result = await dialog.showOpenDialog(window, {
        properties: ["openDirectory"],
        title: "选择素材根目录",
      });

      if (result.canceled || !result.filePaths.length) {
        return null;
      }

      const dirPath = result.filePaths[0];
      const dirName = dirPath.split("/").filter(Boolean).pop() || dirPath;
      return { dirPath, dirName };
    },

    async selectProjectLibrary(defaultPath) {
      const window = getMainWindow();
      if (!window) throw new Error("主窗口不可用");

      const result = await dialog.showOpenDialog(window, {
        defaultPath,
        properties: ["openDirectory"],
        title: "导入 SlateSync Project Library",
        buttonLabel: "导入并切换",
      });
      return result.canceled || !result.filePaths.length
        ? null
        : result.filePaths[0];
    },

    async selectLibraryStorageDirectory(defaultPath) {
      const window = getMainWindow();
      if (!window) throw new Error("主窗口不可用");

      const result = await dialog.showOpenDialog(window, {
        defaultPath,
        properties: ["openDirectory", "createDirectory"],
        title: "选择 Project Library 存储位置",
        buttonLabel: "复制到这里",
      });
      return result.canceled || !result.filePaths.length
        ? null
        : result.filePaths[0];
    },

    async selectLibraryExportPath(defaultPath) {
      const window = getMainWindow();
      if (!window) throw new Error("主窗口不可用");

      const result = await dialog.showSaveDialog(window, {
        defaultPath,
        title: "导出 SlateSync Project Library",
        buttonLabel: "导出",
        filters: [
          { name: "SlateSync Project Library", extensions: ["slatesync-library"] },
        ],
      });
      return result.canceled || !result.filePath ? null : result.filePath;
    },
  };
}
