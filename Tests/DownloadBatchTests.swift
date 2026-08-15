import XCTest
@testable import ImmichDesktop

@MainActor
final class DownloadBatchTests: XCTestCase {
    func testSingleAssetSuccessPreservesOriginalFileAndDates() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("DownloadBatchTests-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let createdAt = "2024-05-06T07:08:09.123Z"
        let modifiedAt = "2024-05-07T08:09:10.456Z"
        let asset = ImmichAsset(
            id: "asset-1",
            type: "IMAGE",
            originalFileName: "holiday.jpg",
            fileCreatedAt: createdAt,
            fileModifiedAt: modifiedAt,
            exifInfo: nil
        )
        let expectedBytes = Data("original bytes".utf8)
        let batch = DownloadBatch { _, temporaryURL in
            try expectedBytes.write(to: temporaryURL)
            return temporaryURL
        }

        XCTAssertTrue(batch.start(assets: [asset], destination: destination))
        await waitForBatch(batch)

        let output = destination.appendingPathComponent("holiday.jpg")
        XCTAssertEqual(try Data(contentsOf: output), expectedBytes)
        XCTAssertEqual(batch.phase, .completed)
        XCTAssertEqual(batch.progress.completedCount, 1)
        XCTAssertEqual(batch.progress.totalCount, 1)
        XCTAssertEqual(batch.result?.successfulAssetIDs, [asset.id])
        XCTAssertTrue(batch.result?.failures.isEmpty == true)
        XCTAssertTrue(batch.result?.unfinished.isEmpty == true)

        let values = try output.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        XCTAssertEqual(values.creationDate, try XCTUnwrap(expectedDate(createdAt)))
        XCTAssertEqual(values.contentModificationDate, try XCTUnwrap(expectedDate(modifiedAt)))
        batch.consumeResult()
        XCTAssertEqual(batch.phase, .idle)
        XCTAssertNil(batch.result)
        XCTAssertEqual(try Data(contentsOf: output), expectedBytes)
    }

    func testMixedPhotoAndVideoBatchProducesOneOriginalEach() async throws {
        let paths = try makeDestination()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let assets = [
            makeAsset(id: "photo", type: "IMAGE", fileName: "photo.jpg"),
            makeAsset(id: "video", type: "VIDEO", fileName: "video.mov")
        ]
        let batch = DownloadBatch { assetID, temporaryURL in
            try Data(assetID.utf8).write(to: temporaryURL)
            return temporaryURL
        }

        XCTAssertTrue(batch.start(assets: assets, destination: paths.destination))
        await waitForBatch(batch)

        XCTAssertEqual(batch.result?.successfulAssetIDs, assets.map(\.id))
        XCTAssertEqual(try Data(contentsOf: paths.destination.appendingPathComponent("photo.jpg")),
                       Data("photo".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.destination.appendingPathComponent("video.mov")),
                       Data("video".utf8))
    }

    func testProgressAdvancesDeterministicallyInSnapshotOrder() async throws {
        let paths = try makeDestination()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let assets = [
            makeAsset(id: "first", fileName: "first.jpg"),
            makeAsset(id: "second", type: "VIDEO", fileName: "second.mov"),
            makeAsset(id: "third", fileName: "third.jpg")
        ]
        let permit = TransferPermit()
        let batch = DownloadBatch { assetID, temporaryURL in
            await permit.wait()
            try Data(assetID.utf8).write(to: temporaryURL)
            return temporaryURL
        }

        XCTAssertTrue(batch.start(assets: assets, destination: paths.destination))
        await waitUntil { batch.progress.currentFileName == "first.jpg" }
        XCTAssertEqual(batch.progress,
                       DownloadBatch.Progress(completedCount: 0,
                                              totalCount: 3,
                                              currentFileName: "first.jpg"))

        await permit.release()
        await waitUntil { batch.progress.currentFileName == "second.mov" }
        XCTAssertEqual(batch.progress,
                       DownloadBatch.Progress(completedCount: 1,
                                              totalCount: 3,
                                              currentFileName: "second.mov"))

        await permit.release()
        await waitUntil { batch.progress.currentFileName == "third.jpg" }
        XCTAssertEqual(batch.progress,
                       DownloadBatch.Progress(completedCount: 2,
                                              totalCount: 3,
                                              currentFileName: "third.jpg"))

        await permit.release()
        await waitForBatch(batch)
        XCTAssertEqual(batch.progress,
                       DownloadBatch.Progress(completedCount: 3,
                                              totalCount: 3,
                                              currentFileName: nil))
        XCTAssertEqual(batch.result?.successfulAssetIDs, assets.map(\.id))
    }

    func testStartSnapshotsAssetsAndDestination() async throws {
        let paths = try makeDestination()
        let alternateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadBatchTests-\(UUID().uuidString)", isDirectory: true)
        let alternateDestination = alternateRoot.appendingPathComponent("Destination",
                                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: alternateDestination,
                                                withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: paths.root)
            try? FileManager.default.removeItem(at: alternateRoot)
        }

        var selectedAssets = [
            makeAsset(id: "one", fileName: "one.jpg"),
            makeAsset(id: "two", fileName: "two.jpg")
        ]
        var selectedDestination = paths.destination
        let batch = DownloadBatch { assetID, temporaryURL in
            try Data(assetID.utf8).write(to: temporaryURL)
            return temporaryURL
        }

        XCTAssertTrue(batch.start(assets: selectedAssets, destination: selectedDestination))
        selectedAssets.removeAll()
        selectedDestination = alternateDestination
        await waitForBatch(batch)

        XCTAssertEqual(batch.result?.successfulAssetIDs, ["one", "two"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.destination
            .appendingPathComponent("one.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.destination
            .appendingPathComponent("two.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternateDestination
            .appendingPathComponent("one.jpg").path))
    }

    func testDuplicateOriginalNamesUseCollisionFreeNumericSuffixes() async throws {
        let paths = try makeDestination()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try Data("existing".utf8)
            .write(to: paths.destination.appendingPathComponent("SAME.jpg"))
        let assets = [
            makeAsset(id: "one", fileName: "same.jpg"),
            makeAsset(id: "two", fileName: "same.jpg")
        ]
        let batch = DownloadBatch { assetID, temporaryURL in
            try Data(assetID.utf8).write(to: temporaryURL)
            return temporaryURL
        }

        XCTAssertTrue(batch.start(assets: assets, destination: paths.destination))
        await waitForBatch(batch)

        XCTAssertEqual(try Data(contentsOf: paths.destination.appendingPathComponent("SAME.jpg")),
                       Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.destination.appendingPathComponent("same 2.jpg")),
                       Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.destination.appendingPathComponent("same 3.jpg")),
                       Data("two".utf8))
    }

    func testInvalidTimestampDoesNotFailAndValidTimestampAppliesIndependently() async throws {
        let paths = try makeDestination()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let modifiedAt = "2024-05-07T08:09:10.456Z"
        let asset = makeAsset(id: "dated", fileName: "dated.jpg",
                              createdAt: "not-a-date", modifiedAt: modifiedAt)
        let batch = DownloadBatch { _, temporaryURL in
            try Data("bytes".utf8).write(to: temporaryURL)
            return temporaryURL
        }

        XCTAssertTrue(batch.start(assets: [asset], destination: paths.destination))
        await waitForBatch(batch)

        XCTAssertTrue(batch.result?.isFullSuccess == true)
        let output = paths.destination.appendingPathComponent("dated.jpg")
        let values = try output.resourceValues(forKeys: [.contentModificationDateKey])
        XCTAssertEqual(values.contentModificationDate, try XCTUnwrap(expectedDate(modifiedAt)))
    }

    func testOneTransferFailureDoesNotStopLaterAssets() async throws {
        let paths = try makeDestination()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let assets = [
            makeAsset(id: "first", fileName: "first.jpg"),
            makeAsset(id: "failed", fileName: "failed.jpg"),
            makeAsset(id: "last", fileName: "last.jpg")
        ]
        let calls = TransferCallRecorder()
        let batch = DownloadBatch { assetID, temporaryURL in
            await calls.record(assetID)
            if assetID == "failed" { throw TransferError.denied }
            try Data(assetID.utf8).write(to: temporaryURL)
            return temporaryURL
        }

        XCTAssertTrue(batch.start(assets: assets, destination: paths.destination))
        await waitForBatch(batch)

        XCTAssertEqual(batch.result?.successfulAssetIDs, ["first", "last"])
        XCTAssertEqual(batch.result?.failures.map(\.originalFileName), ["failed.jpg"])
        XCTAssertTrue(batch.result?.failures.first?.message.contains("permission") == true)
        XCTAssertTrue(batch.result?.unfinished.isEmpty == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.destination
            .appendingPathComponent("last.jpg").path))
        let transferCalls = await calls.snapshot()
        XCTAssertEqual(transferCalls, ["first", "failed", "last"])
    }

    func testCancellationKeepsCompletedFilesAndReportsUnfinishedAssets() async throws {
        let paths = try makeDestination()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let assets = [
            makeAsset(id: "first", fileName: "first.jpg"),
            makeAsset(id: "second", fileName: "second.jpg"),
            makeAsset(id: "third", fileName: "third.jpg")
        ]
        let workspaceBox = TemporaryWorkspaceBox()
        let transfer = CancellationAwareTransfer()
        let batch = DownloadBatch { assetID, temporaryURL in
            workspaceBox.value = temporaryURL.deletingLastPathComponent()
            await transfer.recordStart(assetID)
            try Data("partial".utf8).write(to: temporaryURL)
            if assetID == "second" {
                try await withTaskCancellationHandler(operation: {
                    try await transfer.waitForCancellation()
                }, onCancel: {
                    Task { await transfer.recordCancellation() }
                })
            }
            try Data(assetID.utf8).write(to: temporaryURL)
            return temporaryURL
        }

        XCTAssertTrue(batch.start(assets: assets, destination: paths.destination))
        await waitUntil {
            batch.successfulAssetIDs == ["first"] && batch.progress.currentFileName == "second.jpg"
        }
        await waitUntilAsync { await transfer.hasStarted("second") }
        batch.cancel()
        await waitForBatch(batch)

        let didObserveCancellation = await transfer.didObserveCancellation()
        let startedIDs = await transfer.startedIDs()
        XCTAssertTrue(didObserveCancellation)
        XCTAssertEqual(startedIDs, ["first", "second"])
        XCTAssertEqual(batch.result?.successfulAssetIDs, ["first"])
        XCTAssertEqual(batch.result?.unfinished.map(\.assetID), ["second", "third"])
        XCTAssertTrue(batch.result?.cancelled == true)
        XCTAssertEqual(batch.result?.completedCount, 1)
        XCTAssertEqual(batch.result?.unfinishedCount, 2)
        XCTAssertEqual(try Data(contentsOf: paths.destination.appendingPathComponent("first.jpg")),
                       Data("first".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.destination
            .appendingPathComponent("second.jpg").path))
        if let workspace = workspaceBox.value {
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        }
    }

    func testCancellingSettledResultIsHarmless() async throws {
        let paths = try makeDestination()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let asset = makeAsset(id: "complete", fileName: "complete.jpg")
        let batch = DownloadBatch { _, temporaryURL in
            try Data("complete".utf8).write(to: temporaryURL)
            return temporaryURL
        }

        XCTAssertTrue(batch.start(assets: [asset], destination: paths.destination))
        await waitForBatch(batch)
        let settledResult = try XCTUnwrap(batch.result)

        batch.cancel()

        XCTAssertEqual(batch.phase, .completed)
        XCTAssertEqual(batch.result, settledResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.destination
            .appendingPathComponent("complete.jpg").path))
    }

    func testLaterObserverReconnectsWhileRunningAndAfterCompletionWithoutDeletingOutput() async throws {
        let paths = try makeDestination()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let asset = makeAsset(id: "one", fileName: "one.jpg")
        let permit = TransferPermit()
        let batch = DownloadBatch { _, temporaryURL in
            await permit.wait()
            try Data("one".utf8).write(to: temporaryURL)
            return temporaryURL
        }

        var firstGalleryObserver: DownloadBatch? = batch
        XCTAssertTrue(batch.start(assets: [asset], destination: paths.destination))
        XCTAssertEqual(firstGalleryObserver?.phase, .running)
        firstGalleryObserver = nil

        let reopenedGalleryObserver = batch
        XCTAssertEqual(reopenedGalleryObserver.phase, .running)
        XCTAssertEqual(reopenedGalleryObserver.progress.totalCount, 1)
        await permit.release()
        await waitForBatch(reopenedGalleryObserver)

        XCTAssertEqual(reopenedGalleryObserver.phase, .completed)
        XCTAssertEqual(reopenedGalleryObserver.result?.successfulAssetIDs, [asset.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.destination
            .appendingPathComponent("one.jpg").path))

        reopenedGalleryObserver.consumeResult()
        XCTAssertEqual(reopenedGalleryObserver.phase, .idle)
        XCTAssertNil(reopenedGalleryObserver.result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.destination
            .appendingPathComponent("one.jpg").path))
    }

    func testRunningBatchRejectsSecondStartAndRetainedResultNeedsConsumption() async throws {
        let paths = try makeDestination()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let asset = makeAsset(id: "one", fileName: "one.jpg")
        let batch = DownloadBatch { _, temporaryURL in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            try Data("one".utf8).write(to: temporaryURL)
            return temporaryURL
        }

        XCTAssertTrue(batch.start(assets: [asset], destination: paths.destination))
        let observer = batch
        XCTAssertEqual(observer.phase, .running)
        XCTAssertEqual(observer.progress.totalCount, 1)
        XCTAssertFalse(batch.start(assets: [asset], destination: paths.destination))
        batch.cancel()
        await waitForBatch(batch)
        XCTAssertEqual(batch.phase, .completed)
        XCTAssertNotNil(batch.result)
        XCTAssertIdentical(observer, batch)
        XCTAssertFalse(batch.start(assets: [asset], destination: paths.destination))
        batch.consumeResult()
        XCTAssertEqual(batch.phase, .idle)
        XCTAssertNil(batch.result)
    }

    private func waitForBatch(_ batch: DownloadBatch) async {
        for _ in 0..<10_000 where batch.phase == .running {
            await Task.yield()
        }
        XCTAssertNotEqual(batch.phase, .running, "Download batch did not finish")
    }

    private func makeDestination() throws -> (root: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadBatchTests-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (root, destination)
    }

    private func makeAsset(id: String,
                           type: String = "IMAGE",
                           fileName: String,
                           createdAt: String? = nil,
                           modifiedAt: String? = nil) -> ImmichAsset {
        ImmichAsset(id: id,
                    type: type,
                    originalFileName: fileName,
                    fileCreatedAt: createdAt,
                    fileModifiedAt: modifiedAt,
                    exifInfo: nil)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        await waitUntilAsync { condition() }
    }

    private func waitUntilAsync(_ condition: () async -> Bool) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }

    private actor CancellationAwareTransfer {
        private var startedAssetIDs: [String] = []
        private var cancellationObserved = false
        private var continuation: CheckedContinuation<Void, any Error>?

        func recordStart(_ assetID: String) {
            startedAssetIDs.append(assetID)
        }

        func hasStarted(_ assetID: String) -> Bool {
            startedAssetIDs.contains(assetID)
        }

        func startedIDs() -> [String] {
            startedAssetIDs
        }

        func waitForCancellation() async throws {
            if cancellationObserved {
                throw CancellationError()
            }
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancellationObserved {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        }

        func recordCancellation() {
            cancellationObserved = true
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }

        func didObserveCancellation() -> Bool {
            cancellationObserved
        }
    }

    private actor TransferCallRecorder {
        private var calls: [String] = []

        func record(_ assetID: String) {
            calls.append(assetID)
        }

        func snapshot() -> [String] {
            calls
        }
    }

    private actor TransferPermit {
        private var permits = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if permits > 0 {
                permits -= 1
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            if waiters.isEmpty {
                permits += 1
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private enum TransferError: LocalizedError {
        case denied

        var errorDescription: String? {
            "The server denied permission to download the original."
        }
    }

    private final class TemporaryWorkspaceBox: @unchecked Sendable {
        var value: URL?
    }

    private func expectedDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}
