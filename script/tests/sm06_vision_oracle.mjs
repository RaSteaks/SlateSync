// Extract the frozen helper's real normalization and sorting code into a small
// offline executable. It never imports SlateSyncMedia or its implementation.
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
if (!process.argv.includes("--write")) throw new Error("Explicit --write required");
const root = "Tests/SlateSyncMediaTests/Fixtures/SM06";
const original = readFileSync("scripts/vision_ocr.swift","utf8");
const structs = original.slice(original.indexOf("struct Block:"), original.indexOf("struct PageResult:"));
const helpers = original.slice(original.indexOf("func clamp("), original.indexOf("func emit<"));
const normalization = original.slice(original.indexOf("    var blocks: [Block] = []"), original.indexOf("// MARK: - Entry point")).replace("request.results ?? []", "observations");
const source = `import Foundation
import CoreGraphics
${structs}
${helpers}
struct Box: Codable { let x: Double; let y: Double; let width: Double; let height: Double }
struct Candidate { let string: String; let confidence: Float }
struct Raw: Codable {
 let text: String; let confidence: Double; let box: Box
 var boundingBox: CGRect { CGRect(x: box.x, y: box.y, width: box.width, height: box.height) }
 func topCandidates(_ n: Int) -> [Candidate] { [Candidate(string: text, confidence: Float(confidence))] }
}
func normalize(_ observations: [Raw], maxBlocksPerView: Int, minimumConfidence: Double = 0.1, width: Int = 800, height: Int = 1000, viewIndex: Int = 0) -> ViewResult {
${normalization}
struct Output: Encodable { let observations: [Raw]; let cap: Int; let expected: ViewResult }
let observations: [Raw] = [
 .init(text: " title ", confidence: 0.9, box: .init(x: 0.1,y: 0.9,width: 0.4,height: 0.05)),
 .init(text: "right", confidence: 0.8, box: .init(x: 0.7,y: 0.85,width: 0.2,height: 0.04)),
 .init(text: "left", confidence: 0.8, box: .init(x: 0.05,y: 0.84,width: 0.2,height: 0.04)),
 .init(text: "tie", confidence: 0.8, box: .init(x: 0.05,y: 0.84,width: 0.2,height: 0.04)),
 .init(text: "bottom 😀", confidence: 0.75, box: .init(x: -0.02,y: -0.01,width: 1.04,height: 0.1)),
 .init(text: "   ", confidence: 1, box: .init(x: 0,y: 0,width: 1,height: 1)),
 .init(text: "low", confidence: 0.09, box: .init(x: 0,y: 0,width: 1,height: 1))
]
let output = [0,1,2,4].map { Output(observations: observations, cap: $0, expected: normalize(observations, maxBlocksPerView: $0)) }
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(output))
`;
const temp = mkdtempSync(join(tmpdir(),"sm06-oracle-"));
try {
 writeFileSync(join(temp,"oracle.swift"),source);
 execFileSync("xcrun",["swiftc",join(temp,"oracle.swift"),"-o",join(temp,"oracle")],{stdio:"pipe"});
 const data=execFileSync(join(temp,"oracle"),[]);
 writeFileSync(`${root}/vision-oracle.json`,data);
 const manifest=JSON.parse(readFileSync(`${root}/manifest.json`));
 manifest.files["vision-oracle.json"]={bytes:data.length,sha256:createHash("sha256").update(data).digest("hex")};
 writeFileSync(`${root}/manifest.json`,JSON.stringify(manifest,null,2)+"\n");
} finally { rmSync(temp,{recursive:true,force:true}); }
