# SlateSync Electron 桌面应用改造计划

## 总体架构

```
Electron 模式：
  Renderer (Chromium) ──IPC──► Main Process (Node.js) ──► lib/*.mjs
  public/*.js                  electron/main.mjs          lib/ocr/*.mjs
  electron-bridge.js           electron/ipc-handlers.mjs  scripts/

Web 模式（保留不变）：
  Browser ──HTTP──► server.mjs ──► lib/*.mjs
```

核心思路：前端通过 `window.electronAPI` 检测运行模式，API 调用透明切换 `fetch`（Web）和 `ipcRenderer.invoke`（Electron）。

---

## 阶段 0：环境准备（0.5 天）

- `npm install --save-dev electron electron-builder`
- `package.json` 新增 scripts：`electron:dev`、`electron:build`、`electron:build:dir`
- 验证 `npx electron electron/main.mjs` 能弹出空白窗口

## 阶段 1：Electron Main Process 骨架（1.5 天）

**新增文件：**

| 文件 | 行数 | 用途 |
|------|------|------|
| `electron/main.mjs` | ~120 | Main Process 入口：创建 BrowserWindow、加载 .env、注册 IPC、macOS 窗口生命周期 |
| `electron/preload.cjs` | ~40 | Preload Script：通过 `contextBridge.exposeInMainWorld("electronAPI", {...})` 暴露安全 IPC API |
| `electron/ipc-handlers.mjs` | ~200 | IPC Handler 注册：实现 `get-config`、`save-provider-key`、`get-models`、`recognize`、`save-file`、`select-directory`、`scan-slate-directory` 7 个 handler |
| `electron/env-loader.mjs` | ~50 | 从 server.mjs 提取 `loadLocalEnv()`、`createTaskLimiter()` 等共享函数 |

**关键设计：**
- Main Process 用 ESM（`.mjs`），Preload 必须用 CJS（`.cjs`）因 Electron 沙箱限制
- `recognize` handler 中 `onProgress` 回调通过 `event.sender.send("recognition-progress", data)` 推送进度
- 进度事件格式与 NDJSON 流中的 `{type:"progress", phase, percent, message, ...}` 完全一致
- 复用 `lib/ai-client.mjs` 的 `recognizeSlate()`、`lib/config.mjs` 的 `publicConfig()` 等核心函数

**修改文件：**
- `package.json`：添加 scripts 和 devDependencies
- `.gitignore`：添加 `dist/`、`out/`

## 阶段 2：前端适配层（2 天）

**新增文件：**

| 文件 | 行数 | 用途 |
|------|------|------|
| `public/electron-bridge.js` | ~120 | 前端桥接层：检测 `window.electronAPI`，导出统一的 `fetchConfig()`、`saveProviderKey()`、`fetchModels()`、`recognizeStream()`、`downloadFile()`、`pickDirectory()` 接口 |
| `public/electron-slate-directory.js` | ~60 | Electron 目录扫描适配：调用主进程扫描替代前端 File System Access API |

**`public/app.js` 6 个改动点：**

1. `loadConfig()`（L145-148）：`fetch("/api/config")` → `fetchConfig()`（桥接层）
2. `saveProviderKey()`（L519-543）：`fetch("/api/provider-key")` → `saveProviderKeyApi()`
3. `loadProviderModels()`（L589-633）：`fetch("/api/models?...")` → `fetchModelsApi()`
4. `recognize()`（L1125-1153）：`fetch("/api/recognize-stream")` + NDJSON → `recognizeStreamApi(body, onProgress)`
5. `downloadCsv()`（L1479-1486）：`Blob` + `a.download` → `downloadFileApi(bytes, filename)`
6. `selectSlateDirectory()`（L191-223）：`showDirectoryPicker()` → `pickDirectoryApi()` + 主进程扫描

**`public/index.html` 改动：**
- 添加 CSP `<meta>` 标签（Electron `file://` 协议下无 HTTP header）

## 阶段 3：Electron 特有功能（2 天）

**新增文件：**

| 文件 | 行数 | 用途 |
|------|------|------|
| `electron/file-dialogs.mjs` | ~60 | `dialog.showSaveDialog()` + `fs.writeFile` 保存 CSV；`dialog.showOpenDialog({openDirectory})` 选择目录 |
| `electron/slate-scanner.mjs` | ~150 | 主进程递归扫描 slate.txt：复用 `resolve-csv.js` 中的 `extractCombinedMaterialKey` 和 `parseSlateMetadataText`，实现与前端 `scanSlateDirectory()` 相同的剪枝/深度限制逻辑 |
| `electron/key-store.mjs` | ~50 | API Key 持久化到 `app.getPath("userData")/provider-keys.json`，文件权限 `0o600` |

## 阶段 4：OCR 子进程路径适配（1 天）

**问题：** `lib/ocr/*.mjs` 通过 `join(MODULE_DIR, "..", "..")` 定位项目根目录，Electron 打包后路径变化。

**方案：**
- `lib/ocr/paddleocr.mjs` 和 `lib/ocr/vision.mjs` 各改 1 行：`PROJECT_DIR` 优先使用 `process.env.SLATESYNC_PROJECT_DIR`
- `electron/main.mjs` 启动时设置 `SLATESYNC_PROJECT_DIR`（开发模式 = 项目根目录，打包模式 = `process.resourcesPath/app`）
- `PADDLE_PDX_CACHE_HOME` 设为 `app.getPath("userData")/paddlex`

## 阶段 5：pdf.js 资源适配（0.5 天）

**问题：** `app.js` 用绝对路径 `/vendor/pdfjs/pdf.mjs` 加载 pdf.js，Electron `file://` 协议下无法解析。

**方案：**
- 新增 `scripts/copy-pdfjs.mjs`：`postinstall` 时将 `node_modules/pdfjs-dist/build/pdf.mjs` 和 `pdf.worker.mjs` 复制到 `public/vendor/pdfjs/`
- `app.js` 改 2 行：`/vendor/pdfjs/` → `./vendor/pdfjs/`
- Web 模式继续由 `server.mjs` 的 `/vendor/pdfjs/` 路由服务（不受影响）

## 阶段 6：安全加固（0.5 天）

- `BrowserWindow` 配置：`contextIsolation: true`、`nodeIntegration: false`、`sandbox: true`
- 禁止导航到外部 URL：`setWindowOpenHandler(() => ({action:"deny"}))`
- `will-navigate` 事件拦截非 `file://` 导航
- `index.html` 添加 CSP meta 标签

## 阶段 7：打包与分发（1 天）

**新增文件：**

| 文件 | 用途 |
|------|------|
| `electron-builder.yml` | electron-builder 配置：appId、mac target（dmg+zip，arm64+x64）、files、extraResources、asarUnpack |
| `build/entitlements.mac.plist` | macOS 权限：网络客户端、用户文件读写、禁用库验证（Swift 二进制） |

**关键配置：**
- `asarUnpack: ["scripts/**/*", "bin/**/*"]` — OCR 子进程文件不打入 asar
- `extraResources` — 将 `scripts/`、`bin/`、`slatesync.config.json` 复制到 `resources/app/`
- 不打包 `.env`（敏感信息），用户通过 UI 配置 API Key

## 阶段 8：测试与文档（1.5 天）

**新增测试文件：**

| 文件 | 说明 |
|------|------|
| `test/electron-bridge.test.mjs` | Mock `window.electronAPI`，验证 Web/Electron 模式行为 |
| `test/electron-ipc.test.mjs` | 直接调用 IPC handler 函数，验证业务逻辑 |
| `test/electron-key-store.test.mjs` | 临时目录测试 Key 持久化读写 |

**更新：**
- `package.json` 的 `check` script 新增 electron/*.mjs 和 public/electron-*.js 的语法检查
- `README.md` 添加 Electron 模式使用说明

---

## 文件变更汇总

**新增 15 个文件**（约 1100 行新代码）

**修改 7 个文件：**

| 文件 | 改动量 | 说明 |
|------|--------|------|
| `package.json` | ~15 行 | scripts + devDependencies |
| `public/app.js` | ~60 行 | 6 个 API 调用点改为桥接层 |
| `public/index.html` | ~5 行 | CSP meta 标签 |
| `lib/ocr/paddleocr.mjs` | 1 行 | `SLATESYNC_PROJECT_DIR` 支持 |
| `lib/ocr/vision.mjs` | 1 行 | 同上 |
| `.gitignore` | ~3 行 | `dist/`、`public/vendor/` |
| `README.md` | ~40 行 | Electron 模式说明 |

**不修改的核心文件：** `server.mjs`、`lib/ai-client.mjs`、`lib/config.mjs`、`lib/model-discovery.mjs`、`lib/schema.mjs`、`public/resolve-csv.js`、`public/image-preprocess.js`、`public/workflow-state.js`、`public/styles.css` 等。

---

## 风险与注意事项

1. **Preload 格式限制**：sandbox 模式下 preload 必须是 CJS，不能用 ESM import
2. **IPC 数据大小**：识别请求含大量 Base64 图像（最大 80MB），需验证 IPC 传输性能；如遇瓶颈可改为临时文件路径传递
3. **resolve-csv.js Node 兼容性**：主进程目录扫描需要导入前端模块中的纯函数，Node 20+ 内置 TextDecoder，应该兼容
4. **Vision OCR 签名**：未签名的 Mach-O 二进制可能被 Gatekeeper 阻止，需 entitlements 或 ad-hoc 签名
5. **PaddleOCR Python 环境**：打包应用不含 `.venv-paddleocr`，用户需自行安装或仅用 Vision OCR
6. **双模式同步**：新增 API 端点需同时更新 `server.mjs`、`electron/ipc-handlers.mjs`、`public/electron-bridge.js`

## 总工作量：约 10.5 个工作日