import { BookOpen, CheckCircle2, CircleHelp, FileImage, FolderKanban, Gauge, KeyRound, Search, Settings2, Terminal, Workflow, X, type LucideIcon } from "lucide-react";
import { useMemo, useState, type ReactNode } from "react";
import { Badge, Field, Icon, IconButton, Input, Surface, Text } from "../../design-system";
import styles from "../../app/app.module.css";

type HelpSection = {
  id: string;
  kicker: string;
  title: string;
  summary: string;
  keywords: string;
  icon: LucideIcon;
  content: ReactNode;
};

const HELP_SECTIONS: readonly HelpSection[] = [
  {
    id: "help-quick-start",
    kicker: "01 / 工作流",
    title: "软件使用方法",
    summary: "从项目库创建项目，导入场记单，完成识别、校对，再导出 Resolve CSV。",
    keywords: "项目库 工作台 新建项目 PDF 图片 JPEG PNG WebP 场记单 场记 CSV Resolve CSV 素材目录 元数据 识别 校对 导出",
    icon: Workflow,
    content: <>
      <div className={styles.helpStepGrid}>
        <article className={styles.helpStep}>
          <div className={styles.helpStepTop}><span className={styles.helpStepNumber}>01</span><Icon icon={FolderKanban} size={19} /></div>
          <Text as="h3" size="md" weight="bold">创建或打开项目</Text>
          <Text tone="muted" size="sm">在左侧“项目库”新建项目，或打开已有项目。项目、任务、识别结果和结构学习资料都保存在本机项目库中。</Text>
        </article>
        <article className={styles.helpStep}>
          <div className={styles.helpStepTop}><span className={styles.helpStepNumber}>02</span><Icon icon={FileImage} size={19} /></div>
          <Text as="h3" size="md" weight="bold">导入场记单</Text>
          <Text tone="muted" size="sm">进入“工作台”，在场记单区域选择 PDF、JPEG、PNG 或 WebP。PDF 会逐页准备；单个 PDF 最多 20 页，文件大小上限为 20 MB。</Text>
        </article>
        <article className={styles.helpStep}>
          <div className={styles.helpStepTop}><span className={styles.helpStepNumber}>03</span><Settings2 size={19} aria-hidden="true" /></div>
          <Text as="h3" size="md" weight="bold">准备可选输入</Text>
          <Text tone="muted" size="sm">需要对账或回填时，载入场记 CSV 与 Resolve CSV；已有 Resolve CSV 后，还可以选择素材目录读取 slate.txt 的帧率和拍摄日。</Text>
        </article>
        <article className={styles.helpStep}>
          <div className={styles.helpStepTop}><span className={styles.helpStepNumber}>04</span><Gauge size={19} aria-hidden="true" /></div>
          <Text as="h3" size="md" weight="bold">识别、复核与导出</Text>
          <Text tone="muted" size="sm">在“识别设置”选择 Provider、视觉模型、识别模式、场记结构和提示，点击“开始识别”。完成后检查警告与表格，再导出 Resolve CSV。</Text>
        </article>
      </div>
      <div className={styles.helpCallout} data-tone="accent">
        <strong>最短路径：</strong>项目库 → 新建项目 → 工作台导入场记单 → 配置 Provider/模型 → 开始识别 → 载入 Resolve CSV → 校对回填预览 → 导出。
      </div>
      <div className={styles.helpMiniGrid}>
        <div className={styles.helpMiniPanel}>
          <Text as="h3" size="sm" weight="bold">没有模型密钥也能做什么？</Text>
          <Text tone="muted" size="sm">如果已经有场记 CSV，可以直接在工作台载入它并使用“从场记 CSV 生成结果”完成本地合并；图片识别仍需要已配置的视觉模型。</Text>
        </div>
        <div className={styles.helpMiniPanel}>
          <Text as="h3" size="sm" weight="bold">识别结果是否可以直接导出？</Text>
          <Text tone="muted" size="sm">建议先检查低置信度记录、场镜次序和 Resolve 字段映射。表格中的人工编辑会保留在当前任务，确认后再导出。</Text>
        </div>
      </div>
    </>,
  },
  {
    id: "help-model",
    kicker: "02 / Provider",
    title: "大模型如何配置",
    summary: "密钥属于设备级设置，Provider、模型和识别偏好可以在项目或任务级别选择。",
    keywords: "大模型 Provider API Key 密钥 Base URL OpenAI OpenRouter Token Plan DashScope 阿里云 百炼 兼容模型 模型 ID Chat Completions Responses JSON Schema JSON Object 图片细节 识别模式 精确 快速 场记结构 提示",
    icon: KeyRound,
    // Keep this guide focused on configuration controls and behavior; it never
    // renders credential values or an additional security callout.
    content: <>
      <ol className={styles.helpChecklist}>
        <li><strong>保存访问凭据：</strong>进入左侧“系统 → 全局设置”，在“访问密钥与接口”选择 Provider，填写 API Key 并保存。密钥存放在本机独立凭据文件中，保存后不会回显，也不会进入项目数据。</li>
        <li><strong>确认接口地址：</strong>官方 Provider 通常可以保留默认 Base URL；代理、企业网关或自建服务填写对应的 Base URL。普通参数在全局配置中保存，不必手动编辑 <code>.env</code>。</li>
        <li><strong>选择视觉模型：</strong>打开项目后进入“项目设置”或直接在工作台“识别设置”选择 Provider 和模型。模型列表会按 Provider 过滤；应选择支持图片输入的视觉模型。</li>
        <li><strong>设置本次识别：</strong>“精确”使用主识别 + 查漏，“快速”使用单次主识别；场记结构可以自动学习，也可以选择已有 Profile；识别提示用于补充本片的文字、机位或格式约定。</li>
      </ol>
      <div className={styles.helpTableFrame}>
        <table className={styles.helpTable}>
          <caption className={styles.srOnly}>Provider 配置方式</caption>
          <thead><tr><th>Provider</th><th>需要配置</th><th>适用说明</th></tr></thead>
          <tbody>
            <tr><td>OpenAI 官方 API</td><td>API Key；Base URL 通常保持默认</td><td>使用官方视觉模型目录</td></tr>
            <tr><td>OpenRouter API</td><td>API Key；可选应用标识 URL</td><td>在多个视觉模型之间选择</td></tr>
            <tr><td>阿里云 Token Plan</td><td>API Key；按账户要求填写 Base URL</td><td>使用 Token Plan 可调用的兼容模型</td></tr>
            <tr><td>阿里云百炼（DashScope）</td><td>API Key；Base URL 通常保持默认</td><td>使用百炼控制台提供的视觉模型</td></tr>
            <tr><td>OpenAI 兼容 API</td><td>API Key、Base URL、模型 ID</td><td>自建网关、第三方兼容服务或本地服务</td></tr>
          </tbody>
        </table>
      </div>
      <div className={styles.helpMiniGrid}>
        <div className={styles.helpMiniPanel}>
          <Text as="h3" size="sm" weight="bold">OpenAI 兼容接口的额外选项</Text>
          <Text tone="muted" size="sm">在全局设置中可以指定模型 ID、请求接口（Chat Completions 或 Responses）、JSON 模式（JSON Schema、JSON Object 或 Prompt 约束）和图片细节（auto、low、high、original）。配置后可点击“测试 JSON Schema”检查服务端能力。</Text>
        </div>
        <div className={styles.helpMiniPanel}>
          <Text as="h3" size="sm" weight="bold">为什么 Provider 显示未配置？</Text>
          <Text tone="muted" size="sm">通常是 API Key 为空、Base URL 不可达，或 OpenAI 兼容接口缺少模型 ID。先在全局设置保存并检查，再回到工作台重新选择模型。</Text>
        </div>
      </div>
    </>,
  },
  {
    id: "help-ocr",
    kicker: "03 / Local OCR",
    title: "OCR 如何配置",
    summary: "本地 OCR 只提取文字和坐标作为证据，最终字段仍由视觉模型结合页面图片确认。",
    keywords: "OCR 本地 Apple Vision Vision bridge macOS Swift PaddleOCR Python venv 启用 必需 自动选择 回退 文字块 证据",
    icon: Terminal,
    content: <>
      <ol className={styles.helpChecklist}>
        <li><strong>选择路由：</strong>进入“全局设置 → 本地 OCR”，在“首选 OCR 引擎”选择自动、Apple Vision OCR、PaddleOCR 或关闭本地 OCR。</li>
        <li><strong>配置 Apple Vision OCR：</strong>macOS 自带本地能力，不需要 Python；通常保留“自动 + 可选”，再按场记语言选择 `zh-Hans`、`en-US` 等语言。</li>
        <li><strong>配置 PaddleOCR：</strong>在项目根目录执行 <code>npm run ocr:setup</code> 安装环境，执行 <code>npm run ocr:check</code> 检查；设置页中的 Python 环境路径可以留空使用项目内环境，也可以填写绝对路径，最后点击“验证并保存环境”。</li>
        <li><strong>保存并观察状态：</strong>保存后，状态卡会显示“当前优先”、环境可用性和实际模型配置。首次选择 PaddleOCR 可能需要下载模型；应用会在后台预加载选中的配置，后续任务复用已准备的 Worker。</li>
      </ol>
      <div className={styles.helpCallout} data-tone="accent">
        <strong>路由优先级：</strong>必需模式 → 显式开启 → 自动选择。自动模式在 macOS 上优先 Vision；Vision 不可用时转用可用的 PaddleOCR；两者都不可用时，识别仍可降级为仅发送页面图片的多模态流程（如果本次 Provider 可用）。
      </div>
      <div className={styles.helpTableFrame}>
        <table className={styles.helpTable}>
          <caption className={styles.srOnly}>Apple Vision OCR 参数</caption>
          <thead><tr><th>参数</th><th>可选值/范围</th><th>具体含义</th></tr></thead>
          <tbody>
            <tr><td>启用模式</td><td>自动 / 开启 / 关闭</td><td>决定 Vision 是否参与本地 OCR 路由；自动会按系统能力判断。</td></tr>
            <tr><td>必需模式</td><td>可选 / 必需</td><td>必需时 Vision 不可用会阻止识别，不会静默换成其他 OCR。</td></tr>
            <tr><td>识别语言</td><td>语言列表</td><td>逗号分隔的语言标识，例如 `zh-Hans,en-US`；语言越贴合素材，文字识别通常越稳定。</td></tr>
            <tr><td>识别精度</td><td>高精度 / 快速</td><td>高精度优先识别质量，快速优先降低本地处理延迟。</td></tr>
            <tr><td>语言校正</td><td>启用 / 关闭</td><td>启用系统语言校正；特殊术语、片名或人名较多时可关闭并交给后续模型判断。</td></tr>
            <tr><td>最低置信度</td><td>0–1</td><td>低于阈值的文字块不进入 OCR evidence；这是输出过滤，不是模型推理加速开关。</td></tr>
            <tr><td>每个视图最多文字块</td><td>0–10000</td><td>0 表示不限制；限制时按页面均匀覆盖，避免只保留页面顶部。</td></tr>
            <tr><td>超时</td><td>auto 或毫秒</td><td>auto 按视图数量计算；明确值需要在 10000–1800000 毫秒范围内。</td></tr>
            <tr><td>Vision bridge 路径</td><td>文件路径或留空</td><td>留空会自动编译或查找 bridge；只有自定义构建产物时才需要填写。</td></tr>
          </tbody>
        </table>
      </div>
    </>,
  },
  {
    id: "help-paddle-parameters",
    kicker: "04 / PaddleOCR",
    title: "PaddleOCR 参数具体含义",
    summary: "预设控制主要速度参数；自定义模式保留现有 v5/v6 配置，适合逐项调优。",
    keywords: "PaddleOCR PP-OCRv5 PP-OCRv6 模型版本 参数预设 性能 平衡 快速 自定义 medium small tiny detection recognition batch 批量 置信度 检测边长 文字块上限 profile device language timeout Python cache",
    icon: Gauge,
    content: <>
      <div className={styles.helpTableFrame}>
        <table className={styles.helpTable}>
          <caption className={styles.srOnly}>PaddleOCR 参数预设</caption>
          <thead><tr><th>预设</th><th>模型</th><th>检测最长边</th><th>识别 batch</th><th>最低置信度</th><th>文字块上限</th></tr></thead>
          <tbody>
            <tr><td>性能（质量优先）</td><td><code>PP-OCRv6_medium_det + PP-OCRv6_medium_rec</code></td><td>1280</td><td>4</td><td>0.05</td><td>不限</td></tr>
            <tr><td>平衡（推荐）</td><td><code>PP-OCRv6_small_det + PP-OCRv6_small_rec</code></td><td>960</td><td>8</td><td>0.10</td><td>256</td></tr>
            <tr><td>快速（低延迟）</td><td><code>PP-OCRv6_tiny_det + PP-OCRv6_tiny_rec</code></td><td>736</td><td>16</td><td>0.25</td><td>64</td></tr>
            <tr><td>自定义</td><td>用户当前 v5/v6 配置</td><td>用户配置</td><td>用户配置</td><td>用户配置</td><td>用户配置</td></tr>
          </tbody>
        </table>
      </div>
      <div className={styles.helpCallout} data-tone="warning">
        <strong>快速预设提示：</strong>tiny 模型、更小检测边长和更高置信度门槛会降低延迟与后续数据量，但复杂手写、很小的字和低置信度文字可能减少。命名预设默认强制使用 PP-OCRv6；需要继续使用 PP-OCRv5 时请选择“自定义”，再选择 PP-OCRv5 和对应性能档。
      </div>
      <dl className={styles.helpDefinitions}>
        <div><dt>参数预设</dt><dd>命名预设一次性切换模型、检测尺寸、识别 batch 和 evidence 过滤；自定义模式逐字段读取手动值。</dd></div>
        <div><dt>模型版本</dt><dd>选择 PP-OCRv5 或 PP-OCRv6。切换版本会清理已知的旧版本检测/识别模型覆盖，避免拼出 v5/v6 混合管线；PP-OCRv6 下的检测模型和识别模型可直接从对应档位下拉选择。</dd></div>
        <div><dt>兼容性能档</dt><dd>自定义模式下的旧版 fast、balanced、accurate 档，用于为未填写具体模型名的 v5/v6 配置提供默认模型。</dd></div>
        <div><dt>检测模型</dt><dd>定位页面中的文字区域并生成文字块坐标。PP-OCRv6 可选择 medium、small 或 tiny；模型越大通常越能保留细节，但下载、准备和推理成本也越高。</dd></div>
        <div><dt>识别模型</dt><dd>读取检测到的文字区域并输出文本。PP-OCRv6 可选择 medium、small 或 tiny；识别 batch 决定一次送入模型的文字裁剪数量。</dd></div>
        <div><dt>检测最长边</dt><dd>检测前将图像按最长边缩放到的尺寸，范围 320–4096；调小通常更快，但小字和密集排版可能丢失。</dd></div>
        <div><dt>识别批量大小</dt><dd>一次批量识别的文字块数量，范围 1–64；提高可能提升吞吐，但会增加 CPU 内存和瞬时负载。</dd></div>
        <div><dt>最低置信度</dt><dd>范围 0–1，低于阈值的文字块不会作为证据传给后续流程。它主要减少噪声和数据量，不直接减少已完成的模型计算。</dd></div>
        <div><dt>每个视图最多文字块</dt><dd>范围 0–10000，0 表示不限；超过上限时按页面均匀抽取，保持顶部、中部和底部的覆盖。</dd></div>
        <div><dt>识别语言</dt><dd>默认 `ch`，按 PaddleOCR 支持的语言代码填写；语言模型与场记文字匹配时更容易得到稳定结果。</dd></div>
        <div><dt>计算设备</dt><dd>默认 `cpu`。本项目当前按 CPU Worker 管理常驻模型，不建议随意填写未安装的设备后端。</dd></div>
        <div><dt>OCR 超时</dt><dd>auto 会按视图数量扩展；明确值范围为 10000–3600000 毫秒。模型首次下载或冷启动时应预留更长时间。</dd></div>
        <div><dt>Python 环境路径</dt><dd>留空使用项目内 `.venv-paddleocr/bin/python`；也可以填已经安装 PaddleOCR 的绝对路径。</dd></div>
        <div><dt>Paddle 模型缓存路径</dt><dd>留空使用稳定的应用缓存目录。保留缓存可以避免每次启动重新下载权重。</dd></div>
      </dl>
      <Text tone="subtle" size="xs">调速时优先调整模型档位、检测最长边和识别 batch；置信度与文字块上限主要影响证据过滤和后续请求体大小。</Text>
    </>,
  },
  {
    id: "help-runtime",
    kicker: "05 / 调优",
    title: "速度、运行参数与排查",
    summary: "冷启动慢通常来自模型下载和初始化；热启动会复用缓存与后台 Worker。",
    keywords: "速度 性能 冷启动 热启动 预加载 Worker 缓存 请求体 超时 重试 并行 页面 并行识别任务 排查 日志 失败",
    icon: CheckCircle2,
    content: <>
      <div className={styles.helpTableFrame}>
        <table className={styles.helpTable}>
          <caption className={styles.srOnly}>全局运行参数</caption>
          <thead><tr><th>参数</th><th>建议</th><th>影响</th></tr></thead>
          <tbody>
            <tr><td>模型请求超时（毫秒）</td><td>默认 180000</td><td>单次云端模型请求的等待上限；大图或高精度模式可适当提高。</td></tr>
            <tr><td>超时重试次数</td><td>0–3，默认 1</td><td>网络或服务端超时后的重试次数；重试会增加总耗时和可能的 API 消耗。</td></tr>
            <tr><td>并行提交页数</td><td>1–6，默认 2</td><td>同时发送给视觉模型的页面数量；遇到限流或内存压力时降低。</td></tr>
            <tr><td>并行识别任务数</td><td>1–16，默认 1</td><td>同时运行的识别任务数量；本机资源有限时保持 1。</td></tr>
            <tr><td>请求体上限（MB）</td><td>默认 80</td><td>限制传给 Main/模型请求的体积；大 PDF 或原始图片较多时不要盲目调大。</td></tr>
            <tr><td>Paddle 模型缓存路径</td><td>通常留空</td><td>缓存权重和运行资源；清理它会触发下一次重新下载或初始化。</td></tr>
          </tbody>
        </table>
      </div>
      <div className={styles.helpMiniGrid}>
        <div className={styles.helpMiniPanel}>
          <Text as="h3" size="sm" weight="bold">首次识别很慢</Text>
          <Text tone="muted" size="sm">先确认 PaddleOCR 模型缓存目录可写、网络可用，并在全局设置完成环境检查。应用启动后会后台预加载当前配置；首次下载完成后，后续任务通常会明显缩短准备阶段。</Text>
        </div>
        <div className={styles.helpMiniPanel}>
          <Text as="h3" size="sm" weight="bold">OCR 文字不完整</Text>
          <Text tone="muted" size="sm">先切换到“性能”或自定义更大的检测最长边，降低最低置信度并把文字块上限设为 0；如果是手写内容，不建议直接使用“快速”预设。</Text>
        </div>
        <div className={styles.helpMiniPanel}>
          <Text as="h3" size="sm" weight="bold">识别请求失败</Text>
          <Text tone="muted" size="sm">检查 Provider 是否已配置、模型是否支持图片、Base URL 是否正确，再查看左侧“日志”。如果只想测试本地流程，可以先载入场记 CSV 做本地合并。</Text>
        </div>
        <div className={styles.helpMiniPanel}>
          <Text as="h3" size="sm" weight="bold">如何判断是否用了 OCR？</Text>
          <Text tone="muted" size="sm">在全局设置查看“下一次识别将使用”和引擎状态；识别完成后任务的 OCR 摘要会记录引擎、模型、预设、文字块数量和耗时。</Text>
        </div>
      </div>
      <div className={styles.helpCallout} data-tone="accent">
        <strong>建议调优顺序：</strong>先确认路由和环境可用 → 选择合适模型档位 → 调整检测最长边 → 调整识别 batch → 最后才调整置信度和文字块上限。每次只改一组参数，并用相同页数的样本比较冷启动、热启动和识别耗时。
      </div>
    </>,
  },
];

function HelpSection({ section }: { section: HelpSection }) {
  const SectionIcon = section.icon;
  const headingId = `${section.id}-title`;
  return <Surface as="section" id={section.id} className={styles.helpSection} aria-labelledby={headingId}>
    <div className={styles.helpSectionHeader}>
      <div className={styles.helpSectionHeading}>
        <p className={styles.kicker}>{section.kicker}</p>
        <h2 id={headingId} className={styles.helpSectionTitle}>{section.title}</h2>
      </div>
      <Icon icon={SectionIcon} size={19} />
    </div>
    <p className={styles.helpSectionSummary}>{section.summary}</p>
    <div className={styles.helpSectionBody}>{section.content}</div>
  </Surface>;
}

export function HelpPage() {
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim().toLocaleLowerCase();
  const visibleSections = useMemo(() => {
    if (!normalizedQuery) return HELP_SECTIONS;
    return HELP_SECTIONS.filter((section) => `${section.kicker} ${section.title} ${section.summary} ${section.keywords}`.toLocaleLowerCase().includes(normalizedQuery));
  }, [normalizedQuery]);

  // The help page is intentionally local and stateless: search only filters the
  // documented sections, while native anchors keep keyboard and browser find
  // behavior predictable without adding another renderer/main contract.
  return <div className={styles.page}>
    <div className={styles.pageHeader}>
      <div><p className={styles.eyebrow}>使用指南</p><h1 className={styles.heading}>说明</h1><p className={styles.subtitle}>从第一次导入到 OCR 与大模型调优，快速找到 SlateSync 的使用方法和参数解释。</p></div>
      <div className={styles.pageActions}><Badge tone="accent" icon={BookOpen}>本地说明</Badge></div>
    </div>

    <Surface tone="accent" className={`${styles.panel} ${styles.helpSearchPanel}`}>
      <div className={styles.helpSearchHeader}>
        <div><p className={styles.kicker}>快速查找</p><Text as="h2" size="lg" weight="bold">搜索说明</Text></div>
        <Search size={19} aria-hidden="true" />
      </div>
      <div className={styles.helpSearchRow}>
        <Field label="关键词" hint="支持搜索 Provider、PaddleOCR、置信度、批量、导出等关键词。"><Input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="例如：模型版本、Base URL、检测最长边" autoComplete="off" /></Field>
        {query && <IconButton label="清空搜索" size="sm" onClick={() => setQuery("")}><X size={16} /></IconButton>}
      </div>
      <Text tone="subtle" size="xs" aria-live="polite">{normalizedQuery ? `找到 ${visibleSections.length} 个相关章节` : `共 ${HELP_SECTIONS.length} 个章节 · 也可以使用左侧目录跳转`}</Text>
    </Surface>

    <div className={styles.helpLayout}>
      <aside className={styles.helpAside}>
        <Surface as="nav" className={`${styles.panel} ${styles.helpToc}`} aria-label="说明目录">
          <p className={styles.kicker}>目录</p>
          <div className={styles.helpTocList}>
            {/* Keep the directory in sync with filtered content so every
                keyboard- and pointer-activated anchor has a mounted target. */}
            {visibleSections.map((section, index) => <a key={section.id} className={styles.helpTocLink} href={`#${section.id}`}><span>{String(index + 1).padStart(2, "0")}</span>{section.title}</a>)}
          </div>
        </Surface>
      </aside>
      <div className={styles.helpContent}>
        {visibleSections.length > 0
          ? visibleSections.map((section) => <HelpSection key={section.id} section={section} />)
          : <Surface className={`${styles.panel} ${styles.helpEmpty}`}><CircleHelp size={22} aria-hidden="true" /><Text as="h2" size="lg" weight="bold">没有匹配的说明</Text><Text tone="muted" size="sm">试试搜索“模型”“OCR”“Provider”或“导出”。</Text></Surface>}
      </div>
    </div>
  </div>;
}
