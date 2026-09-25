import Foundation
import XCTest
@testable import SlateSyncPersistence

/// Shared project-key ownership contracts survive Provider migration removal.
final class KeychainBackendTests: XCTestCase {
    func testConditionalDeletePreservesAValueChangedByAnotherWriter() async throws {
        let backend = InMemoryKeychainBackend(values: ["openai": "new-secret"])

        let outcome = try await backend.deleteIfMatching(
            Data("old-secret".utf8),
            service: InMemoryKeychainBackend.service,
            account: "openai"
        )

        XCTAssertEqual(outcome, .valueChanged)
        let retainedValue = await backend.value(account: "openai")
        XCTAssertEqual(retainedValue, "new-secret")
    }

    func testCreateIfAbsentReturnsOwnershipAndRejectsWrongOwnerCompensation() async throws {
        let backend = InMemoryKeychainBackend()
        let first = try await backend.createIfAbsent(
            Data("first-secret".utf8),
            service: InMemoryKeychainBackend.service,
            account: "openai"
        )
        guard case .created(let ownership) = first else {
            XCTFail("Expected the first create to own the item")
            return
        }
        let duplicate = try await backend.createIfAbsent(
            Data("second-secret".utf8),
            service: InMemoryKeychainBackend.service,
            account: "openai"
        )
        XCTAssertEqual(duplicate, .alreadyExists)

        let wrongOwner = try await backend.deleteIfMatching(
            Data("first-secret".utf8),
            service: InMemoryKeychainBackend.service,
            account: "openai",
            ownership: Data("another-migration".utf8)
        )
        XCTAssertEqual(wrongOwner, .valueChanged)
        let retained = await backend.value(account: "openai")
        XCTAssertEqual(retained, "first-secret")

        let correctOwner = try await backend.deleteIfMatching(
            Data("first-secret".utf8),
            service: InMemoryKeychainBackend.service,
            account: "openai",
            ownership: ownership
        )
        XCTAssertEqual(correctOwner, .removed)

        let recreated = try await backend.createIfAbsent(
            Data("first-secret".utf8),
            service: InMemoryKeychainBackend.service,
            account: "openai"
        )
        guard case .created(let recreatedOwnership) = recreated else {
            XCTFail("Expected a fresh create after compensation")
            return
        }

        // Even an identical credential written later revokes the old marker;
        // compensation must not delete another native writer's same-value
        // update merely because the bytes happen to match.
        try await backend.write(
            Data("first-secret".utf8),
            service: InMemoryKeychainBackend.service,
            account: "openai"
        )
        let sameValueLaterWriter = try await backend.deleteIfMatching(
            Data("first-secret".utf8),
            service: InMemoryKeychainBackend.service,
            account: "openai",
            ownership: recreatedOwnership
        )
        XCTAssertEqual(sameValueLaterWriter, .valueChanged)
    }

}
