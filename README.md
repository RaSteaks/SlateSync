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
| PDF、JPEG、PNG、WebP 场记单 | 本地逐页栅格化、OCR evidence、视觉模型识别、字段校验、版式 Profile 复用 | 保留原格式的 Resolve CSV |
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
```

启动应用后进入“全局设置”，即可填写 API Key、接口地址、运行参数和 OCR 配置，普通桌面用户不需要寻找或编辑 `.env`。完整变量模板仍见 [.env.example](./.env.example)；开发、CI 或需要预置环境的场景可以选择复制它：

```bash
cp .env.example .env
```

API Key 也可以直接在“全局设置”中保存；保存后不会回显。

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

修改 Main 或 Preload 后必须完全退出旧 Electron 进程再重启；Renderer HMR 只作用于
`src/renderer`，仅刷新窗口不会重新加载 Preload。遇到“版本不一致”提示时，重新执行
`npm run electron:dev:modern` 即可让启动钩子重新构建 Main/Preload。

## 工作流

```text
导入场记单
    ↓
PDF 逐页栅格化 → 本地 Vision/PaddleOCR → OCR evidence + 页面图片 → 视觉模型 → 字段归一化与版式匹配
    ↓
载入 Resolve CSV + 可选扫描 slate.txt
    ↓
条号对账 / 场镜次序检查 / 完整性告警
    ↓
回填预览 → 人工校对 → 导出 CSV
```

| 阶段 | SlateSync 会做什么 |
| --- | --- |
| 识别 | PDF 先在本地逐页栅格化；本地 OCR 提取文字、置信度和坐标后，与页面图片一起交给视觉模型抽取场、镜、次和条次状态。 |
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
| `VISIONOCR_REQUIRED` | Vision OCR 必需模式；失败时停止识别 |
| `PADDLEOCR_REQUIRED` | PaddleOCR 必需模式；失败时停止识别 |

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

### 全局设置与配置优先级

“全局设置”覆盖 `.env.example` 中除 API Key 外的全部可配置项，包括服务商 Base URL、OpenAI 兼容接口参数、模型请求并发/超时、Vision OCR、PaddleOCR 和模型缓存路径。API Key 使用同一页面的独立凭据入口。

配置按以下优先级生效：普通配置为“全局设置覆盖 > 操作系统进程环境变量 > `.env` > 内置默认值”；通过页面保存的 Provider API Key 则为“本机凭据 > 操作系统进程环境变量 > `.env`”，并由 Main 进程单独管理。

普通配置存放在 Electron 的 `<userData>/global-config.json`：带版本号、只保存已校验的非敏感覆盖项、写入采用临时文件加原子重命名，并使用 `0600` 权限。Provider 密钥仍放在独立的 `<userData>/provider-keys.json`，不会混入全局配置、Project Library、任务数据或 Renderer IPC 的普通配置 DTO。点击“恢复环境默认”只删除全局覆盖，之后回退到 `.env` 和内置默认值。

全局配置按机器用户保存，不随 Project Library 导入/导出；因此同一台机器的多个项目共享它，而项目包仍可独立迁移。若未来需要更高等级的凭据保护，可将现有独立密钥文件迁移到 macOS Keychain/系统安全存储，普通配置文件无需改变。

#### 多自定义 OpenAI 兼容接口

全局设置的“自定义模型接口”支持任意数量的连接，每条记录使用
`openai-compatible:<uuid>` 稳定 ID，可自定义名称、Base URL、Chat Completions/Responses、
JSON 模式、图片细节和多个手动模型 ID。`global-config.json` 已升级为 v2；v1 或早期
direct-object 文件会兼容读取并在下一次保存时写入 v2。删除接口只清理该接口的 Key、
发现和能力缓存，不改写项目数据库，旧项目引用会提示重新选择。

模型检测先读取 `/models`。明确声明图像输入+文本输出、维护模型族推断或已验证的模型
进入“可用于识别”；未声明 modality 的模型进入“待验证”，由用户选择后使用不含项目数据
的合成图片与最小 JSON 探针验证。探针并发上限为 2、单模型超时 30 秒，支持进度、取消和
逐项重试。精度/性价比只展示带来源和日期的参考评级；未知模型显示“精度暂无数据”“价格未知”。

## 数据与安全

- 默认 Project Library 位于 macOS Application Support 下的 `Local SlateSync Library`。
- Project Library 使用 SQLite 保存任务、诊断、项目设置和场记结构 Profile。
- 旧版本 JSON 数据会按兼容规则迁移，并保留兼容快照。
- API Key 只由 Main 进程读取；Renderer 不直接访问密钥或 Node.js 能力。
- PDF 原始字节只用于本地逐页栅格化；模型请求统一只发送页面图片与本地 OCR evidence，不发送原始 PDF 文件。
- OCR 引擎未启用、不可用、超时、失败或没有文字块时，会显示“本地 OCR 不可用，已改用页面图片直接识别；识别精度可能下降。”并降级为页面图片识别；设置为必需时则停止识别。
- 历史客户端提交原始 `pdfDataUrl` 会在 Main 模型调用前收到 400；旧 direct-PDF 路由已退役，不能通过环境变量重新启用。
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

本地源码打包会根据宿主系统选择目标：macOS 只生成 macOS DMG/ZIP（arm64 与 x64），
Windows 只生成 Windows NSIS x64 包；不会生成 Windows ia32/x86 包。Linux 主机以及
跨平台打包参数会被直接拒绝。GitHub Release 工作流目前仍只发布 macOS。

构建 Modern 产物：

```bash
npm run build:modern
```

生成当前宿主平台的未签名应用目录：

```bash
# macOS
CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir

# Windows
npm run electron:build:dir
```

生成当前宿主平台的安装包：

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
