<div align="center">

# SlateSync

**可本地运行或部署到服务器的场记单识别与 DaVinci Resolve CSV 导出工具**

![Node.js ≥ 20.19](https://img.shields.io/badge/Node.js-%E2%89%A520.19-339933.png?logo=nodedotjs&logoColor=white)
![部署方式](https://img.shields.io/badge/%E9%83%A8%E7%BD%B2-Node.js%20%7C%20Docker-blue.png)

</div>

内置以下视觉模型，并支持通过 OpenAI 兼容 API 接入任意视觉模型：

| 模型 | 可用服务商 |
| --- | --- |
| `qwen/qwen3.7-flash` | OpenRouter |
| `openai/gpt-5.6-luna` | OpenAI 官方 / OpenRouter |
| `openai/gpt-5.6-terra` | OpenAI 官方 / OpenRouter |
| `openai/gpt-4o-mini` | OpenAI 官方 / OpenRouter |
| `qwen3.7-plus` | 阿里云 Token Plan |
| `qwen3.8-max` | 阿里云 Token Plan |
| `qwen3.6-flash` | 阿里云 Token Plan |
| `qwen3.6-plus` | 阿里云 Token Plan 团队版 |

- **支持格式**：PDF、JPEG、PNG、WebP。
- **工作顺序**：可以先识别场记单，再载入 DaVinci Resolve 从媒体池导出的媒体元数据 CSV；识别结果会保留，CSV 载入后立即完成素材匹配与合成。也可以沿用先载入 CSV、再识别场记单的顺序。
- **写回内容**：校对后将 `Scene`、`Shot`、`Take`、`Comments` 写回上传的 CSV；选择素材目录后，还会把每个 `slate.txt` 的 `Sensor FPS` 写入 `Camera FPS`、`Shot Date` 写入 `Shoot Day`。原表的全部素材行和其他列保持不变。

> [!NOTE]
> Silverstack CSV 不属于正常输入流程。

## 目录

- [字段映射与导出规则](#字段映射与导出规则)
- [快速启动](#快速启动)
- [使用流程](#使用流程)
- [进阶参考](#进阶参考)（识别链路 · 模型列表 · API 路由）
- [数据与隐私](#数据与隐私)
- [测试](#测试)
- [当前限制](#当前限制)

## 字段映射与导出规则

字段映射固定为：

| 场记单字段 | Resolve 字段 | Resolve 中文界面 | 格式规则 | 示例 |
| --- | --- | --- | --- | --- |
| 场次 | `Scene` | 场景 | 仅数字并补足三位 | `37A` → `037`、`1` → `001` |
| 镜 | `Shot` | 镜次 | 仅数字并补足两位 | `2` → `02` |
| 次 | `Take` | 镜头 | 仅数字并补足两位 | `9` → `09` |
| 素材旁 `slate.txt` 的 `Sensor FPS` | `Camera FPS` | 摄影机帧率 | 正数帧率，去除多余小数零 | `48` → `48`、`47.952 fps` → `47.952` |
| 素材旁 `slate.txt` 的 `Shot Date` | `Shoot Day` | 拍摄日期 | 规范为 `YY-MM-DD` | `2026-08-01` → `26-08-01` |

条次标记写入 `Comments` 的规则：

| 场记单条次标记 | 含义 | 写入 `Comments` |
| --- | --- | --- |
| `☑` / `√` / `✓` | 过条 | `_OK` |
| `△` / 三角形 | 保条 | `_KP` |
| `X` / `×` | 废条 | 空值 |

- 识别出的备注文字仅供人工校对，**绝不写入** CSV `Comments`。
- “景别”不会被误写为 `Scene`。

### 硬性导出约束

- 整份 CSV 中每个非空 `Scene` 必须匹配 `^\d{3}$`；每个非空 `Shot`、`Take` 必须匹配 `^\d{2}$`。
- 合成时会规范未匹配行中的旧值，最终编码器还会再次校验，因此绕过普通合成入口也不能导出错误位数。CSV 没有工作簿式的“单元格类型”；项目保证写出的字符为 `001`、`01`、`09`，重新解析后前导零仍在。

### 镜号继承（合并单元格）

场记单的镜号经常在合并单元格中只写一次，下面连续记录多次。程序会让同一镜组内的所有素材继承相同 `Shot`，同时逐行读取各自的 `Take`。

> **示例**：A 机 `C002` 属于 `89A` 场 `01` 镜第 `02` 次时，输出为 `Scene=089`、`Shot=01`、`Take=02`。

## 快速启动

**环境要求**：Node.js **20.19** 或更高版本。项目使用内置 PDF.js 校验 PDF 并生成页面视图，不需要安装 Poppler、`pdftoppm` 或其他系统组件。

### 1. 配置环境变量

```bash
cp .env.example .env
```

在 `.env` 中至少填写一个 API Key：

```dotenv
OPENAI_API_KEY=sk-...
OPENROUTER_API_KEY=sk-or-v1-...

# 已获得应用后端调用许可时，可配置 Token Plan 专属 Key
TOKENPLAN_API_KEY=sk-sp-...
TOKENPLAN_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1

# 或配置任意 OpenAI 兼容端点
OPENAI_COMPATIBLE_API_KEY=your-key
OPENAI_COMPATIBLE_BASE_URL=https://your-provider.example/v1
OPENAI_COMPATIBLE_MODEL=your-vision-model
```

### 2. 安装依赖并启动

首次下载项目后：

```bash
npm ci
npm run ocr:setup
npm start
```

### 3. 打开浏览器

访问 <http://127.0.0.1:4173>。

关于 `npm run ocr:setup`：

- 在项目内创建被 Git 忽略的 `.venv-paddleocr`，安装 PaddlePaddle 3.3.1 与 PaddleOCR 3.7.0；首次实际识别时下载所选 PP-OCRv5 官方权重到 `.paddlex-cache`，后续启动直接复用。
- 可用 `npm run ocr:check` 检查本地依赖；暂时不需要 OCR 时，可在 `.env` 设置 `PADDLEOCR_ENABLED=false`。

<details>
<summary><strong>工作流配置（slatesync.config.json）</strong></summary>

工作流行为由项目根目录的 `slatesync.config.json` 控制：

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
    }
  }
}
```

- `maxDirectoryDepth` 是从所选根目录向下进入的最大目录层数，允许 `1–12`；默认 `4` 可覆盖 `Video/day-001/A001_media/master/A001C001_DEMO001/slate.txt`。
- 格式中的每个 `X` 表示一位数字，允许 `1–6` 个 `X`。默认 `Scene=XXX`、`Shot=XX`、`Take=XX`。
- 修改配置后需要重启 SlateSync。也可通过 `.env` 的 `SLATESYNC_CONFIG_PATH` 指定其他配置文件。

</details>

<details>
<summary><strong>生产服务器部署（Docker · Nginx · 运维）</strong></summary>

推荐使用 Docker Compose。容器以非 root 用户运行，异常退出后自动重启，并通过健康检查确认 Node 服务可用；PaddleOCR 模型权重保存在独立数据卷中，更新容器时无需重复下载。

```bash
cp .env.example .env
# 编辑 .env：填写至少一个 API Key，并设置登录账号与强密码
# SLATESYNC_AUTH_USERNAME=slatesync
# SLATESYNC_AUTH_PASSWORD=请替换为强密码
docker compose up -d --build
docker compose ps
curl http://127.0.0.1:4173/healthz
```

默认只把 `4173` 端口绑定到服务器本机。需要修改宿主机端口时，可在 `.env` 追加 `SLATESYNC_PORT=4180`。对公网提供服务时，应在前方配置 HTTPS 反向代理，而不是直接暴露 Node 端口。

Nginx 需要允许 80 MB 请求，并关闭响应缓冲，确保 NDJSON 识别进度实时到达浏览器：

```nginx
location / {
    proxy_pass http://127.0.0.1:4173;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Authorization $http_authorization;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    client_max_body_size 80m;
}
```

Docker 部署会强制要求 `SLATESYNC_AUTH_USERNAME` 与 `SLATESYNC_AUTH_PASSWORD`，SlateSync 对页面和 API 使用同一组 HTTP Basic Auth。还可以在反向代理叠加单点登录、VPN 或 IP 白名单。

日常维护命令：

```bash
docker compose logs -f --tail=200
docker compose build --pull
docker compose up -d
docker compose down
```

- `GET /healthz` 用于存活检查；`GET /readyz` 额外报告识别 API 与 OCR 是否已配置可用，不返回密钥。
- `/readyz` 只有在至少一个识别 API 已配置、且必需 OCR 可用时才返回 HTTP 200。
- 容器默认同时运行 1 个识别任务，避免多个 PaddleOCR 进程争抢内存；按服务器容量设置 `MAX_CONCURRENT_RECOGNITIONS` 可提高并发。
- 容器停止时最多等待 5 分钟，让进行中的识别任务完成；可通过 `SHUTDOWN_TIMEOUT_MS` 调整。
- `slatesync-ocr-cache` 卷只保存可重新下载的 OCR 模型。上传文件、CSV 与识别结果仍只在内存中处理，不写入该卷。
- 升级前备份 `.env`。OCR 缓存不属于业务数据，可以按需重建。

</details>

## 使用流程

### 基本步骤

1. **选择场记单**：上传单张图片或最多 20 页的 PDF，等待浏览器完成页面准备。
2. **开始识别**：选择 API 与视觉模型；PDF 会裁去上下大面积白边，为每页生成整页图和上下两张核心列局部放大图，先由本地 PaddleOCR 提取文字证据，再最多同时处理 2 页多模态请求。
3. **并行载入 CSV**：场记单文件准备完成后，Resolve CSV 入口立即开放；可以在场记单识别过程中载入或更换 CSV，不必等待模型完成。
4. **选择素材目录（可选）**：CSV 载入后即可选择视频备份盘根目录，同样不必等待识别完成。程序按 CSV 中的素材编号定向搜索配置深度内以 `slate.txt` 结尾的文件，跳过无关素材目录，只解析 `Clip Name`、`Sensor FPS` 与 `Shot Date`；视频文件不会被读取或上传。不支持低 I/O 目录接口的浏览器会自动回退到兼容模式。
5. **校对与合成**：识别完成后校对卷号、视频码、场次、镜和次；程序用结果匹配 CSV，并将 `slate.txt` 的 `Sensor FPS` 合成到 `Camera FPS`、`Shot Date` 合成到 `Shoot Day`。
6. **下载回填**：下载“已回填”的完整 Resolve CSV，再导入 Resolve。

### 校对与回填规则

**合并与继承**

- 程序按页合并记录，同一页允许出现多个摄影机卷号；跨页留空的场次和镜会按同一卷号的上一条记录继承。
- 两类有前后记录佐证的高置信错位会被自动校正：被同镜连续 Take 前后夹住的单行镜/次误读，以及至少两条连续素材共同漏掉下一镜十位（例如 `17` 后的 `18` 被读成 `08`）。所有自动校正都会降低置信度并显示人工复核警告；单条或拍摄顺序不明确的情况不会自动改号。

**完整性对账**

- 识别完成后，程序在浏览器本地把识别到的“卷号 + 视频码”与 CSV 素材清单对账：结果区显示覆盖数，未识别素材按连续范围列出，并在 CSV 预览中以**橙色**标记。该对账不会把 Resolve CSV 或其目录、时间码等字段发送给模型。

**回填**

- **不虚构素材**：程序不会生成虚构的文件名，也不会新增不存在的素材行。程序从 `Reel Name`（卷名）和 `File Name`（文件名）解析“卷号 + 条号”，匹配后只回填对应行的 `Scene`、`Shot`、`Take`、`Comments`；同时用 `slate.txt` 的 `Clip Name` 匹配同一素材，将 `Sensor FPS` 写入 `Camera FPS`、`Shot Date` 写入 `Shoot Day`。
- **`Sensor FPS` 安全规则**：支持 UTF-8/UTF-16 `slate.txt`。txt 内已有 `Clip Name` 但无法识别、与 txt 文件名指向不同素材，或同一素材存在冲突 `Sensor FPS` 时，不写入并显示警告；仅当 txt 完全缺少 `Clip Name` 时才允许用文件名识别素材；未找到有效 txt 时保留 CSV 原有 `Camera FPS`，不会清空。即使场记字段不完整或互相冲突，可靠的 `Camera FPS` 仍可独立写入。
- **`Shot Date` 安全规则**：支持 `YYYY-MM-DD`、`YYYY/MM/DD`、`YYYYMMDD` 与 `YY-MM-DD`，写入时统一为 Resolve 使用的 `YY-MM-DD`。无效日期或同一素材存在互相冲突的日期时保留 CSV 原有 `Shoot Day`，不会清空，也不影响可靠的 `Camera FPS` 回填。
- **`Comments` 白名单**：成功匹配的行中 `Comments` 只能是 `_OK`、`_KP` 或空值；导出前对整列清洗：旧值 `OK`/`KP` 规范为 `_OK`/`_KP`，其他文字清空，不会写入“过”“保”“废条”等字样。
- **位数规范化**：导出前按 `slatesync.config.json` 的 `resolve.fieldFormats` 规范化全表 `Scene`/`Shot`/`Take`，默认三位/两位/两位。
- **其余内容不变**：同一素材在 CSV 中出现多行时会全部回填，其他行、列顺序和非目标字段保持不变。

**视频码**

- 视频码固定为 `C0XX`：表格预印 `C0`，场记填 `15` 识别为 `C015`，填 `5` 识别为 `C005`。匹配时忽略 C 后数字多余的前导零，场记 `D001 + C009` 可匹配 Resolve 的 `D001C0009_...MOV`；不同卷号上的相同条号不会串行。

**下载**

- 下载文件沿用上传 CSV 的编码、BOM、分隔符、换行符和末尾换行设置；缺少的 `Scene`/`Shot`/`Take`/`Comments` 列会按 Resolve 英文字段名自动补充，已选有效 `slate.txt` 时缺少的 `Camera FPS` 与 `Shoot Day` 列也会自动补充。

<details>
<summary><strong>高精度模式与流式接口（NDJSON）</strong></summary>

界面默认启用高精度模式：

- 每个来源页先做一次完整字段**主识别**，再做一次独立的核心字段**查漏**，并按“卷号 + 视频码”合并。
- 两次结果的场、镜、次或状态互相冲突，或某个素材只在查漏结果中出现时，会发起第三次**定向复核**；只在查漏中出现但最终无法确认的素材会被移除，避免把假阳性写入 CSV。
- 局部放大图始终与整页图归属于同一来源页，不会重复生成素材记录。
- 因此每页通常消耗两次模型请求和更多图像 token，存在冲突或查漏候选的页面会消耗第三次请求。

服务端 API 的旧 `imageDataUrl` / `imageDataUrls` 调用保持单次快速模式兼容；传入 `accuracyMode: "high"` 与 `imageDataGroups` 才启用上述流程。

网页使用 `POST /api/recognize-stream` 接收换行分隔 JSON（NDJSON）进度事件与最终结果；旧的 `POST /api/recognize` JSON 接口仍保留，供已有客户端兼容使用。流式错误也会以结构化事件返回，前端会停止进度并显示可读原因。

</details>

## 进阶参考

<details>
<summary><strong>PaddleOCR + 多模态识别链路（含性能档位）</strong></summary>

**OCR 证据与分工**

网页上传的 PDF 先在浏览器内逐页生成一张整页图和两张核心列局部放大图。服务端随后按整份文档一次启动本地 PP-OCRv5，给每个识别文本保留：原文、置信度、所属来源页与整页/局部视图、归一化坐标框 `[left, top, right, bottom]`。

这些 OCR 结果作为“证据”与页面图像一起交给多模态模型：

- **主识别**收到完整证据；**独立查漏**和**冲突复核**收到聚焦场、镜、次、卷号、视频码及状态符号的核心证据。
- 提示词明确要求模型核对图片，不把 OCR 当成绝对正确答案；同一文字在整页图与局部图中重复时也不能生成重复素材。
- 这样 PaddleOCR 负责尽量完整地抄录和定位，多模态模型负责表格关系、跨行继承、相似数字纠错和最终 JSON 结构化。

**页面视图与进度**

每个 PDF 页面固定生成 **1 张整页图 + 2 张核心列局部放大图**，因此 4 页 PDF 会显示 12 个“页面视图”。这些不是额外 PDF 页，而是用于保留小字、手写数字和表格列证据的三种视图。

PDF 页面使用受控的双页并发预处理，在保留原页序的同时缩短多页文档准备时间。界面进度条显示实际流水线阶段：

`图像预处理 → PaddleOCR 逐视图提取 → 逐页主识别 → 核心字段查漏 → 必要的冲突复核 → 结果合成 → 完成`

PaddleOCR 每处理完一个整页或局部视图就更新一次进度；模型层按已完成页数更新，因此长任务不会只显示无法判断状态的循环动画。

**性能档位与运行参数**

`PADDLEOCR_PROFILE` 提供三档性能，三档都会保留上述三视图：

| 档位 | 检测模型 | 识别模型 | 识别批量 | 说明 |
| --- | --- | --- | --- | --- |
| `balanced`（默认） | Mobile | Server | 8 | 加速文字框检测的同时保留较强的中文识别 |
| `fast` | Mobile | Mobile | 16 | 最快 |
| `accurate` | Server | Server | 4 | 最准 |

也可以用 `PADDLEOCR_DETECTION_MODEL`、`PADDLEOCR_RECOGNITION_MODEL` 和 `PADDLEOCR_RECOGNITION_BATCH_SIZE` 单独覆盖。

- 默认 `PADDLEOCR_ENABLED=auto`：检测到项目虚拟环境就启用。OCR 初始化或推理失败时会在结果中显示原因，并降级为原有纯多模态流程；生产环境可设置 `PADDLEOCR_REQUIRED=true`，让 OCR 失败直接中止，避免静默降低识别质量。
- 服务端旧接口若直接提交 Base64 PDF 而不是逐页图片，会明确跳过 OCR；Required 模式会直接拒绝这种无法运行 OCR 的输入。网页正常上传 PDF 不受此限制。
- `PADDLEOCR_TIMEOUT_MS=auto` 会按照整份文档的视图数量增加超时时间，避免合法的 20 页文档被固定短超时中断。
- `PADDLEOCR_MAX_BLOCKS_PER_VIEW=0` 默认保留全部 OCR 文本块；若为了限制内存设置为正数，程序会在整页高度范围内均匀保留证据，不会总是删除页面底部。

</details>

<details>
<summary><strong>动态视觉模型列表</strong></summary>

选择一个已配置的 API 服务商后，网页会自动调用服务端的模型发现接口：

| 服务商 | 接口 |
| --- | --- |
| OpenAI 官方 | `GET /api/models?provider=openai` |
| OpenRouter | `GET /api/models?provider=openrouter` |
| 阿里云 Token Plan | `GET /api/models?provider=tokenplan` |
| OpenAI 兼容 | `GET /api/models?provider=openai-compatible` |

服务端使用对应的 Bearer API Key 请求 `${BASE_URL}/models`，API Key 始终只保留在 SlateSync 服务端，不会返回浏览器。模型列表会缓存 **5 分钟**；“刷新列表”按钮可以强制重新读取。

列表只保留适合本项目的“图像输入 + 文本输出”模型，并按两组展示：

1. 固定模型优先，顺序保持为项目预设顺序。
2. 其余当前 Key 可访问的视觉模型，按内部综合优先级排列。

数据来源与展示原则：

- OpenRouter 的 `/models` 会返回输入/输出模态、价格和支持参数，程序优先使用这些实时字段。
- OpenAI 官方 `/models` 主要用于确认当前 Key 可访问的模型 ID，因此程序会再与内置的 OpenAI 视觉能力与公开价格目录求交集。
- 价格只作为服务端计算性价比等级的内部信号，界面不显示具体金额，因为实际价格可能随 API 服务商、路由和优惠变化。
- 界面保留“识别精度”和“性价比”等级；识别精度是模型能力等级，不是未经实测的准确率百分比，后续可用场记单回归集的真实成绩替换。
- 模型列表读取失败时，界面会明确警告，并暂时显示未验证的固定候选模型，不会把它们标记为当前 Key 已确认可用。

</details>

<details>
<summary><strong>API 路由（OpenAI 官方 / OpenRouter / Token Plan / 兼容 API）</strong></summary>

**OpenAI 官方** — Responses API：

```text
POST https://api.openai.com/v1/responses
```

- 界面上传的 PDF 会在浏览器内逐页转成裁去大面积白边的整页图和两张带表头、聚焦左侧场/镜/次与 A–D 机栏的局部放大图；同一来源页的三张视图会放在同一个 `input_image` 请求中，避免把局部图误当成不同页面。
- 普通图片同样作为 `input_image` 发送。使用 `text.format: json_schema` 约束输出。
- Qwen 模型不在 OpenAI 官方服务中，因此选择 OpenAI 时不会显示 Qwen。
- 服务端 API 仍兼容直接提交单个 Base64 `pdfDataUrl`，用于非网页客户端。

**OpenRouter** — OpenAI 兼容的 Chat Completions API。界面上传的 PDF 同样按来源页生成三张视图，并在同一个 `image_url` 消息中发送：

```text
POST https://openrouter.ai/api/v1/chat/completions
```

- 服务端 API 仍兼容单个 Base64 `file` PDF 输入。
- 支持原生结构化输出的模型使用 `response_format: json_schema`；Qwen 3.7 Flash 使用 `json_object`，并把完整 Schema 放进系统提示。
- 两种模式都会启用 `provider.require_parameters`；如果某个原生结构化端点临时不可用，会自动降级为 `json_object` 重试一次。

**阿里云 Token Plan** — 使用已获应用后端调用许可的 Token Plan API Key，通过 OpenAI 兼容 Chat Completions 接入：

```dotenv
TOKENPLAN_API_KEY=sk-sp-...
TOKENPLAN_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
```

- 默认发送到 `${TOKENPLAN_BASE_URL}/chat/completions`，使用 Bearer Authorization；团队版应把 Base URL 替换为控制台显示的套餐专属地址。
- 固定提供 `qwen3.7-plus`、`qwen3.8-max`、`qwen3.6-flash` 和团队版 `qwen3.6-plus`，实时模型列表会按当前 Key 实际权限过滤。
- 优先使用严格 `json_schema` 结构化输出；端点若明确不支持，会自动降级为 `json_object`，再必要时降级为仅提示词约束。
- 网页上传 PDF 时，原始 PDF 仍只在浏览器中处理；每页转换为整页图和两张局部放大图后，以 `image_url` 发送给 Token Plan，并同时附带本地 PaddleOCR 证据。
- 服务端旧接口不向 Token Plan 直接发送 Base64 PDF；非网页客户端应通过 `imageDataGroups` 提交逐页图像。
- Token Plan 官方默认使用范围有限制；此 Provider 只应在已取得自定义应用后端调用许可的情况下启用。参考[获取 API Key](https://platform.qianwenai.com/docs/api-reference/preparation/api-key)与[支持的视觉模型](https://platform.qianwenai.com/docs/token-plan/personal/token-plan-personal-overview)。

**OpenAI 兼容 API** — 支持任意 Bearer API Key、自定义 Base URL 和模型 ID，默认调用 Chat Completions 端点：

```dotenv
OPENAI_COMPATIBLE_API_KEY=your-key
OPENAI_COMPATIBLE_BASE_URL=https://your-provider.example/v1
OPENAI_COMPATIBLE_MODEL=your-vision-model
OPENAI_COMPATIBLE_API_MODE=chat-completions
OPENAI_COMPATIBLE_JSON_MODE=json_object
```

- 程序会向 `${OPENAI_COMPATIBLE_BASE_URL}/chat/completions` 发送 OpenAI 格式的 `messages`、`image_url` 和 Bearer Authorization 请求。
- 兼容服务若支持 Responses API，可把 `OPENAI_COMPATIBLE_API_MODE` 改为 `responses`，程序会改用 `${OPENAI_COMPATIBLE_BASE_URL}/responses`。

`OPENAI_COMPATIBLE_JSON_MODE` 支持：

| 模式 | 行为 |
| --- | --- |
| `json_schema` | 发送严格 `response_format: json_schema` |
| `json_object`（默认） | 发送 `response_format: json_object`，并在系统提示中附带 Schema |
| `prompt` | 不发送 `response_format`，仅用系统提示约束 JSON，适合兼容度较低的端点 |

- 若 `json_object` 被端点明确拒绝，程序会自动降级到 `prompt` 后重试一次。
- 自定义 Base URL 必须是 `http://` 或 `https://`，不能内嵌账号、密码、查询参数或 URL 片段。
- 网页上传的 PDF 已转换为页面图片，因此兼容端点只需支持视觉图片输入；服务端直接提交 Base64 PDF 是否可用取决于该兼容服务对文件输入的支持。

</details>

## 数据与隐私

- API Key 只由 SlateSync Node 服务读取，不会返回浏览器。
- Resolve CSV 只在浏览器内存中解析、匹配和下载，不会发送给 AI API，也不会上传到 SlateSync 服务。
- 所选素材目录只用于浏览器本地筛选和读取 `slate.txt`；视频内容不会被读取，txt 内容也不会发送到 SlateSync 服务或 AI API。受浏览器安全限制，每次刷新页面后需要重新选择素材根目录。
- PaddleOCR 在 SlateSync 服务所在设备运行。页面图像和 OCR 坐标证据只保存在进程内存中；模型权重默认缓存在项目内 `.paddlex-cache`（容器部署时为 `slatesync-ocr-cache` 卷），缓存不包含场记单内容。
- 普通图片会被浏览器缩放到最长边不超过 2600 像素；PDF 使用 PDF.js 逐页渲染，自动裁去上下大面积白边后生成最长边不超过 2600 像素的整页图，以及最长边不超过 3000 像素、聚焦左侧核心表格列的两张局部放大图，再发送给 SlateSync 服务和所选 API 服务。原始 PDF 不会离开浏览器；所选 API 服务会收到页面图像及 OCR 证据文本。
- 提交前会按服务端请求上限检查序列化大小；超限时自动逐级压缩页面图，仍无法满足限制时会提示拆分 PDF，不会先上传再由服务器拒绝。
- PDF、逐页图像、预览和识别结果不写入磁盘，刷新或关闭页面后即释放；当前版本也不在磁盘保存上传的 CSV、图片或识别结果。
- OpenAI、OpenRouter、阿里云 Token Plan 或所配置兼容服务商各自的数据处理政策适用。

## 测试

| 命令 | 说明 |
| --- | --- |
| `npm test` | 运行测试；使用模拟 API 响应，不会消耗额度 |
| `npm run check` | 对服务端、前端 JS 与 OCR Python 脚本做语法检查 |
| `npm run ocr:check` | 检查本地 PaddleOCR 依赖 |

## 当前限制

- 暂不支持 HEIC；PDF 最多 20 页，超过时会提示拆分后重新上传。
- 缺少卷号、视频码、场次、镜或次的识别记录不会写入；CSV 中找不到的记录也不会新增素材行。
- 高精度模式发现同一素材的场、镜、次或状态互相冲突时会定向复核；最终仍无法确认的冲突字段会留空、锁定继承并显示警告，不会把猜测值写入 CSV。内容相同的重复识别会自动合并。
- 若 CSV 同一行的卷名与文件名解析为不同素材，该行会跳过并显示警告。
- 手写识别必须人工校对；尤其要检查跨页继承的场次、镜和次。
