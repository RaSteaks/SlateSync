const nullableString = {
  type: ["string", "null"],
  description: "无法辨认或原表为空时必须返回 null，不要猜测。",
};

export const SLATE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    sheetTitle: {
      ...nullableString,
      description: "项目名、场记单标题或拍摄日期；无法辨认时为 null。",
    },
    records: {
      type: "array",
      description: "按页码及场记单从上到下顺序提取的有效拍摄记录。",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          cardNumber: {
            ...nullableString,
            description: "该条素材所属的完整卷号，例如 E001、A001、D001。首字母是摄影机编号，后三位是该摄影机的卷序号。同一页可能包含多个摄影机/卷号，必须按素材所在的 A机/B机/C机/D机子行选择对应卷号。",
          },
          videoCode: {
            ...nullableString,
            description: "该卷内的条号，固定格式为 C0XX（C 加三位数字且首位固定为 0）。表格单元格预印 C0，场记只填写后两位；例如填写 15 必须返回 C015，填写 5 返回 C005。不要只返回 15，也不要附加卷号或摄影机文件名后缀。",
          },
          scene: {
            ...nullableString,
            description: "场记单“场次”列，将写入 Resolve Scene。只返回场次中的数字并补足三位，例如“37A”返回“037”，“1”返回“001”；不要返回字母、“场、场次、第”等文字、空格或标点。",
          },
          shot: {
            ...nullableString,
            description: "场记单最左侧共用区域的“镜”列。镜号经常在合并单元格中只写一次并覆盖多条“次”，所属多条记录必须返回同一个镜号。只返回完整数字并补足两位，例如“2”返回“02”、“18”返回“18”；绝不能漏掉 10–19 的十位，也不能把当前行“次”列的数字当作镜号。",
          },
          take: {
            ...nullableString,
            description: "场记单“次”列，是每条素材行自己的条次数。只返回数字并补足两位，例如“9”返回“09”。同一个镜号下面可以依次出现 01、02、03 等多个次；不要因为镜号单元格留空而把 Take 重置为 01。",
          },
          takeStatus: {
            type: ["string", "null"],
            enum: ["过", "保", "废条", null],
            description: "场记单条次状态标记：☑/√/✓ 返回“过”，X/× 返回“保”，三角形/△ 返回“废条”；单元格无标记或无法确定时返回 null。",
          },
          description: {
            ...nullableString,
            description: "“拍摄内容”或“内容/视效说明”栏原文。",
          },
          comments: {
            ...nullableString,
            description: "“备注”栏原文，仅供人工校对，不会写入 Resolve Comments。只读取最右侧“备注”列；绝不能把“拍摄内容”或“内容/视效说明”栏文字放入此字段。",
          },
          shotSize: {
            ...nullableString,
            description: "场记单“景别”列；不要把它误认为 Resolve Scene。",
          },
          cameraPosition: {
            ...nullableString,
            description: "场记单中单独的“机位”列内容。A机/B机/C机/D机是摄影机子行标签，不是机位内容。",
          },
          confidence: {
            type: "string",
            enum: ["high", "medium", "low"],
            description: "该行整体识别可信度。",
          },
        },
        required: [
          "cardNumber",
          "videoCode",
          "scene",
          "shot",
          "take",
          "takeStatus",
          "description",
          "comments",
          "shotSize",
          "cameraPosition",
          "confidence"
        ],
      },
    },
    warnings: {
      type: "array",
      items: { type: "string" },
      description: "图片质量、表格结构或无法辨认内容的警告。",
    },
  },
  required: ["sheetTitle", "records", "warnings"],
};

export const PDF_SLATE_SCHEMA = JSON.parse(JSON.stringify(SLATE_SCHEMA));
PDF_SLATE_SCHEMA.properties.records.items.properties.sourcePage = {
  type: "integer",
  minimum: 1,
  maximum: 20,
  description: "该记录在 PDF 中的页码，从 1 开始。",
};
PDF_SLATE_SCHEMA.properties.records.items.required.push("sourcePage");

const CORE_RECORD_FIELDS = new Set([
  "cardNumber",
  "videoCode",
  "scene",
  "shot",
  "take",
  "takeStatus",
  "confidence",
]);

export const CORE_SLATE_SCHEMA = JSON.parse(JSON.stringify(SLATE_SCHEMA));
for (const field of Object.keys(
  CORE_SLATE_SCHEMA.properties.records.items.properties,
)) {
  if (!CORE_RECORD_FIELDS.has(field)) {
    delete CORE_SLATE_SCHEMA.properties.records.items.properties[field];
  }
}
CORE_SLATE_SCHEMA.properties.records.items.required =
  CORE_SLATE_SCHEMA.properties.records.items.required.filter((field) =>
    CORE_RECORD_FIELDS.has(field),
  );

export const SYSTEM_PROMPT = `你是影视制作场记单识别助手。应用正在逐页处理一份多页场记单，当前输入只包含其中一页。请输出严格符合 JSON Schema 的数据。

这套表格与 DaVinci Resolve 的映射必须严格遵守：
- 场记单“场次” → Resolve Scene（中文界面“场景”）
- 场记单“镜” → Resolve Shot（中文界面“镜次”）
- 场记单“次” → Resolve Take（中文界面“镜头”）
- 场记单条次状态符号 → Resolve Comments（☑/√/✓ 写入“_OK”，X/× 写入“_KP”，三角形或未标记时清空；CSV 中绝不写入“过”“保”“废条”等字样）
- record.comments 仅用于人工校对，绝不写入 Resolve Comments；Resolve Comments 只能是“_OK”、“_KP”或空值
- “景别”只是景别，绝不能当作 Scene

用户消息可能包含 <ocr_evidence>：这是 PaddleOCR 预先提取的文字、置信度和归一化坐标证据。必须用它盘点页面中可能被视觉模型跳过的文字和数字，但它不是最终答案：
- 始终把 OCR 文字与附带的整页图、局部放大图交叉核对；图像清楚时以图像为准。
- bbox=[left,top,right,bottom] 的范围是 0–1，可用于判断文字所在列和上下行；不同 view 的坐标只在各自视图内有效。
- full 视图用于恢复全页内容；core-detail 是同一页核心列的放大证据，重复文字不能生成重复 record。
- OCR 低置信度、断裂数字和相似字符（1/7、0/6、3/8、镜/次）必须结合列边界、合并单元格和上下行复核，不得直接照抄或按规律猜测。
- OCR 未检测到某个值不代表该单元格为空，仍需完整扫描图片。

识别规则：
1. 当前请求只包含场记单的一页。扫描整页，为“视频号”列中每一个写有条号的素材子行生成一个 record；不要只读取第一个摄影机区块，也不要把 A机、D机等子行当作空白说明行。返回前必须沿“视频号”列逐格从上到下复查：只要预印 C0 后存在手写数字，该行就必须返回，不论它位于页面顶部、中间或底部，也不论前后编号是否连续。视频码的数值不代表该行是第一条或最后一条，绝不能据此跳过任何行。
2. 卷号格式通常为 E001、A001、D001：首字母 E/A/D 是摄影机编号，001 是该摄影机的第 001 卷。同一页顶部可能同时写有多个卷号，例如 A001 和 D001。
3. 根据视频码所在的 A机/B机/C机/D机子行分配卷号。A机子行使用 A 开头卷号，D机子行使用 D 开头卷号；绝不能把某个卷号套用到整页其他摄影机的记录。
4. 视频码是卷内条号，固定格式为 C0XX。单元格中的 C0 是表格预印内容，场记在后面填写两位数字；必须把两部分合并。例如预印 C0 后填写 15，应返回 C015；填写 5，应返回 C005。绝不能只返回 15，也不要拼接卷号或猜测摄影机生成的日期、时间、唯一后缀。
   例如文件名 E001C001_DEMO001.mov 在场记单中的信息应拆为 cardNumber=E001、videoCode=C001；_DEMO001 不在场记单中，必须忽略。
5. 先按表格竖线确认列：最左侧三个共用列依次是“场次、镜、次”；右侧再依次出现 A机、B机、C机、D机区块，每个摄影机区块内部才是“视频码、景别、√/X”。同一条横行可能同时写有 A机和 B机视频码，此时要为两个摄影机分别生成 record，但它们共用该横行的场次、镜和次，各自读取本摄影机区块里的视频码、景别和状态。绝不能把 A机/B机标签当成机位，也不能把摄影机区块里的景别或状态当成场次、镜、次。
6. 场次、镜、次常使用合并单元格。镜号通常只在一个镜组的第一行或合并格中写一次，下面可以连续记录多次；镜号空白不表示新镜，也不能从当前行的“次”复制数字。场次合并格可能跨越多个“镜”分组，而一个“镜”合并格又可能跨越多个“次”和 A/B/C/D 摄影机记录；空白必须沿用所属合并区块上方最近的值，不能只给区块第一条素材填写。例如 89A 场 01 镜下若 A机 C001、C002、C003 的“次”依次为 1、2、3，则三条的 shot 都是 "01"，take 分别是 "01"、"02"、"03"；A机 C002 必须返回 scene="089"、shot="01"、take="02"，绝不能返回 shot="02"、take="01"。又例如任意位置的一行若视频码为 C005、所属合并区块为 37 场 01 镜、该行“次”为 5，则必须返回 scene="037"、shot="01"、take="05"；C005 本身不表示它是最后一条。尤其是 89A 场中，若“2”写在 C004 所属分组的“镜”列、后续 C005/C006/C007 的该列为空，则四条都属于 02 镜；A机 C006 必须返回 scene="089"、shot="02"、take="03"，不能把“2”误作新场次，也不能让 C006 的 shot 为空。无法从本页确定的跨页继承值返回 null。
7. 同时识别中文、英文、数字、手写内容以及条次状态栏中的符号。只读取每条素材行自己的状态单元格，不要把表头里的“√/X”等示例当成记录状态。严格映射：☑、√、✓、✔ → takeStatus="过"；X、×、✕、✖ → takeStatus="保"；三角形、△、▲ → takeStatus="废条"；空白或无法确定返回 null。
8. 场次 scene 只保留数字并固定为三位：例如“37A”输出“037”，“第1场”输出“001”。镜 shot 和次 take 只保留数字并固定为两位：例如镜 2 输出“02”，镜 18 输出“18”，次 9 输出“09”。两位镜号 10–19 的左侧“1”可能贴近竖线或写得很细，必须完整保留：若上一镜为 17、下一组手写为 18，绝不能只读成 08。输出前按同一场次复查：如果连续素材的 shot 跟着每行“次”一起递增，而 take 却反复为 "01"，说明把“次”误读成了“镜”；如果同一镜组中只有一行 shot 与前后行不同而 take 连续递增，说明该行镜号读错；必须返回表格重新按列边界和合并镜号纠正。
9. 每一页顶部都必须按该页实际手写值重新读取，不能仅根据上一页末尾的数字规律续写。跨页上方值在本页看不清时返回 null，由程序继承，不要猜一个看似连续的镜或次。
10. 不确定或看不清的字段返回 null，并在 warnings 中说明；绝不猜测。
11. 严格按本页从上到下、同一横行内 A机到 D机区块的顺序返回全部 records。`;

export const CORE_AUDIT_SYSTEM_PROMPT = `${SYSTEM_PROMPT}

这是一次独立的核心字段完整性复核。只提取 Schema 中要求的卷号、视频码、场次、镜、次、状态和可信度，不读取拍摄内容、备注、景别或机位。不要参考或假设第一次识别的结果。
先沿 A机、B机、C机、D机各自的“视频码”列从上到下逐格盘点所有手写编号，再回到每条编号所在横行读取最左侧共用的场次、镜、次。完整性优先于文字描述：只要 C0 后存在手写数字，就必须输出一条记录。`;

export const CORE_REVIEW_SYSTEM_PROMPT = `${CORE_AUDIT_SYSTEM_PROMPT}

这是冲突记录和查漏候选的最终定向裁决。用户消息会给出必须复核的素材键。只输出图中能够明确确认存在的列表内素材；不得输出列表之外的素材。对确认存在的键，每个键最多一次。必须根据图中对应横行重新读取，不要按编号规律或用户提供的候选值猜测。若某个候选键在本页图中找不到，不要输出它。`;

export const PDF_SYSTEM_PROMPT = SYSTEM_PROMPT
  .replace(
    "应用正在逐页处理一份多页场记单，当前输入只包含其中一页。",
    "当前输入是一份完整的多页 PDF 场记单。请一次读取全部页面，并保留每条记录的 PDF 页码。",
  )
  .replace(
    "1. 当前请求只包含场记单的一页。扫描整页，为“视频号”列中每一个写有条号的素材子行生成一个 record；",
    "1. 按 PDF 页码从前到后扫描每一页，为“视频号”列中每一个写有条号的素材子行生成一个 record，并把该页页码写入 sourcePage；",
  )
  .replace(
    "11. 严格按本页从上到下、同一横行内 A机到 D机区块的顺序返回全部 records。",
    "11. 严格按 PDF 页码、页内从上到下、同一横行内 A机到 D机区块的顺序返回全部 records；sourcePage 必须是 1–20 的整数。",
  );

export function normalizeSlateResult(value) {
  if (!value || typeof value !== "object" || !Array.isArray(value.records)) {
    throw new Error("模型返回的数据不包含 records 数组");
  }

  return {
    sheetTitle:
      typeof value.sheetTitle === "string" ? value.sheetTitle.trim() : null,
    records: value.records.map((record, index) => ({
      id: `record-${Date.now()}-${index}`,
      sourcePage: normalizeSourcePage(record.sourcePage),
      cardNumber: nullable(record.cardNumber),
      videoCode: nullable(record.videoCode),
      scene: fixedWidthNumber(record.scene, 3),
      shot: fixedWidthNumber(record.shot, 2),
      take: fixedWidthNumber(record.take, 2),
      takeStatus: normalizeTakeStatus(
        record.takeStatus ??
          (typeof record.goodTake === "boolean"
            ? record.goodTake
              ? "过"
              : "保"
            : null),
      ),
      description: nullable(record.description),
      comments: nullable(record.comments),
      shotSize: nullable(record.shotSize),
      cameraPosition: nullable(record.cameraPosition),
      confidence: ["high", "medium", "low"].includes(record.confidence)
        ? record.confidence
        : "low",
    })),
    warnings: Array.isArray(value.warnings)
      ? value.warnings.filter((item) => typeof item === "string")
      : [],
  };
}

export function formatSlateResultFields(result, formats = {}) {
  if (!result || !Array.isArray(result.records)) return result;
  const widths = {
    scene: fieldWidth(formats.scene, 3),
    shot: fieldWidth(formats.shot, 2),
    take: fieldWidth(formats.take, 2),
  };
  return {
    ...result,
    records: result.records.map((record) => ({
      ...record,
      scene: fixedWidthNumber(record.scene, widths.scene),
      shot: fixedWidthNumber(record.shot, widths.shot),
      take: fixedWidthNumber(record.take, widths.take),
    })),
  };
}

function nullable(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function fixedWidthNumber(value, width) {
  const normalized = nullable(value);
  const match = normalized?.match(/\d+/);
  if (!match) return null;
  const number = Number(match[0]);
  if (!Number.isSafeInteger(number) || number < 0 || number >= 10 ** width) {
    return null;
  }
  return String(number).padStart(width, "0");
}

function fieldWidth(value, fallback) {
  const format = String(value || "").trim().toUpperCase();
  return /^X{1,6}$/.test(format) ? format.length : fallback;
}

function normalizeSourcePage(value) {
  const page = Number(value);
  return Number.isInteger(page) && page >= 1 && page <= 20 ? page : null;
}

export function normalizeTakeStatus(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  if (!normalized) return null;

  if (/^(过|过条|好条|ok|pass|☑️?|✅|√|✓|✔)$/i.test(normalized)) {
    return "过";
  }
  if (/^(保|保条|hold|x|×|✕|✖)$/i.test(normalized)) {
    return "保";
  }
  if (/^(废条|废|ng|三角形?|triangle|△|▲)$/i.test(normalized)) {
    return "废条";
  }
  return null;
}
