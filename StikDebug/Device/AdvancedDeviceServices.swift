//
//  AdvancedDeviceServices.swift
//  StikDebug
//

import Foundation
import UIKit
import idevice
import Darwin

struct RemoteFileEntry: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64?

    var id: String { path }
}

struct CrashReportEntry: Identifiable, Hashable {
    let path: String
    let name: String

    var id: String { path }
}

struct SpringBoardSnapshot {
    let orientation: UInt8
    let homeScreenWallpaper: UIImage?
    let lockScreenWallpaper: UIImage?
}

struct DeviceDiagnosticEntry: Identifiable, Hashable {
    let key: String
    let value: String

    var id: String { key }
}

struct ManagedApp: Identifiable, Hashable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

enum DevicePowerAction: String, CaseIterable, Identifiable {
    case restart
    case shutdown
    case sleep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restart: "Restart Device"
        case .shutdown: "Shut Down Device"
        case .sleep: "Put Device to Sleep"
        }
    }

    var message: String {
        switch self {
        case .restart: "The device will restart immediately and StikDebug will disconnect."
        case .shutdown: "The device will shut down immediately and StikDebug will disconnect."
        case .sleep: "The device display will be put to sleep."
        }
    }
}

final class DeviceNotificationStream {
    static let shared = DeviceNotificationStream()

    private let queue = DispatchQueue(label: "com.stikdebug.notification-proxy", qos: .userInitiated)
    private let lock = NSLock()
    private var client: OpaquePointer?
    private var isStreaming = false

    private init() { }

    func start(
        observing name: String,
        onNotification: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        lock.lock()
        guard !isStreaming else { lock.unlock(); return }
        isStreaming = true
        lock.unlock()

        queue.async {
            do {
                let handles = try IdeviceBridge.activeTunnelHandles(for: JITEnableContext.shared)
                let client = try IdeviceBridge.connectClient(
                    fallback: "Failed to connect to Notification Proxy",
                    missingClientMessage: "Notification Proxy client was not created",
                    connect: { notification_proxy_connect_rsd(handles.adapter, handles.handshake, $0) }
                )
                self.lock.lock()
                self.client = client
                self.lock.unlock()

                if let ffiError = notification_proxy_observe(client, name) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to observe \(name)")
                }

                while self.streaming {
                    var received: UnsafeMutablePointer<CChar>?
                    if let ffiError = notification_proxy_receive(client, &received) {
                        if self.streaming {
                            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Notification stream stopped")
                        }
                        idevice_error_free(ffiError)
                        break
                    }
                    if let received {
                        let notification = String(validatingUTF8: received) ?? "<invalid notification>"
                        notification_proxy_free_string(received)
                        DispatchQueue.main.async { onNotification(notification) }
                    }
                }
            } catch {
                if self.streaming {
                    DispatchQueue.main.async { onFailure(error) }
                }
            }
            self.finish()
        }
    }

    func stop() {
        lock.lock()
        isStreaming = false
        let client = client
        self.client = nil
        lock.unlock()
        if let client { notification_proxy_client_free(client) }
    }

    private var streaming: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStreaming
    }

    private func finish() {
        lock.lock()
        let client = client
        self.client = nil
        isStreaming = false
        lock.unlock()
        if let client { notification_proxy_client_free(client) }
    }
}

extension IdeviceBridge {
    static func crashReportDirectoryEntries(_ client: OpaquePointer, path: String?) throws -> [String] {
        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count = 0
        let ffiError = if let path {
            crash_report_client_ls(client, path, &entries, &count)
        } else {
            crash_report_client_ls(client, nil, &entries, &count)
        }
        if let ffiError {
            throw consumeFFIError(ffiError, fallback: "Failed to list crash reports")
        }
        defer { if let entries { freeDirectoryEntries(entries, count: count) } }
        guard let entries else { return [] }
        return (0..<count).compactMap { index in
            entries[index].flatMap { String(validatingUTF8: $0) }
        }
    }

    static func looksLikeCrashReportFile(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return [".ips", ".crash", ".panic", ".log", ".txt", ".synced", ".plist"]
            .contains { lowercased.contains($0) }
    }

    static func diagnosticDictionary(from plist: plist_t?) throws -> [String: Any] {
        guard let plist else { return [:] }
        var binary: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        guard plist_to_bin(plist, &binary, &length) == PLIST_ERR_SUCCESS,
              let binary,
              length > 0 else {
            throw makeError(message: "Failed to decode diagnostics response")
        }
        defer { plist_mem_free(binary) }
        let data = Data(bytes: binary, count: Int(length))
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw makeError(message: "Diagnostics response was not a dictionary")
        }
        return dictionary
    }

    static func withAfcClient<T>(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        try withConnectedClient(
            fallback: "Failed to connect to AFC",
            missingClientMessage: "AFC client was not created",
            connect: { afc_client_connect_rsd(adapter, handshake, $0) },
            cleanup: { afc_client_free($0) },
            body
        )
    }

    static func directoryEntries(_ client: OpaquePointer, path: String) throws -> [String] {
        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count = 0
        if let ffiError = afc_list_directory(client, path, &entries, &count) {
            throw consumeFFIError(ffiError, fallback: "Failed to list \(path)")
        }
        defer {
            if let entries {
                freeDirectoryEntries(entries, count: count)
            }
        }
        guard let entries else { return [] }
        return (0..<count).compactMap { index in
            entries[index].flatMap { String(validatingUTF8: $0) }
        }
    }

    static func freeDirectoryEntries(_ entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
        for index in 0..<count {
            if let entry = entries[index] {
                idevice_string_free(entry)
            }
        }
        idevice_data_free(
            UnsafeMutableRawPointer(entries).assumingMemoryBound(to: UInt8.self),
            UInt(count * MemoryLayout<UnsafeMutablePointer<CChar>?>.stride)
        )
    }

    static func fileData(_ client: OpaquePointer, path: String) throws -> Data {
        var file: OpaquePointer?
        if let ffiError = afc_file_open(client, path, AfcRdOnly, &file) {
            throw consumeFFIError(ffiError, fallback: "Failed to open \(path)")
        }
        guard let file else { throw makeError(message: "AFC did not return a file handle") }
        defer { _ = afc_file_close(file) }

        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        if let ffiError = afc_file_read_entire(file, &bytes, &length) {
            throw consumeFFIError(ffiError, fallback: "Failed to read \(path)")
        }
        defer {
            if let bytes {
                afc_file_read_data_free(bytes, length)
            }
        }
        return bytes.map { Data(bytes: $0, count: length) } ?? Data()
    }

    static func writeFile(_ client: OpaquePointer, path: String, data: Data) throws {
        var file: OpaquePointer?
        if let ffiError = afc_file_open(client, path, AfcWr, &file) {
            throw consumeFFIError(ffiError, fallback: "Failed to create \(path)")
        }
        guard let file else { throw makeError(message: "AFC did not return a file handle") }
        defer { _ = afc_file_close(file) }
        let ffiError = data.withUnsafeBytes { buffer in
            afc_file_write(file, buffer.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        if let ffiError {
            throw consumeFFIError(ffiError, fallback: "Failed to write \(path)")
        }
    }
}

extension JITEnableContext {
    func remoteFiles(at path: String) throws -> [RemoteFileEntry] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withAfcClient(adapter: adapter, handshake: handshake) { client in
                try IdeviceBridge.directoryEntries(client, path: path)
                    .filter { $0 != "." && $0 != ".." }
                    .map { name in
                        let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
                        var info = AfcFileInfo()
                        let fileInfoError = afc_get_file_info(client, childPath, &info)
                        let isInfoAvailable = fileInfoError == nil
                        if let fileInfoError {
                            idevice_error_free(fileInfoError)
                        }
                        defer {
                            if isInfoAvailable { afc_file_info_free(&info) }
                        }
                        let format = IdeviceBridge.string(from: info.st_ifmt) ?? ""
                        return RemoteFileEntry(
                            path: childPath,
                            name: name,
                            isDirectory: format == "S_IFDIR",
                            size: isInfoAvailable ? Int64(info.size) : nil
                        )
                    }
                    .sorted { lhs, rhs in
                        lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
            }
        }
    }

    func downloadRemoteFile(at path: String) throws -> URL {
        let data = try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withAfcClient(adapter: adapter, handshake: handshake) {
                try IdeviceBridge.fileData($0, path: path)
            }
        }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    func uploadRemoteFile(from localURL: URL, to path: String) throws {
        let accessing = localURL.startAccessingSecurityScopedResource()
        defer { if accessing { localURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: localURL)
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withAfcClient(adapter: adapter, handshake: handshake) {
                try IdeviceBridge.writeFile($0, path: path, data: data)
            }
        }
    }

    func deleteRemotePath(_ path: String) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withAfcClient(adapter: adapter, handshake: handshake) { client in
                if let ffiError = afc_remove_path(client, path) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to remove \(path)")
                }
            }
        }
    }

    func crashReports() throws -> [CrashReportEntry] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to crash-report service",
                missingClientMessage: "Crash-report client was not created",
                connect: { crash_report_client_connect_rsd(adapter, handshake, $0) },
                cleanup: { crash_report_client_free($0) }
            ) { client in
                var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                var count = 0
                if let ffiError = crash_report_client_ls(client, nil, &entries, &count) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to list crash reports")
                }
                defer { if let entries { IdeviceBridge.freeDirectoryEntries(entries, count: count) } }
                guard let entries else { return [] }
                return (0..<count).compactMap { index -> CrashReportEntry? in
                    guard let value = entries[index].flatMap({ String(validatingUTF8: $0) }), value != ".", value != ".." else { return nil }
                    return CrashReportEntry(path: value, name: value)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            }
        }
    }

    /// Returns the device's own Analytics reports, including reports that iOS
    /// has moved into nested folders such as `Retired`. Proxied-device folders
    /// are deliberately skipped so an attached Watch or another paired device
    /// cannot contaminate this device's battery history.
    func batteryAnalyticsReports() throws -> [CrashReportEntry] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to crash-report service",
                missingClientMessage: "Crash-report client was not created",
                connect: { crash_report_client_connect_rsd(adapter, handshake, $0) },
                cleanup: { crash_report_client_free($0) }
            ) { client in
                var pending: [(path: String?, depth: Int)] = [(nil, 0)]
                var reports: [CrashReportEntry] = []

                while !pending.isEmpty {
                    let directory = pending.removeFirst()
                    let names: [String]
                    do {
                        names = try IdeviceBridge.crashReportDirectoryEntries(client, path: directory.path)
                    } catch {
                        if directory.path == nil { throw error }
                        continue
                    }

                    for name in names where name != "." && name != ".." {
                        let path = directory.path.map { "\($0)/\(name)" } ?? name
                        let lowercasedName = name.lowercased()
                        if lowercasedName.contains("analytics-") || lowercasedName.contains("log-aggregated-") {
                            reports.append(CrashReportEntry(path: path, name: name))
                            continue
                        }

                        guard directory.depth < 3,
                              !lowercasedName.hasPrefix("proxieddevice-"),
                              !IdeviceBridge.looksLikeCrashReportFile(name) else { continue }
                        pending.append((path, directory.depth + 1))
                    }
                }

                return reports.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            }
        }
    }

    func downloadCrashReport(at path: String) throws -> URL {
        let data = try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to crash-report service",
                missingClientMessage: "Crash-report client was not created",
                connect: { crash_report_client_connect_rsd(adapter, handshake, $0) },
                cleanup: { crash_report_client_free($0) }
            ) { client in
                var bytes: UnsafeMutablePointer<UInt8>?
                var length = 0
                if let ffiError = crash_report_client_pull(client, path, &bytes, &length) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to download \(path)")
                }
                defer { if let bytes { idevice_data_free(bytes, UInt(length)) } }
                return bytes.map { Data(bytes: $0, count: length) } ?? Data()
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try data.write(to: url, options: .atomic)
        return url
    }

    func deleteCrashReport(at path: String) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to crash-report service",
                missingClientMessage: "Crash-report client was not created",
                connect: { crash_report_client_connect_rsd(adapter, handshake, $0) },
                cleanup: { crash_report_client_free($0) }
            ) { client in
                if let ffiError = crash_report_client_remove(client, path) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to remove \(path)")
                }
            }
        }
    }

    func takeDeviceScreenshot() throws -> UIImage {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to screenshot service",
                missingClientMessage: "Screenshot client was not created",
                connect: { screenshotr_connect_rsd(adapter, handshake, $0) },
                cleanup: { screenshotr_client_free($0) }
            ) { client in
                var screenshot = ScreenshotData()
                if let ffiError = screenshotr_take_screenshot(client, &screenshot) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to capture screenshot")
                }
                defer { screenshotr_screenshot_free(screenshot) }
                guard let data = screenshot.data, screenshot.length > 0, let image = UIImage(data: Data(bytes: data, count: Int(screenshot.length))) else {
                    throw IdeviceBridge.makeError(message: "Screenshot data was empty or invalid")
                }
                return image
            }
        }
    }

    func springBoardSnapshot() throws -> SpringBoardSnapshot {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to SpringBoard Services",
                missingClientMessage: "SpringBoard client was not created",
                connect: { springboard_services_connect_rsd(adapter, handshake, $0) },
                cleanup: { springboard_services_free($0) }
            ) { client in
                var orientation: UInt8 = 0
                if let ffiError = springboard_services_get_interface_orientation(client, &orientation) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to fetch interface orientation")
                }
                func image(_ loader: (UnsafeMutablePointer<UnsafeMutableRawPointer?>, UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<IdeviceFfiError>?) -> UIImage? {
                    var bytes: UnsafeMutableRawPointer?
                    var length = 0
                    guard loader(&bytes, &length) == nil, let bytes, length > 0 else { return nil }
                    defer { free(bytes) }
                    return UIImage(data: Data(bytes: bytes, count: length))
                }
                return SpringBoardSnapshot(
                    orientation: orientation,
                    homeScreenWallpaper: image { springboard_services_get_home_screen_wallpaper_preview(client, $0, $1) },
                    lockScreenWallpaper: image { springboard_services_get_lock_screen_wallpaper_preview(client, $0, $1) }
                )
            }
        }
    }

    func performPowerAction(_ action: DevicePowerAction) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to Diagnostics Relay",
                missingClientMessage: "Diagnostics Relay client was not created",
                connect: { diagnostics_relay_client_connect_rsd(adapter, handshake, $0) },
                cleanup: { diagnostics_relay_client_free($0) }
            ) { client in
                let ffiError: UnsafeMutablePointer<IdeviceFfiError>?
                switch action {
                case .restart: ffiError = diagnostics_relay_client_restart(client)
                case .shutdown: ffiError = diagnostics_relay_client_shutdown(client)
                case .sleep: ffiError = diagnostics_relay_client_sleep(client)
                }
                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to \(action.rawValue) device")
                }
            }
        }
    }

    func deviceDiagnostics() throws -> [DeviceDiagnosticEntry] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to Diagnostics Relay",
                missingClientMessage: "Diagnostics Relay client was not created",
                connect: { diagnostics_relay_client_connect_rsd(adapter, handshake, $0) },
                cleanup: { diagnostics_relay_client_free($0) }
            ) { client in
                var response: plist_t?
                if let ffiError = diagnostics_relay_client_all(client, &response) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to fetch device diagnostics")
                }
                defer { if let response { plist_free(response) } }
                return try IdeviceBridge.diagnosticDictionary(from: response)
                    .map { DeviceDiagnosticEntry(key: $0.key, value: String(describing: $0.value)) }
                    .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            }
        }
    }

    func sideloadedManagedApps() throws -> [ManagedApp] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.plistDictionaries(adapter: adapter, handshake: handshake)
                .filter { $0["ProfileValidated"] != nil }
                .compactMap { dictionary -> ManagedApp? in
                    guard let bundleID = dictionary["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
                    return ManagedApp(bundleID: bundleID, name: IdeviceBridge.appName(from: dictionary))
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func uninstallSideloadedApp(bundleID: String) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Unable to open App Service",
                missingClientMessage: "App Service client was not created",
                connect: { app_service_connect_rsd(adapter, handshake, $0) },
                cleanup: { app_service_free($0) }
            ) { client in
                if let ffiError = app_service_uninstall_app(client, bundleID) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to uninstall \(bundleID)")
                }
            }
        }
    }

    func installIPA(from localURL: URL) throws {
        let stageDirectory = "/PublicStaging"
        let stagedPath = "\(stageDirectory)/StikDebug-\(UUID().uuidString).ipa"
        try uploadRemoteFile(from: localURL, to: stagedPath)
        defer { try? deleteRemotePath(stagedPath) }

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to installation proxy",
                missingClientMessage: "Installation proxy client was not created",
                connect: { installation_proxy_connect_rsd(adapter, handshake, $0) },
                cleanup: { installation_proxy_client_free($0) }
            ) { client in
                if let ffiError = installation_proxy_install(client, stagedPath, nil) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to install IPA")
                }
            }
        }
    }

    func setDeveloperMode(enabled: Bool) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to AMFI",
                missingClientMessage: "AMFI client was not created",
                connect: { amfi_connect_rsd(adapter, handshake, $0) },
                cleanup: { amfi_client_free($0) }
            ) { client in
                let ffiError = enabled ? amfi_enable_developer_mode(client) : amfi_reveal_developer_mode_option_in_ui(client)
                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Developer Mode request failed")
                }
            }
        }
    }

    func renameDevice(to name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw IdeviceBridge.makeError(message: "Enter a device name")
        }
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
                cleanup: { lockdownd_client_free($0) }
            ) { client in
                let value = plist_new_string(trimmedName)
                guard let value else {
                    throw IdeviceBridge.makeError(message: "Could not encode the new device name")
                }
                defer { plist_free(value) }
                if let ffiError = lockdownd_set_value(client, "DeviceName", value, nil) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to rename device")
                }
            }
        }
    }

    func postDeviceNotification(_ name: String) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to Notification Proxy",
                missingClientMessage: "Notification Proxy client was not created",
                connect: { notification_proxy_connect_rsd(adapter, handshake, $0) },
                cleanup: { notification_proxy_client_free($0) }
            ) { client in
                if let ffiError = notification_proxy_post(client, name) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to post notification")
                }
            }
        }
    }

    func captureSysdiagnose() throws -> URL {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to sysdiagnose service",
                missingClientMessage: "Sysdiagnose client was not created",
                connect: { diagnostics_service_connect_rsd(adapter, handshake, $0) },
                cleanup: { diagnostics_service_free($0) }
            ) { client in
                var suggestedFilename: UnsafeMutablePointer<CChar>?
                var expectedLength: UInt = 0
                var stream: OpaquePointer?
                if let ffiError = diagnostics_service_capture_sysdiagnose(client, false, &suggestedFilename, &expectedLength, &stream) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to start sysdiagnose")
                }
                defer {
                    if let suggestedFilename { idevice_string_free(suggestedFilename) }
                    if let stream { sysdiagnose_stream_free(stream) }
                }
                guard let stream else { throw IdeviceBridge.makeError(message: "Sysdiagnose stream was not created") }
                let name = suggestedFilename.flatMap { String(validatingUTF8: $0) } ?? "sysdiagnose.tar.gz"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                while true {
                    var bytes: UnsafeMutablePointer<UInt8>?
                    var length: UInt = 0
                    if let ffiError = sysdiagnose_stream_next(stream, &bytes, &length) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to read sysdiagnose data")
                    }
                    guard length > 0 else { break }
                    guard let bytes else { throw IdeviceBridge.makeError(message: "Sysdiagnose stream returned an invalid chunk") }
                    handle.write(Data(bytes: bytes, count: Int(length)))
                }
                _ = expectedLength
                return url
            }
        }
    }

    func capturePackets(for duration: TimeInterval = 30) throws -> URL {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to packet capture service",
                missingClientMessage: "Packet capture client was not created",
                connect: { pcapd_connect_rsd(adapter, handshake, $0) },
                cleanup: { pcapd_client_free($0) }
            ) { client in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("StikDebug-\(Int(Date().timeIntervalSince1970)).pcap")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }

                // libpcap global header: little-endian, microsecond timestamps, LINKTYPE_RAW.
                var globalHeader: [UInt8] = [0xd4, 0xc3, 0xb2, 0xa1, 0x02, 0x00, 0x04, 0x00]
                globalHeader += [0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0x65, 0x00, 0, 0]
                handle.write(Data(globalHeader))

                let deadline = Date().addingTimeInterval(duration)
                while Date() < deadline {
                    var packet: UnsafeMutablePointer<DevicePacketHandle>?
                    if let ffiError = pcapd_next_packet(client, &packet) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Packet capture stopped")
                    }
                    guard let packet else { continue }
                    defer { pcapd_device_packet_free(packet) }
                    let value = packet.pointee
                    guard let data = value.data, value.data_len > 0 else { continue }
                    let length = UInt32(min(value.data_len, UInt(UInt32.max)))
                    var record = Data()
                    for item in [value.seconds, value.microseconds, length, length] {
                        var littleEndian = item.littleEndian
                        record.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
                    }
                    record.append(Data(bytes: data, count: Int(length)))
                    handle.write(record)
                }
                return url
            }
        }
    }
}
