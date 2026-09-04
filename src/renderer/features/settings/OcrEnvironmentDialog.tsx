import { CheckCircle2, Download, Loader2, Monitor, RefreshCw, Terminal, Wrench } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import type { OcrEnvironmentSnapshot, VisionOcrCheckResult } from "../../../shared/contracts/index.js";
import { Badge, Button, Dialog, Icon, InlineError, Progress, Stack, StatusIndicator, Surface, Text } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import styles from "../../app/app.module.css";
import { engineStatusLabel, engineStatusTone, engineStatus, type PaddleOcrInstallState } from "./ocrEngineStatus";

type EnvironmentState = "idle" | "loading" | "loaded" | "error";

interface OcrEnvironmentDialogProps {
  open: boolean;
  onClose: () => void;
  config: Parameters<typeof engineStatus>[0];
  paddleInstallState: PaddleOcrInstallState;
  paddleInstallProgress: { stage: string; percent: number; message: string } | null;
  paddleInstallError: string | null;
  onInstallPaddleOcr: () => void;
  onCancelPaddleOcrInstall: () => void;
  visionCheck: VisionOcrCheckResult | null;
  visionCheckState: "idle" | "checking" | "checked";
  onCheckVision: () => void;
}

function visionSourceLabel(source: OcrEnvironmentSnapshot["vision"]["source"]): string {
  if (source === "explicit") return "已配置 VISIONOCR_BINARY";
  if (source === "bundled") return "打包内置 bridge";
  if (source === "local-build") return "开发环境本地编译";
  return "未找到";
}

function pythonStatusLabel(python: OcrEnvironmentSnapshot["python"]): { label: string; tone: "neutral" | "success" | "warning" | "danger" } {
  if (python.found && python.meetsMinimum) return { label: `满足要求 · ${python.version}`, tone: "success" };
  if (python.found) return { label: `版本过低 · ${python.version}`, tone: "warning" };
  if (python.error) return { label: "不可用", tone: "danger" };
  return { label: "未检测", tone: "neutral" };
}

export function OcrEnvironmentDialog({
  open,
  onClose,
  config,
  paddleInstallState,
  paddleInstallProgress,
  paddleInstallError,
  onInstallPaddleOcr,
  onCancelPaddleOcrInstall,
  visionCheck,
  visionCheckState,
  onCheckVision,
}: OcrEnvironmentDialogProps) {
  const [environment, setEnvironment] = useState<OcrEnvironmentSnapshot | null>(null);
  const [environmentState, setEnvironmentState] = useState<EnvironmentState>("idle");
  const [environmentError, setEnvironmentError] = useState<string | null>(null);

  const reloadEnvironment = useCallback(async () => {
    setEnvironmentState("loading");
    setEnvironmentError(null);
    try {
      const api = getSlateSync();
      if (typeof api.settings?.getOcrEnvironment !== "function") {
        throw new Error("当前 Renderer 与 Preload 版本不一致，无法检测 OCR 环境。请完全退出 SlateSync 后重新启动；不要只刷新窗口。");
      }
      setEnvironment(await unwrap(await api.settings.getOcrEnvironment()));
      setEnvironmentState("loaded");
    } catch (error) {
      setEnvironment(null);
      setEnvironmentError(appErrorFromUnknown(error).message);
      setEnvironmentState("error");
    }
  }, []);

  // Re-probe on every open and after a successful PaddleOCR install so the
  // detection result always reflects the machine as it is right now.
  useEffect(() => {
    if (!open) return;
    void reloadEnvironment();
  }, [open, reloadEnvironment]);

  useEffect(() => {
    if (paddleInstallState !== "installed") return;
    void reloadEnvironment();
  }, [paddleInstallState, reloadEnvironment]);

  if (!open) return null;

  const vision = engineStatus(config, "vision");
  const paddle = engineStatus(config, "paddleocr");
  const visionEnvironment = environment?.vision;
  const paddleEnvironment = environment?.paddle;
  const pythonRow = environment ? pythonStatusLabel(environment.python) : null;
  const visionReady = Boolean(visionEnvironment?.binaryExists || visionEnvironment?.swiftToolchain);

  return <Dialog
    open={open}
    onClose={onClose}
    size="wide"
    title="OCR 环境检测与下载"
    description="检测本机可用的本地 OCR 引擎；缺失的引擎可以在这里直接下载安装。"
    footer={<Stack direction="row" justify="end" gap={2} wrap>
      <Button variant="secondary" loading={environmentState === "loading"} onClick={() => void reloadEnvironment()} startIcon={<RefreshCw size={15} />}>重新检测</Button>
      <Button onClick={onClose}>关闭</Button>
    </Stack>}
  >
    <Stack direction="column" gap={4}>
      {environmentError && <InlineError message={environmentError} onRetry={() => void reloadEnvironment()} />}
      {environmentState === "loading" && !environment && <div className={styles.ocrEnvironmentPending} role="status" aria-live="polite">
        <Icon icon={Loader2} size={16} /> 正在检测本机 OCR 环境…
      </div>}

      {environment && <Surface className={styles.ocrEnvironmentMachine} aria-labelledby="ocr-environment-machine-title">
        <div className={styles.ocrEnvironmentMachineHeader}>
          <Text as="h3" id="ocr-environment-machine-title" size="md" weight="bold"><Icon icon={Monitor} size={15} /> 本机环境</Text>
          {environment.packaged ? <Badge tone="neutral">打包版</Badge> : <Badge tone="neutral">开发版</Badge>}
        </div>
        <dl className={styles.ocrEnvironmentGrid}>
          <div className={styles.ocrEnvironmentItem}>
            <dt>操作系统</dt>
            <dd>{environment.platformLabel}</dd>
          </div>
          <div className={styles.ocrEnvironmentItem}>
            <dt>处理器架构</dt>
            <dd>{environment.architectureLabel}</dd>
          </div>
          <div className={styles.ocrEnvironmentItem}>
            <dt>Python</dt>
            <dd>
              <Stack direction="row" justify="end" align="center" gap={2} wrap>
                <StatusIndicator tone={pythonRow?.tone ?? "neutral"} label={pythonRow?.label ?? "未检测"} />
                {environment.python.command && <Text tone="subtle" size="xs" mono>（{environment.python.command}）</Text>}
              </Stack>
            </dd>
          </div>
          {environment.python.error && <div className={`${styles.ocrEnvironmentItem} ${styles.ocrEnvironmentItemFull}`}>
            <dt>说明</dt>
            <dd>{environment.python.error}</dd>
          </div>}
        </dl>
      </Surface>}

      <div className={styles.ocrEngineGrid}>
        <article className={styles.ocrEngineCard} aria-labelledby="ocr-environment-vision-title">
          <div className={styles.ocrEngineHeader}>
            <div>
              <Text as="h3" id="ocr-environment-vision-title" size="md" weight="bold">Apple Vision OCR</Text>
              <Text tone="muted" size="sm">macOS 系统内置，无需下载；缺少 bridge 时开发环境可自动编译。</Text>
            </div>
            <StatusIndicator tone={engineStatusTone(vision)} label={engineStatusLabel(vision)} />
          </div>
          {visionEnvironment && <dl className={styles.ocrEngineDetails}>
            <div><dt>bridge 状态</dt><dd>{visionEnvironment.binaryExists ? "已就绪" : visionEnvironment.swiftToolchain ? "可用 swiftc 自动编译" : "未找到"}</dd></div>
            <div><dt>能力来源</dt><dd>{visionSourceLabel(visionEnvironment.source)}</dd></div>
            {visionEnvironment.binaryPath && <div><dt>bridge 路径</dt><dd className={styles.ocrEnvironmentPath}>{visionEnvironment.binaryPath}</dd></div>}
          </dl>}
          {visionCheck?.ok === true && <div className={styles.ocrCheckResult} data-tone="success" role="status">
            <Text tone="success" size="sm"><Icon icon={CheckCircle2} size={15} /> 运行检查通过 · {visionCheck.engine} {visionCheck.modelVersion}</Text>
          </div>}
          {visionCheck?.ok === false && <div className={styles.ocrCheckResult} data-tone="danger" role="alert">
            <Text tone="danger" size="sm">运行检查失败 · {visionCheck.error.message}</Text>
          </div>}
          <Stack direction="row" justify="between" align="center" wrap>
            <Text tone="subtle" size="xs">{visionCheckState === "idle" ? "尚未执行运行检查" : visionCheckState === "checking" ? "正在启动 Vision bridge…" : visionCheck?.ok ? "最近检查通过" : "最近检查失败"}</Text>
            <Button size="sm" variant="secondary" loading={visionCheckState === "checking"} onClick={onCheckVision} startIcon={<Wrench size={15} />}>检查 Vision OCR</Button>
          </Stack>
        </article>

        <article className={styles.ocrEngineCard} aria-labelledby="ocr-environment-paddle-title">
          <div className={styles.ocrEngineHeader}>
            <div>
              <Text as="h3" id="ocr-environment-paddle-title" size="md" weight="bold">PaddleOCR</Text>
              <Text tone="muted" size="sm">Python 本地引擎，需要一次性下载运行环境与模型。</Text>
            </div>
            <StatusIndicator tone={engineStatusTone(paddle)} label={engineStatusLabel(paddle)} />
          </div>
          {paddleEnvironment && <dl className={styles.ocrEngineDetails}>
            <div>
              <dt>生效解释器</dt>
              <dd className={styles.ocrEnvironmentPath}>
                {paddleEnvironment.activePythonPath
                  ? paddleEnvironment.activePythonExists
                    ? paddleEnvironment.activePythonPath
                    : `${paddleEnvironment.activePythonPath}（未找到）`
                  : "自动发现（python3）"}
              </dd>
            </div>
            {paddleEnvironment.configuredPythonPath && <div><dt>路径来源</dt><dd>全局设置 · PADDLEOCR_PYTHON</dd></div>}
            <div><dt>一键安装目标</dt><dd>{paddleEnvironment.venvExists ? "已安装" : "未安装"} · <span className={styles.ocrEnvironmentPath}>{paddleEnvironment.pythonPath || "—"}</span></dd></div>
          </dl>}
          {paddleInstallState === "installing" && <div className={styles.ocrInstallFeedback} data-tone="accent" role="status" aria-live="polite">
            <div className={styles.ocrInstallFeedbackHeader}>
              <div className={styles.ocrInstallFeedbackCopy}>
                <Text tone="accent" size="sm" weight="bold">正在安装 PaddleOCR</Text>
                <Text tone="muted" size="xs">{paddleInstallProgress?.message || "正在准备安装环境…"}</Text>
              </div>
              <Button size="sm" variant="ghost" onClick={onCancelPaddleOcrInstall}>取消安装</Button>
            </div>
            <Progress
              value={paddleInstallProgress?.percent ?? 0}
              label={`PaddleOCR 安装进度 ${Math.round(paddleInstallProgress?.percent ?? 0)}%`}
            />
          </div>}
          {paddleInstallState === "installed" && <div className={styles.ocrInstallFeedback} data-tone="success" role="status">
            <Text tone="success" size="sm"><Icon icon={CheckCircle2} size={15} /> PaddleOCR 已安装并验证通过，后续识别可以直接使用。</Text>
          </div>}
          {paddleInstallState === "canceled" && <div className={styles.ocrInstallFeedback} data-tone="warning" role="status">
            <Text tone="warning" size="sm">安装已取消；已创建的运行环境会在下次安装时复用。</Text>
          </div>}
          {paddleInstallState === "error" && paddleInstallError && <div className={styles.ocrInstallFeedback} data-tone="danger">
            <InlineError message={paddleInstallError} onRetry={onInstallPaddleOcr} />
          </div>}
          <Stack direction="row" justify="between" align="center" wrap>
            <Text tone={paddleEnvironment?.configuredPythonPath && paddleEnvironment?.activePythonExists === false ? "warning" : "subtle"} size="xs">
              {paddleEnvironment?.configuredPythonPath
                ? paddleEnvironment?.activePythonExists
                  ? "已使用全局设置中固定的 Python 路径；一键安装写入应用自有目录，不会覆盖当前配置。"
                  : "固定的 Python 路径当前不存在，请检查该路径或重新安装。"
                : paddleEnvironment?.venvExists
                  ? "运行环境已就绪；如需重装可再次执行安装。"
                  : "尚未检测到安装好的 PaddleOCR 运行环境。"}
            </Text>
            <Button
              size="sm"
              variant={paddleEnvironment?.venvExists || paddleEnvironment?.activePythonExists ? "secondary" : "primary"}
              loading={paddleInstallState === "installing"}
              onClick={onInstallPaddleOcr}
              startIcon={<Download size={15} />}
            >
              {paddleInstallState === "installed" || paddleEnvironment?.venvExists ? "重新安装 PaddleOCR" : "安装 PaddleOCR"}
            </Button>
          </Stack>
        </article>
      </div>

      <Text tone="subtle" size="xs" className={styles.ocrFootnote}>
        <Icon icon={Terminal} size={13} /> 检测只读取系统信息，不会上传任何数据；PaddleOCR 安装在本机应用数据目录中完成。
        {visionReady ? "" : " 若本机从未安装过任何本地 OCR，识别仍可使用多模态模型完成。"}
      </Text>
    </Stack>
  </Dialog>;
}
