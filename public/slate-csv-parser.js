// Renderer-side slate CSV parser with no Node.js API dependencies.

export function parseSlateCsv(text) {
  const lines = text.split(/\r?\n/).filter((line) => line.trim());
  if (lines.length < 2) {
    throw new Error("场记 CSV 为空或缺少数据行");
  }

  const headers = parseCsvLine(lines[0]);
  const fieldMap = mapSlateHeaders(headers);
  if (fieldMap.fileName == null) {
    throw new Error("场记 CSV 缺少 File Name 列");
  }

  const records = [];
  for (let i = 1; i < lines.length; i++) {
    const cells = parseCsvLine(lines[i]);
    const fileName = cells[fieldMap.fileName] || "";
    const scene = cells[fieldMap.scene] || null;
    const shot = cells[fieldMap.shot] || null;
    const take = cells[fieldMap.take] || null;
    const comments = cells[fieldMap.comments] || null;

    if (!scene && !shot && !take) continue;

    const materialKey = extractMaterialKey(fileName);
    records.push({
      fileName: fileName || null,
      materialKey,
      scene: scene || null,
      shot: shot || null,
      take: take || null,
      comments: normalizeSlateComments(comments),
      cameraFps: cells[fieldMap.cameraFps] || null,
      shootDay: cells[fieldMap.shootDay] || null,
    });
  }

  return { headers, records };
}

function mapSlateHeaders(headers) {
  const map = {};
  for (let i = 0; i < headers.length; i++) {
    const h = headers[i].trim().toLowerCase();
    if (h === "file name" || h === "filename" || h === "文件名") {
      map.fileName = i;
    } else if (h === "scene" || h === "场" || h === "场次" || h === "场景") {
      map.scene = i;
    } else if (h === "shot" || h === "镜" || h === "镜次") {
      map.shot = i;
    } else if (h === "take" || h === "次" || h === "镜头") {
      map.take = i;
    } else if (h === "comments" || h === "备注") {
      map.comments = i;
    } else if (h === "camera fps" || h === "camerafps" || h === "摄影机帧率") {
      map.cameraFps = i;
    } else if (h === "shoot day" || h === "shootday" || h === "拍摄日期") {
      map.shootDay = i;
    }
  }
  return map;
}

function extractMaterialKey(fileName) {
  if (!fileName) return null;
  let match = fileName.match(/([A-Z]\d+)_(C\d+)/i);
  if (match) return `${match[1].toUpperCase()}${match[2].toUpperCase()}`;
  match = fileName.match(/([A-Z]\d+)(C\d+)/i);
  if (match) return `${match[1].toUpperCase()}${match[2].toUpperCase()}`;
  return null;
}

function normalizeSlateComments(value) {
  if (!value) return null;
  const v = String(value).trim();
  if (!v) return null;
  if (/^_?OK$/i.test(v)) return "过";
  if (/^_?KP$/i.test(v)) return "保";
  if (/^_?NG$/i.test(v)) return "废条";
  if (/^(过|过条|好条)$/i.test(v)) return "过";
  if (/^(保|保条)$/i.test(v)) return "保";
  if (/^(废条|废|NG)$/i.test(v)) return "废条";
  return null;
}

function parseCsvLine(line) {
  const cells = [];
  let current = "";
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (inQuotes) {
      if (ch === '"') {
        if (i + 1 < line.length && line[i + 1] === '"') {
          current += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        current += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ",") {
      cells.push(current);
      current = "";
    } else {
      current += ch;
    }
  }
  cells.push(current);
  return cells;
}
