import XCTest
@testable import ImmichDesktop

@MainActor
final class DeletionBatchTests: XCTestCase {
    func testStopFinishesCurrentDeletionWithoutSendingRemainingAssets() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var attempted: [String] = []
        var batch: DeletionBatch!
        batch = fixture.batch { _, id in
            attempted.append(id)
            batch.stop()
        }

        XCTAssertTrue(batch.start(assets: [asset("first"), asset("second")]))
        await batch.waitForCompletion()

        XCTAssertEqual(attempted, ["first"])
        XCTAssertEqual(batch.result?.successfulAssetIDs, ["first"])
        XCTAssertEqual(batch.result?.unfinished.map(\.assetID), ["second"])
        XCTAssertEqual(batch.result?.retryableAssetIDs, ["second"])
        XCTAssertEqual(try fixture.journal.confirmedDeletions(connectionID: fixture.client.connectionID)
            .map(\.assetID), ["first"])
        XCTAssertFalse(batch.start(assets: [asset("second")]))
        batch.consumeResult()
        XCTAssertEqual(batch.phase, .idle)
    }

    func testAssetRejectionContinuesButKeyFailureStopsUnsentWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var attempted: [String] = []
        let batch = fixture.batch { _, id in
            attempted.append(id)
            if id == "not-owned" { throw ImmichClient.DeletionError.rejected(statusCode: 400) }
            if id == "revoked" { throw ImmichClient.DeletionError.authentication(statusCode: 403) }
        }

        XCTAssertTrue(batch.start(assets: ["not-owned", "owned", "revoked", "unsent"].map(asset)))
        await batch.waitForCompletion()

        XCTAssertEqual(attempted, ["not-owned", "owned", "revoked"])
        XCTAssertEqual(batch.result?.successfulAssetIDs, ["owned"])
        XCTAssertEqual(batch.result?.failures.map(\.assetID), ["not-owned", "revoked"])
        XCTAssertEqual(batch.result?.unfinished.map(\.assetID), ["unsent"])
    }

    func testLostResponseNeverRetriesAndDoesNotSelectUncertainAssetForRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var attempted: [String] = []
        let batch = fixture.batch { _, id in
            attempted.append(id)
            throw URLError(.networkConnectionLost)
        }

        XCTAssertTrue(batch.start(assets: [asset("uncertain"), asset("unsent")]))
        await batch.waitForCompletion()

        XCTAssertEqual(attempted, ["uncertain"])
        XCTAssertEqual(batch.result?.uncertain.map(\.assetID), ["uncertain"])
        XCTAssertEqual(batch.result?.retryableAssetIDs, ["unsent"])
        XCTAssertEqual(try fixture.journal.confirmedDeletions(connectionID: fixture.client.connectionID), [])
        let recovered = fixture.batch { _, id in attempted.append(id) }
        await recovered.waitForCompletion()
        XCTAssertEqual(attempted, ["uncertain"])
        XCTAssertEqual(recovered.result?.uncertain.map(\.assetID), ["uncertain"])
    }

    func testCrashIntentIsReconciledWithoutReplayingDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var inFlight = DeletionJournal.Asset(id: UUID(), assetID: "already-trashed",
                                             originalFileName: "photo.jpg")
        inFlight.state = .inFlight
        let unsent = DeletionJournal.Asset(id: UUID(), assetID: "unsent", originalFileName: "video.mov")
        try fixture.journal.save(DeletionJournal.Batch(id: UUID(), connectionID: fixture.client.connectionID,
            createdAt: Date(), assets: [inFlight, unsent]))
        var writes = 0
        let recovered = fixture.batch(readState: { _, _ in .deleted }) { _, _ in writes += 1 }
        await recovered.waitForCompletion()

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(recovered.result?.successfulAssetIDs, ["already-trashed"])
        XCTAssertEqual(recovered.result?.unfinished.map(\.assetID), ["unsent"])
        XCTAssertEqual(try fixture.journal.confirmedDeletions(connectionID: fixture.client.connectionID)
            .map(\.assetID), ["already-trashed"])
        recovered.consumeResult()
        let reopened = fixture.batch { _, _ in writes += 1 }
        XCTAssertEqual(reopened.phase, .idle)
        XCTAssertEqual(writes, 0)
    }

    func testUnavailableJournalPreventsAnyMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let blocked = fixture.root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocked)
        var writes = 0
        let batch = DeletionBatch(journal: DeletionJournal(storageDirectory: blocked),
            clientProvider: { fixture.client }, readOptIn: { true }, writeOptIn: { _ in },
            deleteOperation: { _, _ in writes += 1 })

        _ = batch.start(assets: [asset("must-not-delete")])
        await batch.waitForCompletion()

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(batch.phase, .completed)
        XCTAssertNotNil(batch.result?.message)
    }

    func testOutcomeStorageFailureDoesNotTurnMutationIntoRetryableFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var writes = 0
        let batch = fixture.batch { _, _ in
            writes += 1
            // The request completed, but the confirmation destination became unwritable.
            let blocked = fixture.journal.storageDirectory!
                .appendingPathComponent(fixture.client.connectionID)
                .appendingPathComponent("confirmed")
            try Data("not a directory".utf8).write(to: blocked)
        }

        XCTAssertTrue(batch.start(assets: [asset("changed"), asset("unsent")]))
        await batch.waitForCompletion()

        XCTAssertEqual(writes, 1)
        XCTAssertEqual(batch.result?.uncertain.map(\.assetID), ["changed"])
        XCTAssertEqual(batch.result?.retryableAssetIDs, ["unsent"])
        let recovered = fixture.batch { _, _ in writes += 1 }
        await recovered.waitForCompletion()
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(recovered.start(assets: [asset("changed")]))
    }

    func testKnownMissingPermissionBlocksButUnavailableDiscoveryAllowsOptIn() async throws {
        let missing = try Fixture(permissionResponse: 200, permissions: ["asset.read"])
        defer { missing.remove() }
        let blocked = missing.batch { _, _ in XCTFail("Missing scope must block mutation") }
        await blocked.refreshCapabilities()
        XCTAssertFalse(blocked.canDelete)
        XCTAssertFalse(blocked.start(assets: [asset("blocked")]))

        let older = try Fixture(permissionResponse: 404)
        defer { older.remove() }
        var writes = 0
        let allowed = older.batch { _, _ in writes += 1 }
        await allowed.refreshCapabilities()
        XCTAssertTrue(allowed.canDelete)
        XCTAssertTrue(allowed.start(assets: [asset("explicit-opt-in")]))
        await allowed.waitForCompletion()
        XCTAssertEqual(writes, 1)
    }

    private func asset(_ id: String) -> ImmichAsset {
        ImmichAsset(id: id, type: "IMAGE", originalFileName: "\(id).jpg",
                    fileCreatedAt: nil, fileModifiedAt: nil, exifInfo: nil)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let journal: DeletionJournal
        let client: ImmichClient
        private let host: String
        private let session: URLSession

        init(permissionResponse: Int = 200, permissions: [String] = ["asset.delete"]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("DeletionTests-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            journal = DeletionJournal(storageDirectory: root.appendingPathComponent("journal"))
            host = "test-\(UUID().uuidString.lowercased()).invalid"
            DeletionHTTPProtocol.register(host: host, code: permissionResponse, permissions: permissions)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DeletionHTTPProtocol.self]
            session = URLSession(configuration: config)
            client = ImmichClient(serverURL: "https://\(host)", apiKey: "test-only", session: session)!
        }

        func batch(readState: @escaping DeletionBatch.ReadState = { _, _ in .unknown("Check Immich") },
                   delete: @escaping DeletionBatch.DeleteOperation) -> DeletionBatch {
            DeletionBatch(journal: journal, clientProvider: { self.client },
                readOptIn: { true }, writeOptIn: { _ in }, deleteOperation: delete, readState: readState)
        }

        func remove() {
            session.invalidateAndCancel()
            DeletionHTTPProtocol.unregister(host: host)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class DeletionHTTPProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [String: (Int, [String])] = [:]

    static func register(host: String, code: Int, permissions: [String]) {
        lock.lock()
        defer { lock.unlock() }
        responses[host] = (code, permissions)
    }

    static func unregister(host: String) {
        lock.lock()
        defer { lock.unlock() }
        responses.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let response = Self.responses[request.url!.host!]
        Self.lock.unlock()
        guard let (permissionCode, permissions) = response else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let code: Int
        let body: [String: Any]
        switch request.url!.path {
        case "/api/api-keys/me":
            code = permissionCode
            body = ["permissions": permissions]
        case "/api/server/features":
            code = 200
            body = ["trash": true]
        case "/api/server/config":
            code = 200
            body = ["trashDays": 30]
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
