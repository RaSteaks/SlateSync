export const REQUEST_SIZE_SAFETY_RATIO = 0.94;

export const REQUEST_COMPRESSION_PROFILES = [
  { maxDimension: 2200, quality: 0.82 },
  { maxDimension: 1800, quality: 0.74 },
  { maxDimension: 1500, quality: 0.68 },
];

export function serializeRecognitionRequest(input) {
  return JSON.stringify({
    provider: input.provider,
    model: input.model,
    filename: input.filename,
    imageDataGroups: input.imageDataGroups,
    pageCount: input.pageCount,
    accuracyMode: "high",
  });
}

export function requestBodyBytes(value) {
  return new Blob([value]).size;
}

export function requestBodyTargetBytes(maxRequestBytes) {
  return Math.floor(Number(maxRequestBytes) * REQUEST_SIZE_SAFETY_RATIO);
}

export function requestBodyFits(value, maxRequestBytes) {
  return requestBodyBytes(value) <= requestBodyTargetBytes(maxRequestBytes);
}
