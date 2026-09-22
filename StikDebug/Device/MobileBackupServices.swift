//
//  MobileBackupServices.swift
//  StikDebug
//

import Foundation
import idevice

struct DeviceBackupProgress {
    let bytesDone: UInt64
    let bytesTotal: UInt64
    let fraction: Double
}
private final class DeviceBackupDelegate {
    let root: URL
    let onProgress: (DeviceBackupProgress) -> Void
    private let lock = NSLock()
    private var writers: [String: FileHandle] = [:]
    private var failure: Error?
    private var cancelled = false

    init(root: URL, onProgress: @escaping (DeviceBackupProgress) -> Void) {
        self.root = root.standardizedFileURL
        self.onProgress = onProgress
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || failure != nil
    }

    func capturedFailure() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func closeOpenFiles() {
        lock.lock()
        let handles = Array(writers.values)
        writers.removeAll()
        lock.unlock()
        for handle in handles { try? handle.close() }
    }

    private func record(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    private func url(for callbackPath: UnsafePointer<CChar>?) throws -> URL {
        guard let callbackPath, let value = String(validatingUTF8: callbackPath), !value.isEmpty else {
            throw IdeviceBridge.makeError(message: "Backup service returned an invalid file path")
        }
        let supplied = URL(fileURLWithPath: value)
        let target: URL
        if supplied.path.hasPrefix(root.path + "/") || supplied.path == root.path {
            target = supplied.standardizedFileURL
        } else {
            target = root.appendingPathComponent(value).standardizedFileURL
        }
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw IdeviceBridge.makeError(message: "Backup service requested a path outside the selected folder")
        }
        return target
    }

    func freeDiskSpace(_ path: UnsafePointer<CChar>?) -> UInt64 {
        do {
            let target = try url(for: path)
            let values = try target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
        } catch {
            record(error)
            return 0
        }
    }

    func openRead(_ path: UnsafePointer<CChar>?, data: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, length: UnsafeMutablePointer<UInt>?) {
        // Backup creation normally writes device files to this host. If the device requests
        // a host-side file, stop safely rather than silently supplying the wrong data.
        record(IdeviceBridge.makeError(message: "This backup requested host-side input, which StikDebug does not provide"))
        data?.pointee = nil
        length?.pointee = 0
    }

    func createWrite(_ path: UnsafePointer<CChar>?) {
        do {
            let target = try url(for: path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            lock.lock()
            writers[target.path] = handle
            lock.unlock()
        } catch {
            record(error)
        }
    }

    func write(_ path: UnsafePointer<CChar>?, bytes: UnsafePointer<UInt8>?, length: UInt) {
        do {
            let target = try url(for: path)
            guard let bytes else { throw IdeviceBridge.makeError(message: "Backup service returned an empty data pointer") }
            lock.lock()
            let handle = writers[target.path]
            lock.unlock()
            guard let handle else { throw IdeviceBridge.makeError(message: "Backup service wrote to a file that was not opened") }
            handle.write(Data(bytes: bytes, count: Int(length)))
        } catch {
            record(error)
        }
    }

    func close(_ path: UnsafePointer<CChar>?) {
        do {
            let target = try url(for: path)
            lock.lock()
            let handle = writers.removeValue(forKey: target.path)
            lock.unlock()
            try handle?.close()
        } catch {
            record(error)
        }
    }

    func createDirectory(_ path: UnsafePointer<CChar>?) {
        do {
            try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
        } catch {
            record(error)
        }
    }

    func remove(_ path: UnsafePointer<CChar>?) {
        do {
            let target = try url(for: path)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        } catch {
            record(error)
        }
    }

    func rename(_ from: UnsafePointer<CChar>?, _ to: UnsafePointer<CChar>?) {
        do {
            let source = try url(for: from)
            let destination = try url(for: to)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            record(error)
        }
    }

    func copy(_ source: UnsafePointer<CChar>?, _ destination: UnsafePointer<CChar>?) {
        do {
            let sourceURL = try url(for: source)
            let destinationURL = try url(for: destination)
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            record(error)
        }
    }

    func exists(_ path: UnsafePointer<CChar>?) -> Bool {
        (try? url(for: path)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func isDirectory(_ path: UnsafePointer<CChar>?) -> Bool {
        guard let target = try? url(for: path) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func reportProgress(bytesDone: UInt64, bytesTotal: UInt64, fraction: Double) {
        DispatchQueue.main.async {
            self.onProgress(DeviceBackupProgress(bytesDone: bytesDone, bytesTotal: bytesTotal, fraction: fraction))
        }
    }
}

private func backupDelegate(from context: UnsafeMutableRawPointer?) -> DeviceBackupDelegate? {
    context.map { Unmanaged<DeviceBackupDelegate>.fromOpaque($0).takeUnretainedValue() }
}

private func backupGetFreeDiskSpace(_ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> UInt64 {
    backupDelegate(from: context)?.freeDiskSpace(path) ?? 0
}

private func backupOpenFileRead(
    _ path: UnsafePointer<CChar>?,
    _ data: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ length: UnsafeMutablePointer<UInt>?,
    _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    backupDelegate(from: context)?.openRead(path, data: data, length: length)
    return nil
}

private func backupCreateFileWrite(_ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    backupDelegate(from: context)?.createWrite(path)
    return nil
}

private func backupWriteChunk(
    _ path: UnsafePointer<CChar>?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: UInt,
    _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    backupDelegate(from: context)?.write(path, bytes: bytes, length: length)
    return nil
}

private func backupCloseFile(_ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    backupDelegate(from: context)?.close(path)
    return nil
}

private func backupCreateDirectory(_ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    backupDelegate(from: context)?.createDirectory(path)
    return nil
}

private func backupRemove(_ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    backupDelegate(from: context)?.remove(path)
    return nil
}

private func backupRename(_ from: UnsafePointer<CChar>?, _ to: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    backupDelegate(from: context)?.rename(from, to)
    return nil
}

private func backupCopy(_ source: UnsafePointer<CChar>?, _ destination: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<IdeviceFfiError>? {
    backupDelegate(from: context)?.copy(source, destination)
    return nil
}

private func backupExists(_ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> Bool {
    backupDelegate(from: context)?.exists(path) ?? false
}

private func backupIsDirectory(_ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> Bool {
    backupDelegate(from: context)?.isDirectory(path) ?? false
}

private func backupIsCancelled(_ context: UnsafeMutableRawPointer?) -> Bool {
    backupDelegate(from: context)?.isCancelled ?? true
}

private func backupProgress(
    _ progress: UnsafePointer<Mobilebackup2BackupProgress>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let progress else { return }
    let value = progress.pointee
    backupDelegate(from: context)?.reportProgress(
        bytesDone: value.session_bytes_done,
        bytesTotal: value.session_bytes_total,
        fraction: value.overall_progress
    )
}

extension JITEnableContext {
    func createLocalBackup(
        in parentDirectory: URL,
        onProgress: @escaping (DeviceBackupProgress) -> Void
    ) throws -> URL {
        let accessing = parentDirectory.startAccessingSecurityScopedResource()
        defer { if accessing { parentDirectory.stopAccessingSecurityScopedResource() } }

        let formatter = ISO8601DateFormatter()
        let backupDirectory = parentDirectory.appendingPathComponent(
            "StikDebug Backup \(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let fileDelegate = DeviceBackupDelegate(root: backupDirectory, onProgress: onProgress)
        let context = Unmanaged.passUnretained(fileDelegate).toOpaque()
        var delegate = Mobilebackup2BackupDelegateFFI()
        delegate.context = context
        delegate.get_free_disk_space = backupGetFreeDiskSpace
        delegate.open_file_read = backupOpenFileRead
        delegate.create_file_write = backupCreateFileWrite
        delegate.write_chunk = backupWriteChunk
        delegate.close_file = backupCloseFile
        delegate.create_dir_all = backupCreateDirectory
        delegate.remove = backupRemove
        delegate.rename = backupRename
        delegate.copy = backupCopy
        delegate.exists = backupExists
        delegate.is_dir = backupIsDirectory
        delegate.is_cancelled = backupIsCancelled
        delegate.on_progress = backupProgress
        defer { fileDelegate.closeOpenFiles() }

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to the backup service",
                missingClientMessage: "Backup service was not created",
                connect: { mobilebackup2_connect_rsd(adapter, handshake, $0) },
                cleanup: { mobilebackup2_client_free($0) }
            ) { client in
                var response: plist_t?
                defer { if let response { plist_free(response) } }
                if let ffiError = mobilebackup2_backup(client, backupDirectory.path, nil, nil, &delegate, &response) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "The device backup did not finish")
                }
            }
        }

        if let failure = fileDelegate.capturedFailure() {
            throw failure
        }
        return backupDirectory
    }
}
