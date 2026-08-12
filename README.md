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

- 识别 PDF、JPEG、PNG、WebP 场记单，最多 20 页。
- 结合本地 OCR 与云端多模态模型，提高中文、数字和手写内容的识别率。
- 支持 OpenAI、OpenRouter、阿里云 Token Plan、DashScope 和 OpenAI 兼容接口。
- 自动回填 Resolve 的 `Scene`、`Shot`、`Take`、`Comments`。
- 从素材目录中的 `slate.txt` 补充 `Camera FPS` 和 `Shoot Day`。
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

1. 上传场记单，可选加载场记系统 CSV 作为辅助数据。
2. 选择 API、模型和识别模式，开始识别。
3. 载入 Resolve CSV；需要时选择素材目录扫描 `slate.txt`。
4. 校对识别与回填结果，然后下载 CSV。

| 识别模式 | 行为 | 建议用途 |
| --- | --- | --- |
| 精确 | 并行执行主识别与核心字段查漏，冲突时定向复核 | 手写较多、表格复杂、准确率优先 |
| 快速 | 只上传整页视图并调用一次模型 | 页面清晰、格式稳定、速度优先 |

### 本地 CSV 合并

1. 载入场记系统 CSV。
2. 载入 Resolve CSV。
3. 点击“合并 CSV”，校对后下载。

## 写入规则

| Resolve 字段 | 数据来源 | 输出格式 |
| --- | --- | --- |
| `Scene` | 场记单“场次” | 仅数字，默认三位 |
| `Shot` | 场记单“镜” | 仅数字，默认两位 |
| `Take` | 场记单“次” | 仅数字，默认两位 |
| `Comments` | 条次状态 | 过条 `_OK`、保条 `_KP`、其他为空 |
| `Camera FPS` | `slate.txt` 的 `Sensor FPS` | 原始帧率 |
| `Shoot Day` | `slate.txt` 的 `Shot Date` | `YY-MM-DD` |

SlateSync 只更新匹配到的素材，不创建虚构行；原 CSV 的其他字段、编码和换行格式保持不变。

## 配置

完整环境变量及说明见 [.env.example](./.env.example)。常用配置如下：

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `HOST` / `PORT` | `127.0.0.1` / `4173` | Web 服务监听地址 |
| `SLATESYNC_DATA_DIR` | `data` | API Key、任务和诊断数据目录 |
| `MODEL_PAGE_CONCURRENCY` | `2` | 同时提交给模型的页数，范围 1–6 |
| `MAX_CONCURRENT_RECOGNITIONS` | `1` | 同时运行的识别任务数 |
| `PADDLEOCR_ENABLED` | `auto` | `auto`、`true` 或 `false` |
| `PADDLEOCR_PROFILE` | `balanced` | `fast`、`balanced` 或 `accurate` |
| `VISIONOCR_ENABLED` | `auto` | macOS Vision OCR 开关 |

字段位数和素材目录扫描深度在 [slatesync.config.json](./slatesync.config.json) 中配置。

## 数据与安全

- API Key 仅由 Node.js 或 Electron 主进程读取，不返回浏览器页面。
- Resolve CSV、素材目录和 `slate.txt` 始终在本地处理。
- 原始 PDF 不离开浏览器；云端模型接收处理后的页面图像、OCR 证据和可选辅助字段。
- 原始文件和页面图像不写入磁盘；结构化任务结果与诊断文本会持久化。
- Web 数据位于 `SLATESYNC_DATA_DIR`，Electron 数据位于应用用户目录，Docker 数据位于 `slatesync-data` 卷。

## 限制

- PDF 最多 20 页，暂不支持 HEIC。
- 缺少卷号、视频码、场、镜或次的记录不会写入 Resolve CSV。
- `Comments` 只允许 `_OK`、`_KP` 或空值，自由文本备注不会写入。
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

## 常见问题

- **`npm run ocr:check` 提示找不到 Python 环境**：先运行 `npm run ocr:setup`；如果系统缺少 `venv`，请先安装对应的 Python venv 组件。

- **模型接口频繁限流或超时**：将 `MODEL_PAGE_CONCURRENCY` 降为 `1`，或适当增加 `MODEL_REQUEST_TIMEOUT_MS`。

- **Electron 编译时找不到 `swiftc`**：运行 `xcode-select --install`，完成安装后重新编译 Vision OCR。

- **端口 4173 已被占用**：在 `.env` 中修改 `PORT`；Docker 部署则修改 `SLATESYNC_PORT`。
