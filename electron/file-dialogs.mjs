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

      const buffer = Buffer.from(data);
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
  };
}
