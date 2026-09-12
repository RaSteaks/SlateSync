// Client-side image preprocessing for slate page recognition.
//
// Finds the outer bounds of dense content bands on a scanned page (to crop dead
// margin), splits a page into header + overlapping body segments for higher
// detail, and computes the core-column crop width used by the "high accuracy"
// audit pass.
const DEFAULT_DARK_THRESHOLD = 225;
const DEFAULT_ROW_DENSITY = 0.02;

// Phase 05 quality stages are deliberately pure and opt-in. The fixed version
// string belongs in OCR cache metadata so changing the math cannot reuse an
// older recognition payload by accident.
export const IMAGE_PREPROCESS_VERSION = "slatesync-image-preprocess-v1";
export const DEFAULT_IMAGE_PREPROCESS_OPTIONS = Object.freeze({
  enabled: false,
  grayscale: false,
  contrast: 1.08,
  sharpen: 0.18,
  deskew: false,
  deskewAngle: 0,
});

export function analyzeImageQuality(imageData) {
  const { data, width, height } = imageData || {};
  if (!data || !width || !height) return { mean: 255, contrast: 0, score: 0 };
  let sum = 0;
  let sumSquares = 0;
  const count = Math.max(1, width * height);
  for (let offset = 0; offset < data.length; offset += 4) {
    const luminance = data[offset] * 0.299 + data[offset + 1] * 0.587 + data[offset + 2] * 0.114;
    sum += luminance;
    sumSquares += luminance * luminance;
  }
  const mean = sum / count;
  const variance = Math.max(0, sumSquares / count - mean * mean);
  const contrast = Math.sqrt(variance);
  // A bounded score is for diagnostics only; it never changes recognition.
  const score = Math.round(Math.min(1, contrast / 72) * 1000) / 1000;
  return { mean: Math.round(mean * 100) / 100, contrast: Math.round(contrast * 100) / 100, score };
}

export function preprocessImageData(imageData, options = {}) {
  const requested = { ...DEFAULT_IMAGE_PREPROCESS_OPTIONS, ...(options || {}) };
  const before = analyzeImageQuality(imageData);
  if (!requested.enabled) {
    return {
      imageData,
      metadata: {
        version: IMAGE_PREPROCESS_VERSION,
        applied: false,
        fallback: false,
        deskewApplied: false,
        qualityBefore: before,
        qualityAfter: before,
      },
    };
  }
  try {
    let output = cloneImageData(imageData);
    if (requested.grayscale) output = mapPixels(output, (r, g, b) => {
      const luminance = r * 0.299 + g * 0.587 + b * 0.114;
      return [luminance, luminance, luminance];
    });
    if (Number(requested.contrast) !== 1) output = mapPixels(output, (r, g, b) => [
      clampByte((r - 128) * Number(requested.contrast) + 128),
      clampByte((g - 128) * Number(requested.contrast) + 128),
      clampByte((b - 128) * Number(requested.contrast) + 128),
    ]);
    if (Number(requested.sharpen) > 0) output = sharpenImageData(output, Number(requested.sharpen));
    let deskewApplied = false;
    const angle = Number(requested.deskewAngle) || 0;
    if (requested.deskew && Math.abs(angle) > 0.01) {
      output = rotateImageDataExpanded(output, angle);
      deskewApplied = true;
    }
    return {
      imageData: output,
      metadata: {
        version: IMAGE_PREPROCESS_VERSION,
        applied: true,
        fallback: false,
        deskewApplied,
        qualityBefore: before,
        qualityAfter: analyzeImageQuality(output),
      },
    };
  } catch {
    // Recognition must continue with the original pixels if a browser/Worker
    // implementation rejects an optional enhancement stage.
    return {
      imageData,
      metadata: {
        version: IMAGE_PREPROCESS_VERSION,
        applied: false,
        fallback: true,
        deskewApplied: false,
        qualityBefore: before,
        qualityAfter: before,
      },
    };
  }
}

function cloneImageData(imageData) {
  return { data: new Uint8ClampedArray(imageData.data), width: imageData.width, height: imageData.height };
}

function mapPixels(imageData, transform) {
  const output = cloneImageData(imageData);
  for (let offset = 0; offset < output.data.length; offset += 4) {
    const [r, g, b] = transform(output.data[offset], output.data[offset + 1], output.data[offset + 2]);
    output.data[offset] = clampByte(r);
    output.data[offset + 1] = clampByte(g);
    output.data[offset + 2] = clampByte(b);
  }
  return output;
}

function sharpenImageData(imageData, amount) {
  const source = imageData.data;
  const output = cloneImageData(imageData);
  const strength = Math.min(1, Math.max(0, amount));
  for (let y = 1; y < imageData.height - 1; y += 1) {
    for (let x = 1; x < imageData.width - 1; x += 1) {
      const center = (y * imageData.width + x) * 4;
      for (let channel = 0; channel < 3; channel += 1) {
        const blurred = (source[(y - 1) * imageData.width * 4 + x * 4 + channel]
          + source[(y + 1) * imageData.width * 4 + x * 4 + channel]
          + source[y * imageData.width * 4 + (x - 1) * 4 + channel]
          + source[y * imageData.width * 4 + (x + 1) * 4 + channel]) / 4;
        output.data[center + channel] = clampByte(source[center + channel] + (source[center + channel] - blurred) * strength);
      }
    }
  }
  return output;
}

function rotateImageDataExpanded(imageData, degrees) {
  const radians = degrees * Math.PI / 180;
  const cosine = Math.abs(Math.cos(radians));
  const sine = Math.abs(Math.sin(radians));
  const width = Math.max(1, Math.ceil(imageData.width * cosine + imageData.height * sine));
  const height = Math.max(1, Math.ceil(imageData.width * sine + imageData.height * cosine));
  const output = { data: new Uint8ClampedArray(width * height * 4), width, height };
  output.data.fill(255);
  const cos = Math.cos(radians);
  const sin = Math.sin(radians);
  const sourceCenterX = (imageData.width - 1) / 2;
  const sourceCenterY = (imageData.height - 1) / 2;
  const targetCenterX = (width - 1) / 2;
  const targetCenterY = (height - 1) / 2;
  for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) {
    const translatedX = x - targetCenterX;
    const translatedY = y - targetCenterY;
    const sourceX = Math.round(translatedX * cos + translatedY * sin + sourceCenterX);
    const sourceY = Math.round(-translatedX * sin + translatedY * cos + sourceCenterY);
    if (sourceX < 0 || sourceY < 0 || sourceX >= imageData.width || sourceY >= imageData.height) continue;
    const sourceOffset = (sourceY * imageData.width + sourceX) * 4;
    const targetOffset = (y * width + x) * 4;
    output.data.set(imageData.data.slice(sourceOffset, sourceOffset + 4), targetOffset);
  }
  return output;
}

function clampByte(value) { return Math.max(0, Math.min(255, Math.round(Number(value) || 0))); }

export function findDenseRowBand(
  imageData,
  {
    darkThreshold = DEFAULT_DARK_THRESHOLD,
    rowDensity = DEFAULT_ROW_DENSITY,
    maxGapRatio = 0.025,
    minBandRatio = 0.12,
    paddingRatio = 0.025,
  } = {},
) {
  const { data, width, height } = imageData || {};
  if (!data || !Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1) {
    return { top: 0, bottom: Math.max(0, Number(height) || 0), cropped: false };
  }

  const minimumDarkPixels = Math.max(4, Math.round(width * rowDensity));
  const activeRows = [];
  for (let y = 0; y < height; y += 1) {
    let darkPixels = 0;
    const rowOffset = y * width * 4;
    for (let x = 0; x < width; x += 1) {
      const offset = rowOffset + x * 4;
      const luminance =
        data[offset] * 0.299 +
        data[offset + 1] * 0.587 +
        data[offset + 2] * 0.114;
      if (luminance < darkThreshold) darkPixels += 1;
    }
    if (darkPixels >= minimumDarkPixels) activeRows.push(y);
  }

  if (!activeRows.length) {
    return { top: 0, bottom: height, cropped: false };
  }

  const maximumGap = Math.max(3, Math.round(height * maxGapRatio));
  const bands = [];
  let start = activeRows[0];
  let end = activeRows[0];
  let activeCount = 1;

  for (const row of activeRows.slice(1)) {
    if (row - end <= maximumGap) {
      end = row;
      activeCount += 1;
      continue;
    }
    bands.push({ start, end, activeCount });
    start = row;
    end = row;
    activeCount = 1;
  }
  bands.push({ start, end, activeCount });

  // Keep the outer bounds of every supported content band. A slate may put a
  // title/header and its table in separate bands with a large blank gap; using
  // only the largest band would silently delete valid recognition input.
  const contentBands = bands.filter((band) => band.activeCount >= 3);
  const firstBand = contentBands[0];
  const lastBand = contentBands[contentBands.length - 1];
  const minimumHeight = Math.max(8, Math.round(height * minBandRatio));
  if (!firstBand || !lastBand || lastBand.end - firstBand.start + 1 < minimumHeight) {
    return { top: 0, bottom: height, cropped: false };
  }

  const padding = Math.max(4, Math.round(height * paddingRatio));
  const top = Math.max(0, firstBand.start - padding);
  const bottom = Math.min(height, lastBand.end + padding + 1);
  const savedHeight = height - (bottom - top);
  if (savedHeight < height * 0.08) {
    return { top: 0, bottom: height, cropped: false };
  }

  return { top, bottom, cropped: true };
}

export function calculateDetailSegments(
  height,
  {
    headerRatio = 0.22,
    overlapRatio = 0.045,
  } = {},
) {
  const normalizedHeight = Math.max(1, Math.round(Number(height) || 1));
  const headerBottom = Math.max(
    1,
    Math.min(normalizedHeight, Math.round(normalizedHeight * headerRatio)),
  );
  const bodyHeight = Math.max(1, normalizedHeight - headerBottom);
  const midpoint = headerBottom + Math.round(bodyHeight / 2);
  const overlap = Math.max(1, Math.round(normalizedHeight * overlapRatio));

  return {
    header: { top: 0, bottom: headerBottom },
    segments: [
      {
        top: headerBottom,
        bottom: Math.min(normalizedHeight, midpoint + overlap),
      },
      {
        top: Math.max(headerBottom, midpoint - overlap),
        bottom: normalizedHeight,
      },
    ],
  };
}

export function calculateCoreColumnWidth(width, ratio = 0.62) {
  const normalizedWidth = Math.max(1, Math.round(Number(width) || 1));
  const normalizedRatio = Number.isFinite(Number(ratio))
    ? Math.min(1, Math.max(0.5, Number(ratio)))
    : 0.62;
  return Math.max(1, Math.round(normalizedWidth * normalizedRatio));
}
