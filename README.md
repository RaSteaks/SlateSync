<div align="center">

<img src="./assets/slatesync-icon-v5.png" alt="SlateSync 图标" width="112" />

# SlateSync

**场记单识别 · 结构校对 · DaVinci Resolve CSV 回填**

将 PDF 或图片场记单转换为可校对的场、镜、次记录，结合素材元数据生成或回填 CSV。

[快速开始](#快速开始) · [使用流程](#使用流程) · [导出模板](#导出模板) · [开发与验证](#开发与验证) · [MIT License](./LICENSE)

</div>

## 功能

- **场记识别**：支持 PDF、JPEG、PNG、WebP，结合本地 OCR 和视觉模型提取场、镜、次及条次状态。
- **结构复用**：根据 OCR 表头、坐标和版式生成场记结构 Profile，在相似任务中复用。
- **人工校对**：检查条号缺失、场镜次序和识别完整性，在预览中修正后导出。
- **素材元数据**：读取 Kinefinity `slate.txt`、ARRI XML/ALE 及受支持的 QuickTime 元数据，补充帧率、拍摄日期等信息。
- **CSV 导出**：支持内置 Resolve 模板、自定义字段和导入后期提供的 CSV 样表；可回填已有素材清单，也可从场记记录生成表格。
- **项目管理**：在本地项目库中保存项目、任务、诊断与结构 Profile，支持归档、项目包导入导出及项目库迁移。

未配置模型密钥时，仍可载入场记 CSV 执行本地合并。PDF 和图片的视觉模型识别需要配置相应服务。

## 快速开始

### 环境要求

- Node.js `>=20.19` 与 npm。

- PaddleOCR 为可选组件，需要 Python 3.10+；首次安装环境和下载模型需要网络。

### 安装与启动

```bash
git clone https://github.com/RaSteaks/SlateSync.git
cd SlateSync
npm ci
npm start
```

`npm start` 会构建应用、重建 Electron 原生依赖，并启动 Vite 开发服务器和 Electron。
Renderer 修改支持热更新；修改 Main 或 Preload 后，需要完全退出应用并重新执行启动命令。

### 配置识别服务

打开“全局设置”，配置服务商、API Key 和模型。支持 OpenAI、OpenRouter、Token Plan、DashScope，以及自定义 OpenAI 兼容接口。

自定义接口可配置 Base URL、Chat Completions 或 Responses 协议及手动模型 ID。模型检测支持获取模型列表，并对待验证模型执行图片识别能力检查。

普通使用无需编辑 `.env`。开发或预置环境时，可参考 [.env.example](./.env.example)：

```bash
cp .env.example .env
```

### 本地 OCR

| 引擎 | 配置方式 |
| --- | --- |
| macOS Vision | 在“全局设置 → 本地 OCR”中选择；仅适用于 macOS。 |
| PaddleOCR | 点击“安装 PaddleOCR”，或填写已有 Python 环境路径并验证。 |

PaddleOCR 安装器会检查本机 Python、创建独立环境、安装依赖并保存验证通过的路径，支持进度查看、取消和重试。应用包不内置 Python 解释器或完整 PaddleOCR 环境。

macOS 开发环境也可使用：

```bash
npm run ocr:setup
npm run ocr:check
```

本地 OCR 用于提供文字与坐标证据，视觉模型负责结构化识别。OCR 不可用时可降级为页面图片识别；将引擎设为“必需”后，OCR 失败会停止识别。

## 使用流程

1. **创建或打开项目**：在项目设置中选择识别模型和导出模板。
2. **导入场记**：载入 PDF、图片进行识别，或载入已有场记 CSV 进行本地处理。
3. **核对记录**：检查场、镜、次、条次状态及缺失或冲突提示。
4. **补充素材信息**：载入 Resolve 素材 CSV，按需扫描素材目录中的元数据。
5. **预览并导出**：确认匹配关系、列配置与单元格内容，导出 CSV。

PDF 会先在本地逐页转换为图片，再将页面图片和本地 OCR 证据发送给所选视觉模型；不会向模型发送原始 PDF 文件。

输入限制：单个文件最大 **20 MB**，单个 PDF 最多 **20 页**。识别结果需要人工复核。

## 导出模板

在“项目设置 → 导出配置”中管理项目模板，修改后点击“保存项目设置”生效。

| 方式 | 用途 |
| --- | --- |
| 内置 Resolve CSV | 使用预设的素材匹配列与元数据字段；内置模板只读，可复制为自定义模板。 |
| 自定义模板 | 配置字段、列顺序、表头、文件名规则、编码、分隔符、BOM 和换行。 |
| 导入 CSV 模板 | 提取后期样表的列结构和文件格式，不将样表中的素材行带入新任务。 |

模板库支持新建、另存为、重命名和删除。导入样表最大 5 MB、最多 256 列，也支持只有表头的 CSV。

内置 Resolve 模板包含 `File Name`、`Start TC`、`End TC`、`Reel Name`、`Clip Directory` 五项素材匹配列，默认启用 `Scene`、`Shot`、`Take` 和 `Comments`，可选择其他文本字段。没有素材清单时，可在预览中补齐素材身份；导出前必须填写 `File Name`。

`Comments` 的写入取决于导出配置：内置 Resolve 模板使用文字备注；原有回填流程可按配置写入过条、保条标记。已有 CSV 回填会保留未匹配素材和未修改字段，输出编码、换行及列集合以当前导出配置为准。

字段说明、素材匹配和接收端设置见 [Resolve 元数据模板说明](./docs/resolve-metadata-template.md)。内置模板是项目实现的适配器，实际交付前应在目标 Resolve 版本中用少量素材检查导入结果。

## 项目与数据

项目库默认位于 macOS Application Support 下的 `Local SlateSync Library`，使用 SQLite 保存项目数据，可导入、导出或更换存储位置。

在项目卡片的“项目设置 → 项目包”中，可将单个项目导出为 `.slatesync-project` 目录包。项目包包含任务、诊断、结构 Profile、项目设置及任务中已保存的图片和 CSV 数据。

导入项目包会创建新项目，不覆盖原项目；同名项目可以并存，归档状态会保留。传输前需等待自动保存或识别等写入操作完成。迁移时应复制完整目录包。

全局配置、API Key、OCR 环境和日志不随项目包迁移。更换机器后，需要重新配置识别服务和本地 OCR。

## 配置与隐私

- “全局设置”管理服务商接口、运行参数、OCR 和缓存路径，同一机器用户的项目共享这些设置。
- 普通配置优先级为：全局设置覆盖 → 进程环境变量 → `.env` → 内置默认值。
- Provider API Key 优先使用页面保存的本机凭据，其次为进程环境变量和 `.env`；密钥由 Main 进程管理，不向 Renderer 回显。
- 普通设置与密钥分别保存在 Electron 用户数据目录的 `global-config.json` 和 `provider-keys.json`。
- [slatesync.config.json](./slatesync.config.json) 提供素材扫描深度、场镜次补位和条次标记配置，可通过 `SLATESYNC_CONFIG_PATH` 指定其他文件。
- 使用远程识别服务时，页面图片与 OCR 证据会发送到所配置的服务端。
- `.env`、本地项目库和用户数据不应提交到版本库。

## 开发与验证

应用采用 Electron Main / Preload、React Renderer 和 Zustand。Renderer 通过 `window.slateSync` 调用桌面能力；存储 Worker 处理 SQLite 与项目传输，CSV 和页面准备由独立 Worker 处理。

| 目录 | 内容 |
| --- | --- |
| `src/main`、`electron` | 主进程入口、IPC、文件与环境管理 |
| `src/preload`、`src/shared` | 桌面桥接、共享类型与契约 |
| `src/renderer` | React 界面、状态与 Worker |
| `lib` | 识别、配置、项目库与存储逻辑 |
| `public` | 共享 CSV/元数据处理模块及 Legacy 回退界面 |
| `scripts`、`test`、`test-support` | 构建工具与测试 |

在 macOS 的全新检出中，运行存储测试前先生成本地加密桥接（`npm start` 或 `npm run build:modern` 也会生成）：

```bash
node scripts/build-local-encryption.mjs
```

常用检查命令：

```bash
npm run check             # JavaScript 与 Python 语法检查
npm run typecheck         # TypeScript 检查
npm test                  # Node 与 Modern Renderer 测试
npm run test:e2e          # Electron Playwright 测试
npm run test:native:abi   # Node/Electron 原生依赖生命周期检查
npm run validate:modern  # 类型检查、Modern 测试与构建
npm run build:storybook  # 组件文档构建
```

测试应使用临时用户数据和临时项目库。

## 构建与打包

```bash
npm run build:modern     # 构建 Main、Preload 和 Renderer
npm run electron:build   # 生成当前宿主平台的安装包
```

macOS 生成 arm64/x64 DMG 和 ZIP；Windows 生成 x64 NSIS 安装包。当前打包脚本不支持 Linux 或跨平台打包。

仅生成应用目录用于本地验证：

```bash
# macOS：不自动查找签名身份
CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir

# Windows
npm run electron:build:dir
```


## 许可证

[MIT](./LICENSE)
