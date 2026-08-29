// Client-side image preprocessing for slate page recognition.
//
// Finds the outer bounds of dense content bands on a scanned page (to crop dead
// margin), splits a page into header + overlapping body segments for higher
// detail, and computes the core-column crop width used by the "high accuracy"
// audit pass.
const DEFAULT_DARK_THRESHOLD = 225;
const DEFAULT_ROW_DENSITY = 0.02;

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
