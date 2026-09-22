import Darwin
import Combine
import Foundation
import UIKit
import idevice

struct RemotePairingRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var serviceIdentifier: String?
    let pairingFileName: String
    let hostAlternateIRK: Data
    let createdAt: Date
    var lastConnectedAt: Date?
}

struct RemotePairingMatch: Equatable {
    let record: RemotePairingRecord
    let pairingFileURL: URL
}

enum RemotePairingStore {
    private static let lock = NSLock()
    private static let metadataFileName = "records.json"

    static func pairingFileURLs(preferredFor device: NearbyDevelopmentDevice? = nil) throws -> [URL] {
        if let pairingFileURL = device?.pairingFileURL {
            return [pairingFileURL]
        }
        lock.lock()
        defer { lock.unlock() }

        let directory = try storageDirectory()
        let records = try loadRecords(in: directory)
        let ordered = records.sorted { lhs, rhs in
            if let device {
                let lhsMatches = lhs.serviceIdentifier == device.id || lhs.displayName == device.name
                let rhsMatches = rhs.serviceIdentifier == device.id || rhs.displayName == device.name
                if lhsMatches != rhsMatches { return lhsMatches }
            }
            return (lhs.lastConnectedAt ?? lhs.createdAt) > (rhs.lastConnectedAt ?? rhs.createdAt)
        }
        return ordered.compactMap { record in
            let url = directory.appendingPathComponent(record.pairingFileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    static func matchingRecord(
        serviceIdentifier: String,
        authenticationTags: [String]
    ) throws -> RemotePairingMatch? {
        guard !authenticationTags.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let directory = try storageDirectory()
        for record in try loadRecords(in: directory) {
            let url = directory.appendingPathComponent(record.pairingFileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var pairingFile: OpaquePointer?
            guard url.path.withCString({ rp_pairing_file_read($0, &pairingFile) }) == nil,
                  let pairingFile else { continue }
            defer { rp_pairing_file_free(pairingFile) }

            for tag in authenticationTags {
                var matches = false
                let error = serviceIdentifier.withCString { identifier in
                    tag.withCString { tag in
                        remote_control_pairing_matches_service(
                            pairingFile,
                            identifier,
                            tag,
                            &matches
                        )
                    }
                }
                if let error { idevice_error_free(error) }
                if matches {
                    return RemotePairingMatch(record: record, pairingFileURL: url)
                }
            }
        }
        return nil
    }

    static func save(
        pairingFile: OpaquePointer,
        displayName: String,
        hostAlternateIRK: Data
    ) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        let directory = try storageDirectory()
        let identifier = UUID()
        let fileName = identifier.uuidString + ".plist"
        let url = directory.appendingPathComponent(fileName)
        if let error = url.path.withCString({ rp_pairing_file_write(pairingFile, $0) }) {
            throw IdeviceBridge.consumeFFIError(error, fallback: "Unable to save the remote pairing record")
        }

        var records = try loadRecords(in: directory)
        records.append(
            RemotePairingRecord(
                id: identifier,
                displayName: displayName,
                serviceIdentifier: nil,
                pairingFileName: fileName,
                hostAlternateIRK: hostAlternateIRK,
                createdAt: Date(),
                lastConnectedAt: nil
            )
        )
        try saveRecords(records, in: directory)
        return url
    }

    static func markConnected(
        pairingFileURL: URL,
        to device: NearbyDevelopmentDevice
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let directory = try storageDirectory()
        var records = try loadRecords(in: directory)
        guard let index = records.firstIndex(where: { $0.pairingFileName == pairingFileURL.lastPathComponent }) else {
            return
        }
        records[index].displayName = device.name
        records[index].serviceIdentifier = device.serviceIdentifier
        records[index].lastConnectedAt = Date()
        try saveRecords(records, in: directory)
    }

    static func records() throws -> [RemotePairingRecord] {
        lock.lock()
        defer { lock.unlock() }
        let directory = try storageDirectory()
        return try loadRecords(in: directory)
    }

    private static func storageDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("RemotePairing", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        return directory
    }

    private static func loadRecords(in directory: URL) throws -> [RemotePairingRecord] {
        let url = directory.appendingPathComponent(metadataFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RemotePairingRecord].self, from: Data(contentsOf: url))
    }

    private static func saveRecords(_ records: [RemotePairingRecord], in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoderCompatibleRecords = try encoder.encode(records)
        try decoderCompatibleRecords.write(
            to: directory.appendingPathComponent(metadataFileName),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}

private func remotePairingPINCallback(
    _ pin: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let pin, let context else { return }
    let coordinator = Unmanaged<RemotePairingCoordinator>.fromOpaque(context).takeUnretainedValue()
    coordinator.receivedPIN(String(cString: pin))
}

private struct SendableCallbackContext: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

final class RemotePairingCoordinator: NSObject, ObservableObject, NetServiceDelegate, @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case preparing
        case advertising
        case waitingForCode(String)
        case saving
        case completed(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let workQueue = DispatchQueue(label: "com.stikdebug.remote-pairing", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listenerFD: Int32 = -1
    private var acceptedFD: Int32 = -1
    private var service: NetService?
    private var cancelled = false

    var isActive: Bool {
        switch phase {
        case .preparing, .advertising, .waitingForCode, .saving:
            return true
        default:
            return false
        }
    }

    func start() {
        guard !isActive else { return }
        phase = .preparing
        stateLock.lock()
        cancelled = false
        stateLock.unlock()

        let retainedContext = SendableCallbackContext(
            pointer: Unmanaged.passRetained(self).toOpaque()
        )
        let controllerName = "StikDebug on \(UIDevice.current.name)"
        workQueue.async { [weak self] in
            defer { Unmanaged<RemotePairingCoordinator>.fromOpaque(retainedContext.pointer).release() }
            self?.runPairing(controllerName: controllerName, context: retainedContext.pointer)
        }
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        let listener = listenerFD
        let accepted = acceptedFD
        listenerFD = -1
        acceptedFD = -1
        stateLock.unlock()

        if accepted >= 0 {
            _ = Darwin.shutdown(accepted, SHUT_RDWR)
            Darwin.close(accepted)
        }
        if listener >= 0 {
            _ = Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        service?.stop()
        service = nil
        if isActive { phase = .idle }
    }

    func receivedPIN(_ pin: String) {
        Task { @MainActor [weak self] in
            self?.phase = .waitingForCode(pin)
        }
    }

    private func runPairing(controllerName: String, context: UnsafeMutableRawPointer) {
        var handle: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txtBytes: UnsafeMutablePointer<UInt8>?
        var txtLength = 0
        var hostIRK = [UInt8](repeating: 0, count: 16)
        let prepareError = controllerName.withCString { name in
            "Mac17,7".withCString { model in
                pairable_host_prepare(
                    name,
                    model,
                    false,
                    &handle,
                    &serviceID,
                    &txtBytes,
                    &txtLength,
                    &hostIRK
                )
            }
        }
        if let prepareError {
            finish(error: IdeviceBridge.consumeFFIError(prepareError, fallback: "Unable to create a remote pairing identity"))
            return
        }
        guard let handle, let serviceID, let txtBytes, txtLength > 0 else {
            finish(error: IdeviceBridge.makeError(message: "The remote pairing identity was incomplete"))
            return
        }
        defer {
            pairable_host_free(handle)
            idevice_string_free(serviceID)
            idevice_data_free(txtBytes, UInt(txtLength))
        }

        do {
            let txtRecord = try Self.txtRecord(from: Data(bytes: txtBytes, count: txtLength))
            let socket = try Self.makeListeningSocket()
            self.setListenerFD(socket.fd)
            try publishService(name: String(cString: serviceID), port: socket.port, txtRecord: txtRecord)

            let accepted = Darwin.accept(socket.fd, nil, nil)
            guard accepted >= 0 else {
                if isCancelled { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNABORTED)
            }
            self.setAcceptedFD(accepted)
            Task { @MainActor [weak self] in self?.phase = .saving }

            var pairingFile: OpaquePointer?
            var peerDevice: UnsafeMutablePointer<RpPairingPeerDeviceC>?
            let acceptError = pairable_host_accept_fd(
                handle,
                accepted,
                remotePairingPINCallback,
                context,
                &peerDevice,
                &pairingFile
            )
            guard acceptError == nil else {
                throw IdeviceBridge.consumeFFIError(acceptError!, fallback: "The other device rejected remote pairing")
            }
            guard let pairingFile else {
                throw IdeviceBridge.makeError(message: "Pairing completed without a reusable pairing record")
            }
            defer { rp_pairing_file_free(pairingFile) }
            defer { rppairing_peer_device_free(peerDevice) }

            let deviceName = peerDevice?.pointee.name.map { String(cString: $0) } ?? "Paired Device"

            _ = try RemotePairingStore.save(
                pairingFile: pairingFile,
                displayName: deviceName,
                hostAlternateIRK: Data(hostIRK)
            )
            finish(success: "\(deviceName) is paired. It will appear when it advertises remote development services.")
        } catch {
            if !isCancelled { finish(error: error) }
        }
        cleanupSockets()
    }

    private func publishService(name: String, port: UInt16, txtRecord: Data) throws {
        try DispatchQueue.main.sync {
            guard !isCancelled else { throw CancellationError() }
            let service = NetService(
                domain: "local.",
                type: "_remotepairing-pairable-host._tcp.",
                name: name,
                port: Int32(port)
            )
            service.delegate = self
            service.setTXTRecord(txtRecord)
            self.service = service
            service.publish()
            self.phase = .advertising
        }
    }

    private func finish(success message: String) {
        Task { @MainActor [weak self] in
            self?.service?.stop()
            self?.service = nil
            self?.phase = .completed(message)
        }
    }

    private func finish(error: Error) {
        Task { @MainActor [weak self] in
            self?.service?.stop()
            self?.service = nil
            self?.phase = .failed(error.localizedDescription)
        }
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func setListenerFD(_ value: Int32) {
        stateLock.lock()
        listenerFD = value
        stateLock.unlock()
    }

    private func setAcceptedFD(_ value: Int32) {
        stateLock.lock()
        acceptedFD = value
        stateLock.unlock()
    }

    private func cleanupSockets() {
        stateLock.lock()
        let listener = listenerFD
        let accepted = acceptedFD
        listenerFD = -1
        acceptedFD = -1
        stateLock.unlock()
        if accepted >= 0 { Darwin.close(accepted) }
        if listener >= 0 { Darwin.close(listener) }
    }

    private static func txtRecord(from plistData: Data) throws -> Data {
        let object = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        guard let strings = object as? [String: String] else {
            throw IdeviceBridge.makeError(message: "The pairing advertisement metadata was invalid")
        }
        return NetService.data(fromTXTRecord: strings.mapValues { Data($0.utf8) })
    }

    private static func makeListeningSocket() throws -> (fd: Int32, port: UInt16) {
        let fd = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var dualStack: Int32 = 0
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &dualStack, socklen_t(MemoryLayout.size(ofValue: dualStack)))

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        address.sin6_addr = in6addr_any

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EADDRNOTAVAIL)
        }

        var bound = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        return (fd, UInt16(bigEndian: bound.sin6_port))
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        cancel()
        phase = .failed("StikDebug could not advertise for pairing (Bonjour error \(code)). Check Local Network access.")
    }
}
