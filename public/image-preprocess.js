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

  const best = bands
    .filter((band) => band.activeCount >= 3)
    .sort((left, right) => {
      const leftSpan = left.end - left.start + 1;
      const rightSpan = right.end - right.start + 1;
      return rightSpan - leftSpan || right.activeCount - left.activeCount;
    })[0];
  const minimumHeight = Math.max(8, Math.round(height * minBandRatio));
  if (!best || best.end - best.start + 1 < minimumHeight) {
    return { top: 0, bottom: height, cropped: false };
  }

  const padding = Math.max(4, Math.round(height * paddingRatio));
  const top = Math.max(0, best.start - padding);
  const bottom = Math.min(height, best.end + padding + 1);
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
