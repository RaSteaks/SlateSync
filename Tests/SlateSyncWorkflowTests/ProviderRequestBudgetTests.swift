import CoreGraphics
import Foundation
import ImageIO
import SlateSyncDomain
import SlateSyncMedia
import UniformTypeIdentifiers
import XCTest
@testable import SlateSyncWorkflow

private actor BudgetTransport: ProviderHTTPTransporting {
    var bodies: [Data] = []
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        bodies.append(request.body ?? Data())
        return .init(status: 200, body: Data(#"{"output_text":"{}"}"#.utf8))
    }
    func close() {}
}

final class ProviderRequestBudgetTests: XCTestCase {
    func testActualPayloadIsCompressedWithinBudgetWithoutChangingSourceImage() async throws {
        var seed: UInt32 = 0x12345678
        // A real page-sized image exercises the supported downsampling ladder;
        // tiny noise cannot meet an arbitrarily small budget by JPEG quality alone.
        let side = 2048
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for pixel in 0..<(side * side) {
            for channel in 0..<3 {
                seed = seed &* 1664525 &+ 1013904223
                pixels[pixel * 4 + channel] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prepared = try await MediaPreparationService().prepare(.bytes(data as Data, filename: "noise.png"), options: .init(includesDetails: false))
        let original = prepared.pages[0].views[0].image
        let request = request(image: original, prompt: "Read", budget: 4 * 1024 * 1024)
        XCTAssertGreaterThan(try ProviderPayloadBuilder.payload(request, mode: .jsonSchema, enforceBudget: false).count, request.maximumRequestBytes)
        let transport = BudgetTransport(), client = ProviderRecognitionClient(transport: transport)
        _ = try await client.recognize(request)
        let bodies = await transport.bodies
        XCTAssertEqual(bodies.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(bodies.first).count, Int(Double(request.maximumRequestBytes) * 0.94))
        XCTAssertFalse(String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self).contains(original.dataURL))
        XCTAssertEqual(request.images[0].data, original.jpeg)
        await client.close()
    }

    func testOversizedTextContextIsRejectedBeforeTransportOrImageDecode() async throws {
        let image = try PreparedImage(jpeg: Data([255,216,255,255,217]), width: 1, height: 1)
        let transport = BudgetTransport(), client = ProviderRecognitionClient(transport: transport)
        do {
            _ = try await client.recognize(request(image: image, prompt: String(repeating: "context", count: 1000), budget: 1000))
            XCTFail("No image compression can make this text-only context fit")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MEDIA_REQUEST_SIZE") }
        let bodies = await transport.bodies
        XCTAssertTrue(bodies.isEmpty)
        await client.close()
    }

    private func request(image: PreparedImage, prompt: String, budget: Int) -> RecognitionStageRequest {
        .init(provider: .init(id: "openai", label: "fixture", origin: .builtin, providerKind: .openAI,
                             baseURL: URL(string: "https://example.com/v1")!, transport: .responses),
              model: .init(publicID: "m", apiID: "m", providerID: "openai", label: "m"), stage: .primary,
              filename: "fixture", images: [image], systemPrompt: prompt, schema: .object(["type": .string("object")]),
              maximumRequestBytes: budget)
    }
}
