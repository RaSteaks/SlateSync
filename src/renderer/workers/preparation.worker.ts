import * as pdfjs from "pdfjs-dist/legacy/build/pdf.mjs";
import pdfWorkerUrl from "pdfjs-dist/legacy/build/pdf.worker.mjs?url";
// The browser-safe compatibility module is the single source for crop and
// segmentation math used by both legacy and modern preparation paths.
// @ts-expect-error public compatibility modules intentionally ship as JS.
import { calculateCoreColumnWidth, calculateDetailSegments, findDenseRowBand, IMAGE_PREPROCESS_VERSION, preprocessImageData } from "../../../public/image-preprocess.js";

type ImagePreprocessOptions = {
  enabled?: boolean;
  grayscale?: boolean;
  contrast?: number;
  sharpen?: number;
  deskew?: boolean;
  deskewAngle?: number;
};
type PreprocessSummary = {
  version: string;
  applied: boolean;
  fallbackCount: number;
  deskewApplied: boolean;
  durationMs: number;
};
type PrepareMessage = { id: number; type?: "prepare"; fileType: string; data: ArrayBuffer; filename: string; preprocessOptions?: ImagePreprocessOptions };
type RecompressMessage = { id: number; type: "recompress"; imageDataGroups: string[][]; maxDimension: number; quality: number };
type ProgressMessage = { id: number; type: "progress"; progress: number; message: string };
type ResultMessage = { id: number; type: "result"; pageCount: number; imageDataGroups: string[][]; preprocess?: PreprocessSummary };
type RecompressedMessage = { id: number; type: "recompressed"; imageDataGroups: string[][] };
type ErrorMessage = { id: number; type: "error"; message: string };

const MAX_PDF_PAGES = 20;
// Vite fingerprints the nested pdf.js Worker as a packaged asset. Setting the
// URL inside this preparation Worker preserves pdf.js isolation in both
// file:// development and ASAR production without a Renderer-side fallback.
pdfjs.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;
const scope = self as unknown as {
  onmessage: ((event: MessageEvent<PrepareMessage | RecompressMessage>) => void) | null;
  postMessage(message: ProgressMessage | ResultMessage | RecompressedMessage | ErrorMessage): void;
};

async function blobToDataUrl(blob: Blob) {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  const chunkSize = 0x8000;
  for (let index = 0; index < bytes.length; index += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
  }
  return `data:${blob.type};base64,${btoa(binary)}`;
}

function context2d(canvas: OffscreenCanvas) {
  const context = canvas.getContext("2d", { alpha: false });
  if (!context) throw new Error("无法创建图像处理画布");
  return context;
}

function drawWhite(canvas: OffscreenCanvas) {
  const context = context2d(canvas);
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, canvas.width, canvas.height);
  return context;
}

function imageDataForCanvas(value: { data: Uint8ClampedArray; width: number; height: number }) {
  // `preprocessImageData` intentionally returns a plain object so it remains
  // Node-testable; turn it back into a platform ImageData only at the canvas
  // boundary inside the browser Worker.
  const imageData = new ImageData(value.width, value.height);
  imageData.data.set(value.data);
  return imageData;
}

function applyPreprocess(source: OffscreenCanvas, options?: ImagePreprocessOptions) {
  const started = performance.now();
  if (!options?.enabled) {
    return {
      canvas: source,
      summary: { version: IMAGE_PREPROCESS_VERSION, applied: false, fallbackCount: 0, deskewApplied: false, durationMs: 0 } satisfies PreprocessSummary,
    };
  }
  try {
    const context = context2d(source);
    const result = preprocessImageData(context.getImageData(0, 0, source.width, source.height), options);
    if (!result.metadata.applied && !result.metadata.fallback) {
      return {
        canvas: source,
        summary: { version: result.metadata.version, applied: false, fallbackCount: 0, deskewApplied: false, durationMs: Math.round(performance.now() - started) } satisfies PreprocessSummary,
      };
    }
    const output = new OffscreenCanvas(result.imageData.width, result.imageData.height);
    drawWhite(output).putImageData(imageDataForCanvas(result.imageData), 0, 0);
    return {
      canvas: output,
      summary: {
        version: result.metadata.version,
        applied: result.metadata.applied,
        fallbackCount: result.metadata.fallback ? 1 : 0,
        deskewApplied: result.metadata.deskewApplied,
        durationMs: Math.round(performance.now() - started),
      } satisfies PreprocessSummary,
    };
  } catch {
    // Optional quality stages cannot make input preparation fail; keep the
    // original pixels and surface the fallback in the preparation metadata.
    return {
      canvas: source,
      summary: { version: IMAGE_PREPROCESS_VERSION, applied: false, fallbackCount: 1, deskewApplied: false, durationMs: Math.round(performance.now() - started) } satisfies PreprocessSummary,
    };
  }
}

function mergePreprocessSummary(left: PreprocessSummary, right: PreprocessSummary): PreprocessSummary {
  return {
    version: right.version || left.version,
    applied: left.applied || right.applied,
    fallbackCount: left.fallbackCount + right.fallbackCount,
    deskewApplied: left.deskewApplied || right.deskewApplied,
    durationMs: left.durationMs + right.durationMs,
  };
}

async function rasterizeImage(data: ArrayBuffer, fileType: string, preprocessOptions?: ImagePreprocessOptions) {
  const bitmap = await createImageBitmap(new Blob([data], { type: fileType }));
  try {
    const scale = Math.min(1, 2600 / Math.max(bitmap.width, bitmap.height));
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = new OffscreenCanvas(width, height);
    drawWhite(canvas).drawImage(bitmap, 0, 0, width, height);
    // Keep the full page plus two header-repeated core crops for raster images,
    // matching the PDF path so high-accuracy mode can inspect small C0XX and
    // scene/shot/take cells without asking the model to upscale one JPEG.
    return preparePageViews(canvas, 0.92, 0.93, preprocessOptions);
  } finally {
    bitmap.close();
  }
}

async function recompressDataUrl(dataUrl: string, maxDimension: number, quality: number) {
  const response = await fetch(dataUrl);
  if (!response.ok) throw new Error("无法读取已准备的页面图像");
  const bitmap = await createImageBitmap(await response.blob());
  try {
    const scale = Math.min(1, maxDimension / Math.max(bitmap.width, bitmap.height));
    const canvas = new OffscreenCanvas(Math.max(1, Math.round(bitmap.width * scale)), Math.max(1, Math.round(bitmap.height * scale)));
    drawWhite(canvas).drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    return blobToDataUrl(await canvas.convertToBlob({ type: "image/jpeg", quality }));
  } finally {
    bitmap.close();
  }
}

async function recompressGroups(groups: string[][], maxDimension: number, quality: number, id: number) {
  const output: string[][] = [];
  const total = groups.reduce((count, group) => count + group.length, 0);
  let completed = 0;
  for (const group of groups) {
    const nextGroup: string[] = [];
    for (const dataUrl of group) {
      nextGroup.push(await recompressDataUrl(dataUrl, maxDimension, quality));
      completed += 1;
      scope.postMessage({ id, type: "progress", progress: Math.round((completed / Math.max(1, total)) * 100), message: `正在压缩页面视图 ${completed}/${total}` });
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
    }
    output.push(nextGroup);
  }
  return output;
}

function resizeCanvas(source: OffscreenCanvas, maxDimension: number, allowUpscale = false) {
  const scale = Math.min(allowUpscale ? Number.POSITIVE_INFINITY : 1, maxDimension / Math.max(source.width, source.height));
  if (scale === 1) return source;
  const output = new OffscreenCanvas(Math.max(1, Math.round(source.width * scale)), Math.max(1, Math.round(source.height * scale)));
  drawWhite(output).drawImage(source, 0, 0, output.width, output.height);
  return output;
}

function cropVerticalWhitespace(source: OffscreenCanvas) {
  const analysisWidth = Math.min(512, source.width);
  const analysisHeight = Math.max(1, Math.round((source.height * analysisWidth) / source.width));
  const analysis = new OffscreenCanvas(analysisWidth, analysisHeight);
  const analysisContext = drawWhite(analysis);
  analysisContext.drawImage(source, 0, 0, analysisWidth, analysisHeight);
  const bounds = findDenseRowBand(analysisContext.getImageData(0, 0, analysisWidth, analysisHeight));
  if (!bounds.cropped) return source;
  const top = Math.max(0, Math.floor((bounds.top * source.height) / analysisHeight));
  const bottom = Math.min(source.height, Math.ceil((bounds.bottom * source.height) / analysisHeight));
  const output = new OffscreenCanvas(source.width, Math.max(1, bottom - top));
  drawWhite(output).drawImage(source, 0, top, source.width, output.height, 0, 0, output.width, output.height);
  return output;
}

function detailComposite(source: OffscreenCanvas, header: { top: number; bottom: number }, segment: { top: number; bottom: number }) {
  const width = calculateCoreColumnWidth(source.width);
  const headerHeight = Math.max(1, header.bottom - header.top);
  const segmentHeight = Math.max(1, segment.bottom - segment.top);
  const output = new OffscreenCanvas(width, headerHeight + segmentHeight);
  const context = drawWhite(output);
  context.drawImage(source, 0, header.top, width, headerHeight, 0, 0, width, headerHeight);
  context.drawImage(source, 0, segment.top, width, segmentHeight, 0, headerHeight, width, segmentHeight);
  return output;
}

async function encodeCanvas(source: OffscreenCanvas, maxDimension: number, quality: number, allowUpscale = false) {
  const resized = resizeCanvas(source, maxDimension, allowUpscale);
  return blobToDataUrl(await resized.convertToBlob({ type: "image/jpeg", quality }));
}

async function preparePageViews(source: OffscreenCanvas, fullQuality: number, detailQuality: number, preprocessOptions?: ImagePreprocessOptions) {
  const prepared = applyPreprocess(source, preprocessOptions);
  const cropped = cropVerticalWhitespace(prepared.canvas);
  const layout = calculateDetailSegments(cropped.height);
  const output = [await encodeCanvas(cropped, 2600, fullQuality)];
  for (const segment of layout.segments) {
    const detail = detailComposite(cropped, layout.header, segment);
    output.push(await encodeCanvas(detail, 3000, detailQuality, true));
    // Yield between view encodes so a large still image does not monopolize
    // the preparation worker's event loop while progress UI remains responsive.
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  }
  return { views: output, preprocess: prepared.summary };
}

async function preparePdfPage(document: Awaited<ReturnType<typeof pdfjs.getDocument>["promise"]>, pageNumber: number, preprocessOptions?: ImagePreprocessOptions) {
  const page = await document.getPage(pageNumber);
  try {
    const baseViewport = page.getViewport({ scale: 1 });
    const scale = Math.min(4, 3000 / Math.max(baseViewport.width, baseViewport.height));
    const viewport = page.getViewport({ scale });
    const canvas = new OffscreenCanvas(Math.ceil(viewport.width), Math.ceil(viewport.height));
    const context = drawWhite(canvas);
    await page.render({ canvas: canvas as unknown as HTMLCanvasElement, canvasContext: context as unknown as CanvasRenderingContext2D, viewport, background: "#ffffff" }).promise;
    return preparePageViews(canvas, 0.92, 0.93, preprocessOptions);
  } finally {
    page.cleanup();
  }
}

async function rasterizePdf(data: ArrayBuffer, id: number, preprocessOptions?: ImagePreprocessOptions) {
  const document = await pdfjs.getDocument({ data: data.slice(0), isEvalSupported: false }).promise;
  if (!document.numPages) { await document.destroy(); throw new Error("PDF 中没有可识别的页面"); }
  if (document.numPages > MAX_PDF_PAGES) { await document.destroy(); throw new Error("PDF 最多支持 20 页，请拆分后重新上传"); }
  const groups: string[][] = [];
  let preprocess: PreprocessSummary = { version: IMAGE_PREPROCESS_VERSION, applied: false, fallbackCount: 0, deskewApplied: false, durationMs: 0 };
  try {
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
      const prepared = await preparePdfPage(document, pageNumber, preprocessOptions);
      groups.push(prepared.views);
      preprocess = mergePreprocessSummary(preprocess, prepared.preprocess);
      scope.postMessage({ id, type: "progress", progress: Math.round((pageNumber / document.numPages) * 100), message: `已生成 ${pageNumber}/${document.numPages} 页整页图与局部放大图` });
      // One-page batches keep pdf.js/canvas work outside the Renderer and
      // provide an explicit cancellation/resource-release boundary.
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
    }
  } finally {
    await document.destroy();
  }
  return { groups, preprocess };
}

scope.onmessage = (event) => {
  const message = event.data;
  const { id } = message;
  void (async () => {
    try {
      if (message.type === "recompress") {
        const imageDataGroups = await recompressGroups(message.imageDataGroups, message.maxDimension, message.quality, id);
        scope.postMessage({ id, type: "recompressed", imageDataGroups });
        return;
      }
      const { data, fileType, filename, preprocessOptions } = message;
      scope.postMessage({ id, type: "progress", progress: 5, message: `正在读取 ${filename}` });
      const isPdf = fileType === "application/pdf";
      let preprocess: PreprocessSummary = { version: IMAGE_PREPROCESS_VERSION, applied: false, fallbackCount: 0, deskewApplied: false, durationMs: 0 };
      let imageDataGroups: string[][];
      if (isPdf) {
        const prepared = await rasterizePdf(data, id, preprocessOptions);
        imageDataGroups = prepared.groups;
        preprocess = prepared.preprocess;
      } else {
        const prepared = await rasterizeImage(data, fileType, preprocessOptions);
        imageDataGroups = [prepared.views];
        preprocess = prepared.preprocess;
      }
      // The original PDF is only an input to local rasterization. Returning it
      // would reintroduce a model-side path that bypasses local OCR evidence.
      scope.postMessage({ id, type: "result", pageCount: imageDataGroups.length, imageDataGroups, preprocess });
    } catch (error) {
      const named = error as { name?: string; message?: string };
      const fileType = message.type === "recompress" ? "image/jpeg" : message.fileType;
      const errorMessage = named.name === "PasswordException"
        ? "PDF 已加密，请移除密码后再上传。"
        : `无法读取${fileType === "application/pdf" ? " PDF" : "图像"}：${named.message || "文件可能已损坏"}`;
      scope.postMessage({ id, type: "error", message: errorMessage });
    }
  })();
};
