<div align="center">

<img src="./assets/slatesync-icon-v5.png" alt="SlateSync 图标" width="112" />

# SlateSync

**场记单识别 · 结构校对 · Resolve CSV 回填**

识别 PDF 或图片场记单，复核场、镜、次及条次状态，
再将确认后的结果写回 DaVinci Resolve CSV。

[![Node.js](https://img.shields.io/badge/Node.js-%E2%89%A5%2020.19-339933?logo=nodedotjs&logoColor=white)](https://nodejs.org/)
[![Platform](https://img.shields.io/badge/Platform-macOS-111827?logo=apple&logoColor=white)](https://github.com/RaSteaks/SlateSync)
[![Electron](https://img.shields.io/badge/Desktop-Electron-47848F?logo=electron&logoColor=white)](https://www.electronjs.org/)
[![License](https://img.shields.io/badge/License-MIT-2563eb)](./LICENSE)

<br />

[快速开始](#快速开始) · [工作流](#工作流) · [架构](#架构) · [开发与验证](#开发与验证)

</div>

---

## 一眼了解

| 输入 | 处理 | 输出 |
| --- | --- | --- |
| PDF、JPEG、PNG、WebP 场记单 | 本地 OCR、视觉模型识别、字段校验、版式 Profile 复用 | 保留原格式的 Resolve CSV |
| Resolve CSV、素材目录 | 条号对账、场镜次序检查、`slate.txt` 元数据读取 | 可预览、可校对、可导出的回填结果 |

> [!NOTE]
> SlateSync 是本地 Electron 桌面应用。未配置模型密钥时，仍可执行本地 CSV 合并；发送给模型的内容取决于用户选择的识别服务。

## 核心能力

| 识别与理解 | 校对与回填 | 项目与安全 |
| --- | --- | --- |
| 支持 macOS Vision OCR、PaddleOCR，以及 OpenAI、OpenRouter、Token Plan、DashScope 和 OpenAI 兼容视觉模型。 | 导入 Resolve CSV，校验条号、场镜次序和识别完整性，确认后再导出。 | Project Library 使用 SQLite 保存项目、任务、诊断和场记结构 Profile。 |
| 根据 OCR 表头、坐标和页面版式学习并复用场记结构 Profile。 | 读取素材目录中的 `slate.txt`，补充 `Camera FPS` 和 `Shoot Day`。 | API Key 只由 Main 进程读取；Renderer 不直接访问密钥或 Node.js 能力。 |
| 单个 PDF 最多 20 页，支持逐页准备和识别。 | 保留原 CSV 的编码、换行和未匹配字段，仅更新匹配到的字段。 | Project Library 可导入、导出或更换存储位置。 |

## 快速开始

### 1. 环境要求

- macOS：开发和当前打包目标平台。
- Node.js `>=20.19` 与 npm。
- Vision OCR：Xcode Command Line Tools 和 `swiftc`。
- PaddleOCR：Python 3 和可用的 `venv` 模块（可选）。

### 2. 安装依赖

```bash
git clone https://github.com/RaSteaks/SlateSync.git
cd SlateSync
npm ci
cp .env.example .env
```

在 `.env` 中至少配置一个模型服务商的密钥。完整模板见 [.env.example](./.env.example)。

如果需要 PaddleOCR，再执行：

```bash
npm run ocr:setup
npm run ocr:check
```

### 3. 启动应用

```bash
npm start
```

`npm start` 会构建 Main/Preload、重建 Electron 原生依赖，然后启动 Vite Renderer 开发服务器和 Electron。修改 `src/renderer` 后会通过 HMR 自动更新窗口；也可以显式启动 Modern Renderer：

```bash
npm run electron:dev:modern
```

修改 Main 或 Preload 后仍需要重启应用；Renderer HMR 只作用于 `src/renderer`。

## 工作流

```text
导入场记单
    ↓
页面准备 → 本地 OCR / 视觉模型识别 → 字段归一化与版式匹配
    ↓
载入 Resolve CSV + 可选扫描 slate.txt
    ↓
条号对账 / 场镜次序检查 / 完整性告警
    ↓
回填预览 → 人工校对 → 导出 CSV
```

| 阶段 | SlateSync 会做什么 |
| --- | --- |
| 识别 | 读取 PDF 或图片，结合 OCR 与视觉模型抽取场、镜、次和条次状态。 |
| 学习 | 从 OCR 表头、坐标和版式生成场记结构 Profile，并在相似任务中复用。 |
| 对账 | 载入 Resolve CSV，检查条号缺失、场镜次序异常和识别完整性。 |
| 回填 | 只更新匹配到的素材与允许写入的字段，保留原 CSV 的其他内容。 |

### 支持的识别方式

| 方式 | 位置 | 适合场景 |
| --- | --- | --- |
| macOS Vision OCR | 本地 | macOS 环境下的基础文字与坐标识别 |
| PaddleOCR | 本地，可选安装 | 需要额外 OCR 引擎或本地处理能力 |
| OpenAI / OpenRouter / Token Plan / DashScope | 云端 | 需要视觉模型理解复杂版式、中文或手写内容 |
| OpenAI 兼容视觉接口 | 按服务商配置 | 使用兼容 OpenAI 协议的模型服务 |

## 架构

```text
Electron Main
  ├─ Project Library / SQLite / 文件与配置访问
  ├─ IPC handlers
  └─ Preload → window.slateSync

Modern React Renderer（默认）
  ├─ Zustand 状态切片
  ├─ Project Library、Workspace、Settings、Recognition UI
  └─ CSV Worker / Preparation Worker

Legacy Renderer（受限回退路径）
  └─ public/index.html 与 public/app.js
```

- Main 进程是 SQLite、Project Library、密钥和文件系统的权威所有者。
- Renderer 只能通过 Preload 暴露的 `window.slateSync` 访问桌面能力。
- CSV 处理和 PDF/图片准备在 Worker 中执行，Renderer 只负责交互和状态投影。
- Modern Renderer 默认启动；显式指定 legacy 或 Modern 资源不可用时，才使用 Legacy Renderer 回退。

## 配置

工作流配置文件为 [slatesync.config.json](./slatesync.config.json)，可配置：

- 素材目录扫描深度；
- 场、镜、次的最小位数；
- `Comments` 中过条和保条的标记。

常用环境变量：

| 变量 | 作用 |
| --- | --- |
| `SLATESYNC_CONFIG_PATH` | 工作流配置文件路径 |
| `MODEL_REQUEST_TIMEOUT_MS` | 单次模型请求超时 |
| `MODEL_REQUEST_MAX_RETRIES` | 模型请求重试次数 |
| `MODEL_PAGE_CONCURRENCY` | 并行提交的页面数 |
| `MAX_CONCURRENT_RECOGNITIONS` | 并行识别任务数 |
| `VISIONOCR_ENABLED` | Vision OCR 开关 |
| `PADDLEOCR_ENABLED` | PaddleOCR 开关 |

### Resolve 字段回填

| Resolve 字段 | 数据来源 |
| --- | --- |
| `Scene` | 场记单中的场次 |
| `Shot` | 场记单中的镜 |
| `Take` | 场记单中的次 |
| `Comments` | 按配置写入过条、保条标记；其他情况为空 |
| `Camera FPS` | 素材目录 `slate.txt` 的 `Sensor FPS` |
| `Shoot Day` | 素材目录 `slate.txt` 的 `Shot Date` |

字段无法确认时不会被强行写入，必须人工校对。原 CSV 的编码、换行和未匹配字段保持不变。

## 数据与安全

- 默认 Project Library 位于 macOS Application Support 下的 `Local SlateSync Library`。
- Project Library 使用 SQLite 保存任务、诊断、项目设置和场记结构 Profile。
- 旧版本 JSON 数据会按兼容规则迁移，并保留兼容快照。
- API Key 只由 Main 进程读取；Renderer 不直接访问密钥或 Node.js 能力。
- PDF、图片、Resolve CSV 和素材目录默认在本地处理；发送给模型的内容取决于用户选择的识别服务。
- 不要将 `.env`、本地 Project Library、`data/` 或任何用户数据提交到 Git。

## 开发与验证

```bash
npm run check                 # JavaScript、Electron 和 Python 语法检查
npm run typecheck             # TypeScript 项目引用检查
npm test                      # Node 基线测试与 Modern 测试
npm run test:e2e              # Electron Playwright E2E
npm run test:native:abi       # Node/Electron 原生 ABI 生命周期检查
npm run validate:modern       # typecheck、Modern 测试和 Modern 构建
npm run build:storybook      # Storybook 构建
```

测试使用临时用户数据和临时 Project Library，不应指向个人 Library。

## 构建与打包

构建 Modern 产物：

```bash
npm run build:modern
```

生成未签名的 macOS 应用目录：

```bash
CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir
```

生成 DMG 和 ZIP：

```bash
npm run electron:build
```

输出目录为 `dist/`。签名、公证和发布需要单独配置 Apple 发布凭据。



## 限制

- 单个 PDF 最多 20 页，单个上传文件最大 20 MB。
- 当前输入格式为 PDF、JPEG、PNG 和 WebP。
- 无法确认的识别字段不会被强行写入，必须人工校对。
- 只有配置允许的条次标记或空值会写入 Resolve `Comments`。

## License

[MIT](./LICENSE)
