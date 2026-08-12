<div align="center">

# SlateSync

**识别场记单并回填 DaVinci Resolve CSV**

![Node.js ≥ 20.19](https://img.shields.io/badge/Node.js-%E2%89%A520.19-339933.png?logo=nodedotjs&logoColor=white)
![运行方式](https://img.shields.io/badge/%E8%BF%90%E8%A1%8C-Web%20%7C%20Docker%20%7C%20Electron-blue.png)

</div>

SlateSync 支持两种工作方式：

- 使用 PaddleOCR 和视觉模型识别 PDF、JPEG、PNG、WebP 场记单。
- 在浏览器内直接合并“场记系统 CSV + Resolve CSV”，无需 API Key。

结果可写入 `Scene`、`Shot`、`Take`、`Comments`，并可从素材旁的 `slate.txt` 写入 `Camera FPS` 和 `Shoot Day`。


## 启动

需要 Node.js **20.19+**。

```bash
cp .env.example .env
npm ci
npm start
```

打开 <http://127.0.0.1:4173>。

使用 AI 识别时，再执行 OCR 安装并在 `.env` 中配置至少一个 API Key：

```bash
npm run ocr:setup
```

```dotenv
OPENAI_API_KEY=sk-...
# 或 OPENROUTER_API_KEY=sk-or-v1-...
```

完整配置见 [.env.example](./.env.example)。纯本地 CSV 合并不需要 API Key 或 OCR。

Electron（macOS）：

```bash
npm run electron:dev
```

## 使用

### AI 识别

1. 上传场记单；可选加载场记系统 CSV 作为辅助数据。
2. 选择 API 和视觉模型并开始识别。
3. 载入 Resolve CSV；可选选择素材目录扫描 `slate.txt`。
4. 校对结果并下载回填后的 CSV。

### 本地合并

1. 载入场记系统 CSV。
2. 载入 Resolve CSV。
3. 点击“合并 CSV”，校对后下载。

移除或替换场记系统 CSV 时，本地合并结果会同步清除，避免导出旧数据。

## 写入规则

| Resolve 字段 | 来源与格式 |
| --- | --- |
| `Scene` | 场次，仅数字，默认三位 |
| `Shot` | 镜，仅数字，默认两位 |
| `Take` | 次，仅数字，默认两位 |
| `Comments` | 过条 `_OK`、保条 `_KP`、废条空值 |
| `Camera FPS` | `slate.txt` 的 `Sensor FPS` |
| `Shoot Day` | `slate.txt` 的 `Shot Date`，格式为 `YY-MM-DD` |

程序只更新匹配到的素材，不新增虚构行；原 CSV 的其他内容、编码和换行格式保持不变。

<details>
<summary><strong>配置与 OCR</strong></summary>

- OpenAI、OpenRouter、阿里云 Token Plan 和任意 OpenAI 兼容视觉端点均通过 `.env` 配置。
- Web/MCP 数据目录默认为 `data/`，可通过 `SLATESYNC_DATA_DIR` 修改。
- 导出位数和素材扫描深度在 `slatesync.config.json` 中配置。
- `npm run ocr:check` 检查 OCR；`PADDLEOCR_ENABLED=false` 可关闭 OCR。
- `PADDLEOCR_PROFILE` 支持 `balanced`、`fast`、`accurate`。
- Electron 使用原生文件对话框，并将配置和历史保存到用户数据目录。

</details>

<details>
<summary><strong>Docker 部署</strong></summary>

```bash
cp .env.example .env
# 设置 SLATESYNC_AUTH_USERNAME 和 SLATESYNC_AUTH_PASSWORD
docker compose up -d --build
```

- 默认监听 `127.0.0.1:4173`，公网访问应使用 HTTPS 反向代理。
- `slatesync-data` 保存 API Key、任务和诊断历史，升级前应备份。
- `slatesync-ocr-cache` 仅保存可重新下载的 OCR 模型。
- `/healthz` 检查存活，`/readyz` 检查 API 与 OCR 是否可用。

</details>

<details>
<summary><strong>数据与隐私</strong></summary>

- API Key 只由 Node/Electron 主进程读取，不会返回浏览器。
- Resolve CSV、素材目录和 `slate.txt` 只在本地处理。
- 原始 PDF 不离开浏览器；AI 服务会收到处理后的页面图像、OCR 证据和可选辅助字段。
- 原始文件、页面图像和 CSV 不写入磁盘；结构化任务结果和诊断文本会持久化。
- JSON 数据文件权限为 `0600`；最多保留 50 个任务和 20 个诊断会话。
- Web/MCP 数据位于 `SLATESYNC_DATA_DIR`，Electron 位于用户数据目录，Docker 位于 `slatesync-data` 卷。

</details>

<details>
<summary><strong>限制与安全规则</strong></summary>

- PDF 最多 20 页；暂不支持 HEIC。
- 缺少卷号、视频码、场、镜或次的记录不会写入。
- `Comments` 只允许 `_OK`、`_KP` 或空值，自由文本备注不会写入。
- 冲突或无效字段不会覆盖原值，并会提示人工确认。
- 恢复历史任务后，如需再次合并 CSV 或扫描素材目录，必须重新选择对应文件或目录。
- 手写内容和跨页继承结果必须人工校对。

</details>

<details>
<summary><strong>开发与测试</strong></summary>

```bash
npm test
npm run check
npm run ocr:check
```

测试使用模拟 API 响应，不会消耗额度。Electron 打包使用 `npm run electron:build`。

</details>
