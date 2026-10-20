import Foundation
import CryptoKit
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

struct AssetUploadResult {
    let asset: ImmichAsset
    let alreadyExisted: Bool
}

enum AssetUploadError: Error, LocalizedError {
    case rejected(Int, String), trashedDuplicate, unsupportedFile, sourceUnavailable
    var errorDescription: String? {
        switch self {
        case .rejected(let code, let message): return "Upload failed (HTTP \(code)). \(message)"
        case .trashedDuplicate: return "This file already exists in Immich Trash. Review it in Immich; it was not restored."
        case .unsupportedFile: return "Only standalone image and video files are supported. Folders, aliases, symbolic links and sidecars cannot be uploaded."
        case .sourceUnavailable: return "The original file is unavailable or changed during upload. Drop it again to retry."
        }
    }
}

extension ImmichClient {
    static func isTransientUploadError(_ error: Error) -> Bool {
        if case AssetUploadError.rejected(let code, _) = error {
            return code == 408 || code == 429 || (500...599).contains(code)
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains(error.code)
    }

    /// SHA-1 allows uncertain uploads to be retried without a second Asset.
    /// Multipart encoding is temporary transport storage, never recovery state.
    func uploadFile(at url: URL, filename: String? = nil,
                    progress: Progress? = nil) async throws -> AssetUploadResult {
        let name = filename ?? url.lastPathComponent
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                .isAliasFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])
        } catch { throw AssetUploadError.sourceUnavailable }
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isAliasFile != true else {
            throw AssetUploadError.unsupportedFile
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let extraImages: Set<String> = ["3fr", "ari", "arw", "bay", "cap", "cr2", "cr3", "crw", "dcr", "dcs", "dng", "drf", "eip", "erf", "fff", "iiq", "jxl", "k25", "kdc", "mdc", "mef", "mos", "mrw", "nef", "nrw", "obm", "orf", "pef", "ptx", "pxn", "r3d", "raf", "raw", "rw2", "rwl", "rwz", "sr2", "srf", "srw", "x3f", "mpo"]
        let extraVideos: Set<String> = ["3gp", "avi", "flv", "insv", "m2ts", "mts", "mxf", "ts", "vob", "webm", "wmv", "mkv"]
        let type = UTType(filenameExtension: ext)
        guard type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true
                || extraImages.contains(ext) || extraVideos.contains(ext) else { throw AssetUploadError.unsupportedFile }
        guard let size = values.fileSize, size > 0 else { throw AssetUploadError.sourceUnavailable }
        let hashing = Task.detached(priority: .utility) {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = Insecure.SHA1()
            while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let checksum = try await withTaskCancellationHandler {
            try await hashing.value
        } onCancel: { hashing.cancel() }
        try Task.checkCancellation()

        func request(_ path: String) -> URLRequest {
            var req = URLRequest(url: baseURL.appendingPathComponent(path))
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            return req
        }
        func checked(_ req: URLRequest) async throws -> Data {
            let (data, response) = try await session.data(for: req)
            guard let code = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
            guard (200...299).contains(code) else {
                throw AssetUploadError.rejected(code, code == 401 || code == 403
                    ? "Check the API key and its asset.upload and asset.read permissions." : "The server rejected the request.")
            }
            return data
        }
        struct Check: Decodable {
            struct Result: Decodable { let id: String; let assetId: String?; let isTrashed: Bool? }
            let results: [Result]
        }
        var check = request("assets/bulk-upload-check")
        check.httpMethod = "POST"
        check.setValue("application/json", forHTTPHeaderField: "Content-Type")
        check.httpBody = try JSONSerialization.data(withJSONObject: ["assets": [["id": checksum, "checksum": checksum]]])
        let preflight = try JSONDecoder().decode(Check.self, from: await checked(check))
        if preflight.results.contains(where: { $0.id == checksum && $0.isTrashed == true }) {
            throw AssetUploadError.trashedDuplicate
        }
        // Preflight across external libraries is not authoritative for normal upload
        // deduplication. Only the upload endpoint decides which Asset is returned.
        struct Version: Decodable { let major: Int }
        let version = try JSONDecoder().decode(Version.self, from: await checked(request("server/version")))
        let boundary = "ImmichDesktop-" + UUID().uuidString
        let formatter = ISO8601DateFormatter()
        let capturedAt = await originalCaptureDate(at: url, isVideo: type?.conforms(to: .movie) == true || extraVideos.contains(ext))
        var fields = ["fileCreatedAt": formatter.string(from: capturedAt ?? values.creationDate ?? values.contentModificationDate ?? Date()),
                      "fileModifiedAt": formatter.string(from: values.contentModificationDate ?? values.creationDate ?? Date()),
                      "visibility": "timeline"]
        if version.major < 3 {
            fields["deviceId"] = "ImmichDesktop"
            fields["deviceAssetId"] = checksum
        }
        var header = ""
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            header += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n"
        }
        let safeName = name.replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "_")
        header += "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(safeName)\"\r\nContent-Type: \(type?.preferredMIMEType ?? "application/octet-stream")\r\n\r\n"
        let prefix = Data(header.utf8)
        let suffix = Data("\r\n--\(boundary)--\r\n".utf8)
        var req = request("assets")
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(String(prefix.count + size + suffix.count), forHTTPHeaderField: "Content-Length")
        req.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        let encoding = Task.detached(priority: .utility) { try multipartBody(url: url, prefix: prefix, suffix: suffix) }
        let body = try await withTaskCancellationHandler {
            try await encoding.value
        } onCancel: { encoding.cancel() }
        defer { try? FileManager.default.removeItem(at: body) }
        try Task.checkCancellation()
        let transfer = UploadStreamTransfer(url: body, progress: progress)
        let (data, code) = try await transfer.send(req)
        guard code == 200 || code == 201 else {
            throw AssetUploadError.rejected(code, code == 401 || code == 403
                ? "Check the API key's asset.upload permission." : "Check server format, quota and upload-size limits.")
        }
        struct Response: Decodable { let id: String; let status: String }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.status == "created" || response.status == "duplicate" else { throw URLError(.badServerResponse) }
        let currentValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard currentValues.fileSize == size, currentValues.contentModificationDate == values.contentModificationDate else {
            throw AssetUploadError.sourceUnavailable
        }
        struct State: Decodable { let isTrashed: Bool?; let status: String? }
        let assetData = try await checked(request("assets/\(response.id)"))
        let state = try JSONDecoder().decode(State.self, from: assetData)
        if state.isTrashed == true || state.status == "trashed" || state.status == "deleted" {
            throw AssetUploadError.trashedDuplicate
        }
        guard state.isTrashed == false || state.status == "active" else { throw URLError(.badServerResponse) }
        let asset = try JSONDecoder().decode(ImmichAsset.self, from: assetData)
        // Metadata extraction is asynchronous. Finder must never receive a zero size.
        let resultAsset = ImmichAsset(id: asset.id, type: asset.type, originalFileName: asset.originalFileName,
            fileCreatedAt: asset.fileCreatedAt, fileModifiedAt: asset.fileModifiedAt,
            exifInfo: ImmichExif(fileSizeInByte: asset.exifInfo?.fileSizeInByte ?? size,
                city: asset.exifInfo?.city, state: asset.exifInfo?.state, country: asset.exifInfo?.country))
        progress?.completedUnitCount = progress?.totalUnitCount ?? 1
        return AssetUploadResult(asset: resultAsset, alreadyExisted: response.status == "duplicate")
    }
}

private func originalCaptureDate(at url: URL, isVideo: Bool) async -> Date? {
    if isVideo {
        if let item = try? await AVURLAsset(url: url).load(.creationDate) {
            return try? await item.load(.dateValue)
        }
        return nil
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
    let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
    guard let raw = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime as String] as? String else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String {
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        return formatter.date(from: raw + offset)
    }
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return formatter.date(from: raw)
}

/// Foundation's native file stream implements the CFNetwork stream contract.
/// The temporary multipart body is removed on success, failure and cancellation.
private func multipartBody(url: URL, prefix: Data, suffix: Data) throws -> URL {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ImmichDesktop-upload-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    do {
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try output.write(contentsOf: prefix)
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
        }
        try output.write(contentsOf: suffix)
        return destination
    } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
    }
}

private final class UploadStreamTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let progress: Progress?
    private let lock = NSLock()
    private var task: URLSessionUploadTask?
    private var cancelled = false
    private var data = Data()
    private var continuation: CheckedContinuation<(Data, Int), Error>?
    init(url: URL, progress: Progress?) {
        self.url = url; self.progress = progress
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 120
                config.timeoutIntervalForResource = 24 * 3600
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                let task = session.uploadTask(with: request, fromFile: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock()
            task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?.totalUnitCount = max(1, totalBytesExpectedToSend)
        progress?.completedUnitCount = totalBytesSent
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self.data.count < 1024 * 1024 { self.data.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; self.task = nil; lock.unlock()
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: (data, (task.response as? HTTPURLResponse)?.statusCode ?? 0)) }
        session.finishTasksAndInvalidate()
    }
}
