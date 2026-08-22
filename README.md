<div align="center">

# SlateSync

**场记单识别与 DaVinci Resolve CSV 自动回填工具**

[![Node.js](https://img.shields.io/badge/Node.js-%E2%89%A5%2020.19-339933?logo=nodedotjs&logoColor=white)](https://nodejs.org/)
![Platform](https://img.shields.io/badge/运行-Electron-2563eb?logo=electron&logoColor=white)
![OCR](https://img.shields.io/badge/OCR-Vision%20%7C%20PaddleOCR-7c3aed)

识别 PDF 或图片场记单，校对后将场、镜、次和条次状态写回 Resolve CSV。

</div>

---

## 功能

- 识别 PDF、JPEG、PNG、WebP 场记单，最多 20 页，预览区支持逐页滚动核对。
- 结合本地 OCR 与云端多模态模型，提高中文、数字和手写内容的识别率。
- 支持 OpenAI、OpenRouter、阿里云 Token Plan、DashScope 和 OpenAI 兼容接口。
- 自动从 OCR 表头、坐标和页面形状学习场记结构 Profile；相似版式可在项目内跨任务复用。
- 自动回填 Resolve 的 `Scene`、`Shot`、`Take`、`Comments`。
- 从素材目录中的 `slate.txt` 补充 `Camera FPS` 和 `Shoot Day`。
- 条号断档、次序异常自动告警，并在回填预览中标红提示。
- 识别任务、诊断会话和场记结构统一保存到 SQLite，可在多个任务之间切换与恢复。
- 无需 API Key 即可在本地合并“场记系统 CSV + Resolve CSV”。

## 项目架构与实现

```text
SlateSync/
├── public/                 Electron renderer、文件预览和 CSV 编辑
├── electron/               Electron 主进程、IPC、文件对话框和本地扫描
├── lib/                    识别、模型路由、OCR、CSV、配置和数据存储
├── scripts/                Vision OCR、PaddleOCR 和构建辅助脚本
├── test/                   Node.js 单元测试和集成测试
├── slatesync.config.json   工作流配置
└── electron-builder.yml    Electron 打包配置
```

核心处理流程：

```text
PDF/图片 → 页面图像预览 → 本地 OCR → 多模态模型识别
        → 字段归一化与序列校验 → Profile 匹配
        → SQLite 任务保存 → Resolve CSV 回填预览 → 下载 CSV
```

- `public/` 负责 Electron renderer 的文件预览、任务状态和 CSV 预览编辑。
- `electron/main.mjs` 负责桌面窗口、配置、密钥、SQLite、文件对话框和 IPC；渲染器通过 `preload.cjs` 使用受限 API。
- `lib/ai-client.mjs` 统一不同模型供应商的请求、结构化输出和错误处理。
- `lib/ocr/` 将 Vision OCR、PaddleOCR 规范化为统一的文字、置信度和坐标证据。
- `lib/scenario/` 学习、匹配和持久化场记结构 Profile。
- `lib/sqlite-store.mjs`、`lib/task-store.mjs` 和 `lib/diagnostics.mjs` 保存任务、诊断和结构数据。
- `scripts/vision_ocr.swift` 通过 Apple Vision 在本机运行 OCR；Node 端会在 macOS 工具链可用时准备二进制。

## 环境要求

基础要求：

- Node.js **20.19 或更高版本**，并自带 npm。
- AI 识别至少配置一个支持的 API Key。

可选要求：

- PaddleOCR：Python 3，并支持创建 `venv`。
- Electron 开发与编译：macOS；使用 Vision OCR 时需要 Xcode Command Line Tools。

> 只使用本地 CSV 合并时，不需要 API Key，也不需要安装 OCR。

## 安装与启动

### Electron 桌面版（macOS）

克隆项目并安装锁定版本的依赖：

```bash
git clone https://github.com/RaSteaks/SlateSync.git
cd SlateSync
npm ci
cp .env.example .env
```

在 `.env` 中至少填写一个 API Key，例如：

```dotenv
OPENAI_API_KEY=sk-...
# 或
OPENROUTER_API_KEY=sk-or-v1-...
```

需要 PaddleOCR 时再执行：

```bash
npm run ocr:setup
npm run ocr:check
```

启动 Electron 应用：

```bash
npm start
```

API Key 可以写入 `.env`，也可以在应用界面中保存。macOS 会优先使用本地 Vision OCR；如需 PaddleOCR，可额外执行 `npm run ocr:setup`。

`npm start`、`npm run dev` 和 `npm run electron:dev` 都会先按当前 Electron ABI 强制重建 `better-sqlite3`，再启动未打包的源码环境。仓库默认不包含自动重载器；修改 renderer 后可在窗口中按 `⌘R` 刷新，修改主进程或 preload 后需要重新启动。

当前重构中的 React Renderer 可用 `npm run electron:dev:modern` 单独启动。它与 legacy Renderer 不会同时写入同一个窗口；正式启动仍保持 legacy，直到连续 IP-03—08 完成集成与最终审核。

桌面版默认在 macOS 的 `~/Library/Application Support/Local SlateSync Library.slatesync-library` 创建本地 Project Library。项目库首页支持：

- 导出完整 `.slatesync-library` 可移植目录；SQLite 数据库通过一致性备份写入导出包。
- 导入并连接已有 Project Library，校验成功后自动重启应用。
- 选择新的存储目录；当前 Library 会复制到新位置后切换，原位置的数据保持不变。

当前 Library 的绝对路径显示在项目库首页。自定义路径保存在机器级 `settings.json`，不会写入任何项目数据库。

## 编译与打包

当前 `electron-builder.yml` 配置输出 macOS arm64 与 x64 的 DMG、ZIP。

先准备 Vision OCR 二进制，再检查、测试并打包：

```bash
npm ci
xcode-select --install
mkdir -p bin
xcrun swiftc -O -o bin/vision-ocr scripts/vision_ocr.swift
npm run check
npm test
npm run electron:build
```

构建结果位于 `dist/`。只生成未打包应用目录时使用：

```bash
CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir
```

这是当前重构 Gate 的本地验收命令，不需要 Apple Development Key，也不执行
签名、公证或发布。正式对外发布仍使用受保护的 release 流水线和独立凭据。

打包和开发模式使用同一套图标资源：`electron-builder.yml` 从 `build/slatesync.icon` 读取 macOS 应用图标；开发模式的 Dock 和窗口图标读取该 `.icon` 容器中的 `build/slatesync.icon/Assets/icon.png`。`assets/` 下的历史图标版本不会被 Electron 自动使用。

> 发布给其他用户前，还需要配置 Apple Developer 代码签名与公证；仓库默认构建不包含发布证书。

## 使用流程

### AI 识别

1. 上传场记单（多页 PDF 会在预览区逐页展示），可选加载场记系统 CSV 作为辅助数据。
2. 选择 API、模型、识别模式和场记结构。首次使用可保持“自动识别并学习版式”，开始识别。
3. 载入 Resolve CSV；需要时选择素材目录扫描 `slate.txt`。
4. 根据警告清单与回填预览中的标红行进行校对，然后下载 CSV。

| 识别模式 | 行为 | 建议用途 |
| --- | --- | --- |
| 精确 | 并行执行主识别与核心字段查漏，冲突时定向复核 | 手写较多、表格复杂、准确率优先 |
| 快速 | 只上传整页视图并调用一次模型 | 页面清晰、格式稳定、速度优先 |

### 场记结构 Profile

场记结构不是写死在界面里的模板。启用本地 OCR 后，SlateSync 会把表头、字段坐标、摄影机区块、行列带和页面形状整理成 Profile，并以布局指纹进行匹配：

- 首次识别自动创建 Profile，不需要用户确认；相似版式达到匹配阈值后自动复用。
- 在“场记结构”下拉框中可以显式选择已学习 Profile；留空则自动匹配并继续学习新结构。
- Profile 不包含原始 PDF 或图片，只保存结构化布局、字段别名和 Resolve 输出规则。
- Profile 保存在当前 Project Library 的项目数据库中。

### 识别质量保障

识别完成后，SlateSync 会在不改动数据的前提下做程序化校验，问题行在回填预览中以红色标出，悬停可见原因：

- **条号断档**：同卷条号跳号（如 C003 → C006）时提示可能漏识别的条号清单。
- **次序异常**：同镜内次重复、跳号、回落，或换镜后未从 1 开始。
- **完整性对账**：Resolve CSV 中存在、但识别结果中没有的素材会标红，提示可能漏页或漏识别。
- **人工复核标记**：多次识别仍无法确认的冲突字段留空并标记，绝不猜测填入。

快速模式检出序列异常时，会建议使用精确模式重新识别以获得双重校验。

### 本地 CSV 合并

1. 载入场记系统 CSV。
2. 载入 Resolve CSV。
3. 点击“合并 CSV”，校对后下载。

## 写入规则

###### 输出格式都能改

| Resolve 字段 | 数据来源 | 输出格式 |
| --- | --- | --- |
| `Scene` | 场记单“场次” | 单一纯数字按配置位宽补零（默认至少三位）；字母后缀和多场次均保留并统一规范（如 `87a` → `87A`、`57、58` → `57 / 58`、`57a/58` → `57A / 58`） |
| `Shot` | 场记单“镜” | 仅数字，按配置位宽补零（默认至少两位） |
| `Take` | 场记单“次” | 仅数字，按配置位宽补零（默认至少两位） |
| `Comments` | 条次状态 | 按配置的标记写入，默认过条 `_OK`、保条 `_KP`、其他为空 |
| `Camera FPS` | `slate.txt` 的 `Sensor FPS` | 原始帧率 |
| `Shoot Day` | `slate.txt` 的 `Shot Date` | `YY-MM-DD` |

位宽是**最小位数**而非固定位数：不足补前导零，超出位数的数值原样保留（次 11 输出 `11`，绝不截断）。全角数字（`０９`）、带圈数字（`⑪`）和中文数字（`十一`）会先归一化为阿拉伯数字再补零。

SlateSync 只更新匹配到的素材，不创建虚构行；原 CSV 的其他字段、编码和换行格式保持不变。

## 配置

完整环境变量及说明见 [.env.example](./.env.example)。常用配置如下：

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `SLATESYNC_CONFIG_PATH` | `slatesync.config.json` | 工作流配置文件路径 |
| `MODEL_REQUEST_TIMEOUT_MS` | `180000` | 单个模型请求超时（毫秒），范围 30000–3600000 |
| `MODEL_REQUEST_MAX_RETRIES` | `1` | 单个模型请求超时后的自动重试次数，范围 0–3 |
| `MODEL_PAGE_CONCURRENCY` | `2` | 同时提交给模型的页数，范围 1–6 |
| `MAX_CONCURRENT_RECOGNITIONS` | `1` | 同时运行的识别任务数 |
| `PADDLEOCR_ENABLED` | `auto` | `auto`、`true` 或 `false` |
| `PADDLEOCR_PROFILE` | `balanced` | `fast`、`balanced` 或 `accurate` |
| `VISIONOCR_ENABLED` | `auto` | macOS Vision OCR 开关 |

字段位数和素材目录扫描深度在 [slatesync.config.json](./slatesync.config.json) 中配置：

```json
{
  "slate": {
    "maxDirectoryDepth": 4
  },
  "scenario": {
    "matching": {
      "threshold": 0.85,
      "ambiguityMargin": 0.05
    }
  },
  "resolve": {
    "fieldFormats": {
      "scene": "XXX",
      "shot": "XX",
      "take": "XX"
    },
    "comments": {
      "goodTake": "_OK",
      "holdTake": "_KP"
    }
  }
}
```

- `fieldFormats` 中 `X` 的个数表示该字段的**最小位数**：识别输出不足时补前导零，超出时原样保留。例如 `take: "X"` 时，次 9 输出 `9`、次 11 输出 `11`。
- `comments` 定义写入 Resolve `Comments` 的条次标记：`goodTake` 对应过条（默认 `_OK`），`holdTake` 对应保条（默认 `_KP`）；废条和未标记始终写空值。每个标记须为 1–32 个字符且不含换行。已有 CSV 中的 `_OK`/`_KP`（大小写不限）在合并时会自动转换为配置的标记。
- `maxDirectoryDepth` 是扫描素材目录时递归的最大深度，范围 1–12。
- `scenario.matching.threshold` 是自动复用 Profile 的最低相似度，范围 0.5–1；`ambiguityMargin` 是最佳与次佳结果的最小差值，范围 0–0.5。无法确认时会创建新 Profile，不强行套用旧版式。
- 配置文件支持**热加载**：修改保存后，下一次识别或导出即按新配置执行；若改坏文件，应用会继续使用最后一份有效配置。

## 数据与安全

- API Key 仅由 Electron 主进程读取，renderer 无法直接访问密钥文件。
- Resolve CSV、素材目录和 `slate.txt` 始终在本地处理。
- 原始 PDF 不离开本机 renderer；云端模型接收处理后的页面图像、OCR 证据和可选辅助字段。
- 原始文件和页面图像不写入磁盘；结构化任务结果与诊断文本会持久化。
- `slatesync.sqlite` 是任务、诊断和场记结构的权威数据源；旧版本的 `data/tasks/*.json` 与 `data/diagnostics/*.json` 会在首次启动时迁移，并暂时保留为兼容快照。
- Project Library 默认位于 macOS Application Support 目录，可在应用内导入、导出或更换位置。

## 限制

- PDF 最多 20 页，暂不支持 HEIC。
- 缺少卷号、视频码、场、镜或次的记录不会写入 Resolve CSV。
- `Comments` 只允许配置的条次标记（默认 `_OK`、`_KP`）或空值，自由文本备注不会写入。
- 冲突或无效字段不会覆盖原值，并会提示人工确认。
- 手写内容和跨页继承结果仍应人工校对。

## 开发与验证

```bash
npm run check       # 检查 JavaScript、Electron 与 Python 语法
npm test            # 运行完整测试，不调用真实模型，不消耗 API 额度
npm run test:native:abi # 验证 Electron 原生 ABI，并在 finally 后恢复/验证 Node ABI
npm run ocr:check   # 检查 PaddleOCR 安装
```

## 常见问题

- **`npm run ocr:check` 提示找不到 Python 环境**：先运行 `npm run ocr:setup`；如果系统缺少 `venv`，请先安装对应的 Python venv 组件。

- **模型接口频繁限流或超时**：超时默认会自动重试 1 次；仍然失败时，可将 `MODEL_PAGE_CONCURRENCY` 降为 `1`，适当增加 `MODEL_REQUEST_TIMEOUT_MS`，或用 `MODEL_REQUEST_MAX_RETRIES` 调整重试次数。

- **Electron 编译时找不到 `swiftc`**：运行 `xcode-select --install`，完成安装后重新编译 Vision OCR。

- **Node 与 Electron 报 `NODE_MODULE_VERSION` 不匹配**：这是 `better-sqlite3` 被编译给另一个运行时导致的。通过 npm 脚本运行测试或 Electron 时会自动恢复对应 ABI；直接执行 `node ...` 前可运行 `npm run rebuild:native:node`。Electron Builder 打包时也会自动重建原生依赖。

- **Electron 开发模式每次启动都重新编译**：开发脚本会强制重建 `better-sqlite3`，以可靠处理 Node 与 Electron 之间的 ABI 切换；本地重建通常只需几秒。

- **是否应为了 ABI 切换更换数据库**：当前不需要。ABI 数字属于系统 Node 与 Electron 两个运行时，不代表项目仍有 Web 服务；换成 `sqlite3` 仍需原生 ABI，WASM 会改变文件和锁语义，`node:sqlite` 则留作重构完成后的独立兼容性评估。当前脚本、CI 和发布检查会自动准备并恢复正确运行时。

- **修改 `slatesync.config.json` 后识别位数未变化**：配置支持热加载，下一次识别或导出即生效，无需重启。若仍未生效，请检查 JSON 是否合法——格式错误的配置会被忽略并沿用上一次的有效配置；`fieldFormats` 的值必须由 1–6 个 `X` 组成。
