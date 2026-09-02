#!/usr/bin/env swift
// SlateSync macOS Vision OCR bridge.
//
// Reads one JSON request from stdin and writes one sentinel-prefixed JSON
// response to stdout, mirroring scripts/paddleocr_runner.py so the Node side
// can reuse the same parse strategy. Text recognition runs entirely on-device
// through the Apple Vision framework (VNRecognizeTextRequest).
//
// Release builds use the checked wrapper:
//   node scripts/build-vision-ocr.mjs --arch universal
// A direct swiftc command can still produce a local thin binary; the Node
// wrapper is responsible for architecture selection and the --check gate.

import Foundation
import Vision
import ImageIO

// MARK: - Protocol constants

let SENTINEL = "__SLATESYNC_OCR_JSON__"
let PROGRESS_SENTINEL = "__SLATESYNC_OCR_PROGRESS__"

// MARK: - Input / output structures

struct ViewRequest: Decodable {
    let pageNumber: Int
    let images: [String]
}

struct OcrRequest: Decodable {
    let language: String?
    let recognitionLevel: String?
    let usesLanguageCorrection: Bool?
    let minimumConfidence: Double?
    let maxBlocksPerView: Int?
    let pages: [ViewRequest]
}

struct Block: Encodable {
    var order: Int
    let text: String
    let confidence: Double
    let bbox: [Int]
    let bboxNormalized: [Double]
}

struct ViewResult: Encodable {
    let viewIndex: Int
    let viewType: String
    let width: Int
    let height: Int
    var durationMs: Int
    let truncated: Bool
    let blocks: [Block]
}

struct PageResult: Encodable {
    let pageNumber: Int
    let views: [ViewResult]
}

struct OcrSuccess: Encodable {
    let ok: Bool
    let engine: String
    let modelVersion: String
    let language: String
    let recognitionLevel: String
    let durationMs: Int
    let pages: [PageResult]
}

struct OcrError: Encodable {
    let code: String
    let message: String
}

struct OcrFailure: Encodable {
    let ok: Bool
    let error: OcrError
}

struct CheckResult: Encodable {
    let ok: Bool
    let engine: String
    let modelVersion: String
    let systemVersion: String
}

struct ProgressPayload: Encodable {
    let stage: String
    let pageNumber: Int?
    let viewIndex: Int?
    let completedViews: Int
    let totalViews: Int
    let durationMs: Int?
    let blockCount: Int?
}

// MARK: - Small helpers

struct OcrBridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
    return min(max(value, minimum), maximum)
}

func rounded(_ value: Double, _ places: Int) -> Double {
    let factor = pow(10.0, Double(places))
    return (value * factor).rounded() / factor
}

func emit<T: Encodable>(_ value: T, exitCode: Int32 = 0) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let line = SENTINEL + String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8)!
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
    exit(exitCode)
}

func emitProgress(_ payload: ProgressPayload) {
    let encoder = JSONEncoder()
    let line = PROGRESS_SENTINEL + String(data: (try? encoder.encode(payload)) ?? Data(), encoding: .utf8)!
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
}

func decodeDataURL(_ value: String) -> Data? {
    guard let comma = value.firstIndex(of: ",") else { return nil }
    let header = String(value[..<comma])
    guard header.hasPrefix("data:image/"), header.contains(";base64") else { return nil }
    let encoded = String(value[value.index(after: comma)...])
    return Data(base64Encoded: encoded)
}

// MARK: - Recognition

func recognizeView(
    dataURL: String,
    viewIndex: Int,
    languages: [String],
    level: VNRequestTextRecognitionLevel,
    usesLanguageCorrection: Bool,
    minimumConfidence: Double,
    maxBlocksPerView: Int
) throws -> ViewResult {
    guard let data = decodeDataURL(dataURL) else {
        throw OcrBridgeError("图片不是有效 Data URL")
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw OcrBridgeError("无法解码图片")
    }
    let width = cgImage.width
    let height = cgImage.height

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    request.usesLanguageCorrection = usesLanguageCorrection
    if languages.isEmpty {
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }
    } else {
        request.recognitionLanguages = languages
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])

    var blocks: [Block] = []
    for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = Double(candidate.confidence)
        guard !text.isEmpty, confidence >= minimumConfidence else { continue }
        // Vision reports a normalized [x, y, w, h] box with the origin in the
        // bottom-left corner; convert it to the top-left-origin
        // [left, top, right, bottom] format used by PaddleOCR evidence.
        let box = observation.boundingBox
        let left = clamp(box.minX, 0, 1)
        let right = clamp(box.maxX, 0, 1)
        let top = clamp(1 - box.maxY, 0, 1)
        let bottom = clamp(1 - box.minY, 0, 1)
        blocks.append(Block(
            order: 0,
            text: text,
            confidence: rounded(confidence, 5),
            bbox: [
                Int((left * Double(width)).rounded()),
                Int((top * Double(height)).rounded()),
                Int((right * Double(width)).rounded()),
                Int((bottom * Double(height)).rounded()),
            ],
            bboxNormalized: [
                rounded(left, 5),
                rounded(top, 5),
                rounded(right, 5),
                rounded(bottom, 5),
            ]
        ))
    }

    // Reading order: rows from top to bottom, then left to right within a row.
    blocks.sort { a, b in
        let aMidY = a.bboxNormalized[1] + (a.bboxNormalized[3] - a.bboxNormalized[1]) / 2
        let bMidY = b.bboxNormalized[1] + (b.bboxNormalized[3] - b.bboxNormalized[1]) / 2
        if abs(aMidY - bMidY) > 0.02 { return aMidY < bMidY }
        return a.bboxNormalized[0] < b.bboxNormalized[0]
    }

    var truncated = false
    if maxBlocksPerView > 0 && blocks.count > maxBlocksPerView {
        truncated = true
        blocks = selectBlocksWithPageCoverage(blocks, limit: maxBlocksPerView)
    }
    for index in blocks.indices { blocks[index].order = index }

    return ViewResult(
        viewIndex: viewIndex,
        viewType: viewIndex == 0 ? "full" : "core-detail",
        width: width,
        height: height,
        durationMs: 0,
        truncated: truncated,
        blocks: blocks
    )
}

func selectBlocksWithPageCoverage(_ blocks: [Block], limit: Int) -> [Block] {
    // Bound output without always deleting the bottom of a dense page.
    if limit <= 0 || blocks.count <= limit { return blocks }
    if limit == 1 { return [blocks[blocks.count / 2]] }
    let lastIndex = blocks.count - 1
    var selected: [Block] = []
    for slot in 0..<limit {
        let index = Int((Double(slot) * Double(lastIndex) / Double(limit - 1)).rounded())
        selected.append(blocks[index])
    }
    return selected
}

// MARK: - Entry point

func emitCheck() -> Never {
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let version = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    emit(CheckResult(
        ok: true,
        engine: "Vision",
        modelVersion: "macOS-Vision",
        systemVersion: version
    ))
}

func main() {
    if CommandLine.arguments.contains("--check") {
        emitCheck()
    }

    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard !input.isEmpty else {
        emit(OcrFailure(ok: false, error: OcrError(code: "invalid_input", message: "OCR 输入为空")), exitCode: 2)
    }
    let request: OcrRequest
    do {
        request = try JSONDecoder().decode(OcrRequest.self, from: input)
    } catch {
        emit(OcrFailure(ok: false, error: OcrError(code: "invalid_input", message: "OCR 输入不是有效 JSON：\(error.localizedDescription)")), exitCode: 2)
    }

    let languages = (request.language ?? "zh-Hans")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let recognitionLevel = (request.recognitionLevel ?? "accurate") == "fast" ? "fast" : "accurate"
    let level: VNRequestTextRecognitionLevel = recognitionLevel == "fast" ? .fast : .accurate
    let usesLanguageCorrection = request.usesLanguageCorrection ?? true
    let minimumConfidence = clamp(request.minimumConfidence ?? 0.1, 0, 1)
    let maxBlocksPerView = max(0, request.maxBlocksPerView ?? 0)

    let started = Date()
    let totalViews = request.pages.reduce(0) { $0 + $1.images.count }
    var completedViews = 0
    emitProgress(ProgressPayload(
        stage: "ready",
        pageNumber: nil,
        viewIndex: nil,
        completedViews: 0,
        totalViews: totalViews,
        durationMs: nil,
        blockCount: nil
    ))

    var pages: [PageResult] = []
    for page in request.pages {
        var views: [ViewResult] = []
        for (viewIndex, dataURL) in page.images.enumerated() {
            let viewStarted = Date()
            do {
                var view = try recognizeView(
                    dataURL: dataURL,
                    viewIndex: viewIndex,
                    languages: languages,
                    level: level,
                    usesLanguageCorrection: usesLanguageCorrection,
                    minimumConfidence: minimumConfidence,
                    maxBlocksPerView: maxBlocksPerView
                )
                view.durationMs = Int(Date().timeIntervalSince(viewStarted) * 1000)
                completedViews += 1
                emitProgress(ProgressPayload(
                    stage: "view-complete",
                    pageNumber: page.pageNumber,
                    viewIndex: viewIndex,
                    completedViews: completedViews,
                    totalViews: totalViews,
                    durationMs: view.durationMs,
                    blockCount: view.blocks.count
                ))
                views.append(view)
            } catch {
                emit(OcrFailure(
                    ok: false,
                    error: OcrError(
                        code: "inference_failed",
                        message: "第 \(page.pageNumber) 页第 \(viewIndex + 1) 个视图识别失败：\(error.localizedDescription)"
                    )
                ), exitCode: 5)
            }
        }
        pages.append(PageResult(pageNumber: page.pageNumber, views: views))
    }

    emit(OcrSuccess(
        ok: true,
        engine: "Vision",
        modelVersion: "macOS-Vision",
        language: languages.joined(separator: ","),
        recognitionLevel: recognitionLevel,
        durationMs: Int(Date().timeIntervalSince(started) * 1000),
        pages: pages
    ))
}

main()
