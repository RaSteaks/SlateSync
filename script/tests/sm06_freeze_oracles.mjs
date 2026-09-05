// Explicit, offline baseline creation. Never called by the Gate or native tests:
// changing a golden requires reviewing its legacy source and provenance first.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { findDenseRowBand, calculateDetailSegments, calculateCoreColumnWidth } from "../../public/image-preprocess.js";
import { resolvePaddleOcrParameters, formatOcrEvidence } from "../../lib/ocr/paddleocr.mjs";
import { resolveOcrSelection } from "../../lib/ocr/selection.mjs";

if (!process.argv.includes("--write")) throw new Error("Use --write only when freezing a reviewed baseline");
const root = "Tests/SlateSyncMediaTests/Fixtures/SM06";
mkdirSync(root, { recursive: true });
const write = (name, value) => writeFileSync(`${root}/${name}`, JSON.stringify(value, null, 2) + "\n");
const bands = [
  { name: "blank", width: 80, height: 100, rows: [] },
  { name: "noise", width: 80, height: 100, rows: [15,16,70,71] },
  { name: "separate-title-table", width: 80, height: 200, rows: [20,21,22,...Array.from({length:60},(_,i)=>100+i)] },
  ...[4,5,8,9,10].map(n=>({name:`margin-${n}`, width: 80, height:100, rows:Array.from({length:100-2*n},(_,i)=>i+n)})),
  { name: "tiny", width: 3, height: 4, rows: [0,1,2,3] },
];
write("geometry.json", {
  bands: bands.map(input=>{ const data = new Uint8ClampedArray(input.width*input.height*4).fill(255); for(const y of input.rows) for(let x=0;x<input.width;x++) for(let c=0;c<3;c++) data[(y*input.width+x)*4+c]=0; return { ...input, expected:findDenseRowBand({data,width:input.width,height:input.height}) }; }),
  segments: [1,2,3,4,9,10,99,100,101,999,2600,3000].map(height=>({height, expected:calculateDetailSegments(height)})),
  widths: [1,2,3,99,100,101,2600].map(width=>({width,expected:calculateCoreColumnWidth(width)})),
});
const vectors = [{}, {PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN:""}, {PADDLEOCR_MODEL_VERSION:"pp-ocrv5"}];
for(const preset of ["performance","balanced","fast","custom","unknown"]) for(const version of ["PP-OCRv5","PP-OCRv6"]) for(const profile of ["fast","balanced","accurate","unknown"]) vectors.push({PADDLEOCR_PRESET:preset,PADDLEOCR_MODEL_VERSION:version,PADDLEOCR_PROFILE:profile,PADDLEOCR_DETECTION_MODEL:"PP-OCRv5_mobile_det",PADDLEOCR_RECOGNITION_MODEL:"local-rec",PADDLEOCR_RECOGNITION_BATCH_SIZE:"0x10",PADDLEOCR_MIN_CONFIDENCE:"0.4",PADDLEOCR_MAX_BLOCKS_PER_VIEW:"99"});
write("paddle-config.json",vectors.map(raw=>({raw,expected:resolvePaddleOcrParameters(raw)})));
const selections=[];
for(const visionMode of ["true","false","auto","unknown"]) for(const paddleMode of ["true","false","auto"]) for(const vr of [false,true]) for(const pr of [false,true]) for(const va of [false,true]) for(const pa of [false,true]) {
 const raw={VISIONOCR_ENABLED:visionMode,PADDLEOCR_ENABLED:paddleMode};
 const enabled=(mode,available)=>mode==="true"||(mode==="auto"&&available);
 const vision={id:"vision",enabled:enabled(visionMode,va),required:vr,available:va};
 const paddle={id:"paddleocr",enabled:enabled(paddleMode,pa),required:pr,available:pa};
 const result=resolveOcrSelection(raw,{vision,paddle}); selections.push({raw,vision,paddle,expected:{id:result.id,mode:result.mode}});
}
write("selection.json",selections);
const page={pageNumber:2,views:[{viewIndex:0,viewType:"full",width:800,height:1200,truncated:true,blocks:["场 镜 次","C001","较长的中文备注需要完整保留","emoji😀🎬","take _OK ng ×"].map((text,order)=>({order,text,confidence:0.9-order*.1,bbox:[0,0,10,10],bboxNormalized:[0.1,0.2+order*.1,0.8,0.3+order*.1]}))},{viewIndex:1,viewType:"core-detail",width:900,height:1500,truncated:false,blocks:[{order:0,text:"long supplementary comment",confidence:.65,bbox:[0,0,10,10],bboxNormalized:[0,0,1,1]}]}]};
write("evidence.json",["full","core"].flatMap(mode=>[300,500,700,18000].map(maxCharacters=>({page,mode,maxCharacters,expected:formatOcrEvidence(page,{engine:"vision",mode,maxCharacters})}))));
const paths=["public/image-preprocess.js","public/recognition-request.js","src/renderer/workers/preparation.worker.ts","src/renderer/features/workspace/WorkspacePage.tsx","src/renderer/validation/input-validation.ts","lib/config.mjs","scripts/vision_ocr.swift","lib/ocr/vision.mjs","lib/ocr/paddleocr.mjs","scripts/paddleocr_runner.py","lib/ocr/selection.mjs","lib/ocr/cancellation.mjs","lib/ocr/runtime-paths.mjs","lib/ocr/child-environment.mjs","test/fixtures/fake-paddleocr-runner.py"];
const sha256=data=>createHash("sha256").update(data).digest("hex");
write("manifest.json",{schemaVersion:1,sourceCommit:execFileSync("git",["rev-parse","HEAD"],{encoding:"utf8"}).trim(),sources:paths.map(path=>({path,bytes:readFileSync(path).length,sha256:sha256(readFileSync(path))})),files:Object.fromEntries(["geometry.json","paddle-config.json","selection.json","evidence.json"].map(name=>[name,{bytes:readFileSync(`${root}/${name}`).length,sha256:sha256(readFileSync(`${root}/${name}`))}])),rasterAcceptance:{frozenBeforeNativeImplementation:true,geometry:"Exact dimensions, crop/media intersection, quarter-turn rotation, page and view order. JPEG bytes are not cross-framework goldens.",markers:"Synthetic solid color patches sampled at central 50% of each patch; dominant channel >= 180 and other channels <= 80; white alpha background channels >= 240. Samples avoid antialiased edges.",pixelBudget:"No additional product rejection limit. Decoders subsample to <= 3000 per axis; check all finite bounds and integer products before allocation. Analysis <= 512 wide. One source page at a time.",orientation:"EXIF orientation 6 is clockwise; PDF /Rotate 90 is clockwise. Red top-left/blue bottom-right source markers must follow the independent rotated geometry."}});
