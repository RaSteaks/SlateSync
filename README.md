<div align="center">

# SlateSync

**场记单识别与 DaVinci Resolve CSV 自动回填工具**

[![Node.js](https://img.shields.io/badge/Node.js-%E2%89%A5%2020.19-339933?logo=nodedotjs&logoColor=white)](https://nodejs.org/)
![Platforms](https://img.shields.io/badge/运行-Web%20%7C%20Electron%20%7C%20Docker-2563eb)
![OCR](https://img.shields.io/badge/OCR-Vision%20%7C%20PaddleOCR-7c3aed)

识别 PDF 或图片场记单，校对后将场、镜、次和条次状态写回 Resolve CSV。

</div>

---

## 功能

- 识别 PDF、JPEG、PNG、WebP 场记单，最多 20 页，预览区支持逐页滚动核对。
- 结合本地 OCR 与云端多模态模型，提高中文、数字和手写内容的识别率。
- 支持 OpenAI、OpenRouter、阿里云 Token Plan、DashScope 和 OpenAI 兼容接口。
- 自动回填 Resolve 的 `Scene`、`Shot`、`Take`、`Comments`。
- 从素材目录中的 `slate.txt` 补充 `Camera FPS` 和 `Shoot Day`。
- 条号断档、次序异常自动告警，并在回填预览中标红提示。
- 识别任务自动保存，可在多个任务之间切换与恢复。
- 内置 MCP 服务器，可把识别与诊断能力接入 AI 客户端。
- 无需 API Key 即可在本地合并“场记系统 CSV + Resolve CSV”。

## 选择运行方式

| 方式 | 适合场景 | 构建产物 |
| --- | --- | --- |
| Web | 本地使用、开发调试 | 无需单独编译，Node.js 直接运行 |
| Electron | macOS 桌面应用 | `dist/` 中的 DMG、ZIP 或未打包应用 |
| Docker | 服务器部署、团队共享 | Docker 镜像与持久化数据卷 |

## 环境要求

基础要求：

- Node.js **20.19 或更高版本**，并自带 npm。
- AI 识别至少配置一个支持的 API Key。

可选要求：

- PaddleOCR：Python 3，并支持创建 `venv`。
- Electron 开发与编译：macOS；使用 Vision OCR 时需要 Xcode Command Line Tools。
- Docker 部署：Docker Engine 和 Docker Compose v2。

> 只使用本地 CSV 合并时，不需要 API Key，也不需要安装 OCR。

## 安装与启动

### Web 本地运行

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

启动应用：

```bash
npm start
```

浏览器访问 <http://127.0.0.1:4173>。开发时可使用自动重启模式：

```bash
npm run dev
```

### Electron 桌面版（macOS）

首次运行：

```bash
cd SlateSync
npm ci
cp .env.example .env
npm run electron:dev
```

API Key 可以写入 `.env`，也可以在应用界面中保存。macOS 会优先使用本地 Vision OCR；如需 PaddleOCR，可额外执行 `npm run ocr:setup`。

### Docker 部署

复制配置并编辑 `.env`：

```bash
cp .env.example .env
```

Docker 部署必须设置访问账号和密码；AI 识别还需填写至少一个 API Key：

```dotenv
SLATESYNC_AUTH_USERNAME=admin
SLATESYNC_AUTH_PASSWORD=replace-with-a-strong-password
OPENAI_API_KEY=sk-...
```

构建并启动：

```bash
docker compose up -d --build
```

常用管理命令：

```bash
docker compose logs -f slatesync
docker compose restart slatesync
docker compose down
```

默认仅监听 `127.0.0.1:4173`。对外提供服务时，应配置 HTTPS 反向代理。

## 编译与打包

### Web

Web 版没有前端编译步骤。`npm ci` 会自动复制 PDF.js 运行资源，随后直接运行：

```bash
npm ci
npm run check
npm test
npm start
```

### Electron（macOS）

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
npm run electron:build:dir
```

> 发布给其他用户前，还需要配置 Apple Developer 代码签名与公证；仓库默认构建不包含发布证书。

### Docker 镜像

只构建镜像、不启动服务：

```bash
docker compose build
```

完整构建与启动：

```bash
docker compose up -d --build
```

镜像会安装生产依赖、Python 与 PaddleOCR；任务数据和 OCR 模型缓存在 Docker 卷中。

## 使用流程

### AI 识别

1. 上传场记单（多页 PDF 会在预览区逐页展示），可选加载场记系统 CSV 作为辅助数据。
2. 选择 API、模型和识别模式，开始识别。
3. 载入 Resolve CSV；需要时选择素材目录扫描 `slate.txt`。
4. 根据警告清单与回填预览中的标红行进行校对，然后下载 CSV。

| 识别模式 | 行为 | 建议用途 |
| --- | --- | --- |
| 精确 | 并行执行主识别与核心字段查漏，冲突时定向复核 | 手写较多、表格复杂、准确率优先 |
| 快速 | 只上传整页视图并调用一次模型 | 页面清晰、格式稳定、速度优先 |

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
| `HOST` / `PORT` | `127.0.0.1` / `4173` | Web 服务监听地址 |
| `SLATESYNC_DATA_DIR` | `data` | API Key、任务和诊断数据目录 |
| `SLATESYNC_CONFIG_PATH` | `slatesync.config.json` | 工作流配置文件路径 |
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
- 配置文件支持**热加载**：修改保存后无需重启服务，下一次识别或导出即按新配置执行（界面上无需刷新页面）；若改坏文件，服务会继续使用最后一份有效配置。

## 数据与安全

- API Key 仅由 Node.js 或 Electron 主进程读取，不返回浏览器页面。
- Resolve CSV、素材目录和 `slate.txt` 始终在本地处理。
- 原始 PDF 不离开浏览器；云端模型接收处理后的页面图像、OCR 证据和可选辅助字段。
- 原始文件和页面图像不写入磁盘；结构化任务结果与诊断文本会持久化。
- Web 数据位于 `SLATESYNC_DATA_DIR`，Electron 数据位于应用用户目录，Docker 数据位于 `slatesync-data` 卷。

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
npm run ocr:check   # 检查 PaddleOCR 安装
```

健康检查：

- `GET /healthz`：服务进程状态。
- `GET /readyz`：API 与 OCR 可用状态。

## MCP 服务器

内置 Model Context Protocol 服务器（stdio 传输），可将 SlateSync 接入支持 MCP 的 AI 客户端：

```json
{
  "mcpServers": {
    "slatesync": {
      "command": "node",
      "args": ["/path/to/SlateSync/mcp-server.mjs"]
    }
  }
}
```

可用工具包括配置与模型查询、API Key 保存、场记单识别、任务管理，以及诊断会话与 OCR 证据的检索（用于排查识别问题）。

## 常见问题

- **`npm run ocr:check` 提示找不到 Python 环境**：先运行 `npm run ocr:setup`；如果系统缺少 `venv`，请先安装对应的 Python venv 组件。

- **模型接口频繁限流或超时**：将 `MODEL_PAGE_CONCURRENCY` 降为 `1`，或适当增加 `MODEL_REQUEST_TIMEOUT_MS`。

- **Electron 编译时找不到 `swiftc`**：运行 `xcode-select --install`，完成安装后重新编译 Vision OCR。

- **端口 4173 已被占用**：在 `.env` 中修改 `PORT`；Docker 部署则修改 `SLATESYNC_PORT`。

- **修改 `slatesync.config.json` 后识别位数未变化**：配置支持热加载，下一次识别或导出即生效，无需重启。若仍未生效，请检查 JSON 是否合法——格式错误的配置会被忽略并沿用上一次的有效配置；`fieldFormats` 的值必须由 1–6 个 `X` 组成。
