//
//  MonitoringServices.swift
//  StikDebug
//

import Foundation
import Darwin
import idevice

struct PerformanceSnapshot {
    let systemMetrics: [DeviceDiagnosticEntry]
    let cpuMetrics: [DeviceDiagnosticEntry]
    let processCount: Int
}

struct EnergySample: Identifiable {
    let pid: UInt32
    let timestamp: Int64
    let total: Double
    let cpu: Double
    let gpu: Double
    let network: Double
    let display: Double

    var id: String { "\(pid)-\(timestamp)" }
}

struct GraphicsSample {
    let timestamp: UInt64
    let framesPerSecond: Double
    let allocatedMemory: UInt64
    let usedMemory: UInt64
    let driverMemory: UInt64
    let gpuProcess: String
    let recoveryCount: UInt64
}

struct NetworkActivity: Identifiable {
    let kind: String
    let detail: String
    let timestamp = Date()

    var id: String { "\(timestamp.timeIntervalSince1970)-\(kind)-\(detail)" }
}

extension IdeviceBridge {
    static func withRemoteServer<T>(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        try withConnectedClient(
            fallback: "Failed to connect to the Instruments service",
            missingClientMessage: "Instruments service was not created",
            connect: { remote_server_connect_rsd(adapter, handshake, $0) },
            cleanup: { remote_server_free($0) },
            body
        )
    }

    static func plistObject(from plist: plist_t?) throws -> Any {
        guard let plist else { return [:] }
        var binary: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        guard plist_to_bin(plist, &binary, &length) == PLIST_ERR_SUCCESS,
              let binary,
              length > 0 else {
            throw makeError(message: "Failed to decode Instruments response")
        }
        defer { plist_mem_free(binary) }
        return try PropertyListSerialization.propertyList(
            from: Data(bytes: binary, count: Int(length)),
            format: nil
        )
    }

    static func dvtAttributes(
        _ server: OpaquePointer
    ) throws -> (process: [String], system: [String]) {
        try withConnectedClient(
            fallback: "Failed to connect to Instruments device info",
            missingClientMessage: "Instruments device-info client was not created",
            connect: { device_info_new(server, $0) },
            cleanup: { device_info_free($0) }
        ) { client in
            func load(
                _ loader: (OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>, UnsafeMutablePointer<UInt>) -> UnsafeMutablePointer<IdeviceFfiError>?
            ) throws -> [String] {
                var values: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                var count: UInt = 0
                if let ffiError = loader(client, &values, &count) {
                    throw consumeFFIError(ffiError, fallback: "Failed to fetch Instruments attributes")
                }
                defer {
                    if let values {
                        device_info_string_array_free(values, count)
                    }
                }
                guard let values else { return [] }
                return (0..<Int(count)).compactMap { values[$0].flatMap { String(validatingUTF8: $0) } }
            }

            return try (
                process: load(device_info_sysmon_process_attributes),
                system: load(device_info_sysmon_system_attributes)
            )
        }
    }
}

extension JITEnableContext {
    func performanceSnapshot() throws -> PerformanceSnapshot {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withRemoteServer(adapter: adapter, handshake: handshake) { server in
                let attributes = try IdeviceBridge.dvtAttributes(server)
                let processCStringPointers = attributes.process.map { strdup($0) }
                let systemCStringPointers = attributes.system.map { strdup($0) }
                defer {
                    processCStringPointers.forEach { free($0) }
                    systemCStringPointers.forEach { free($0) }
                }

                return try IdeviceBridge.withConnectedClient(
                    fallback: "Failed to connect to system monitor",
                    missingClientMessage: "System monitor was not created",
                    connect: { sysmontap_new(server, $0) },
                    cleanup: { sysmontap_free($0) }
                ) { monitor in
                    var config = IdeviceSysmontapConfig()
                    config.interval_ms = 750
                    var processes = processCStringPointers.map { UnsafePointer($0) }
                    var systems = systemCStringPointers.map { UnsafePointer($0) }
                    try processes.withUnsafeBufferPointer { processBuffer in
                        try systems.withUnsafeBufferPointer { systemBuffer in
                            config.process_attributes = processBuffer.baseAddress
                            config.process_attributes_count = UInt(processBuffer.count)
                            config.system_attributes = systemBuffer.baseAddress
                            config.system_attributes_count = UInt(systemBuffer.count)
                            if let ffiError = sysmontap_set_config(monitor, &config) {
                                throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to configure system monitor")
                            }
                        }
                    }
                    if let ffiError = sysmontap_start(monitor) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to start system monitor")
                    }
                    defer { _ = sysmontap_stop(monitor) }

                    var processesPlist: plist_t?
                    var systemPlist: plist_t?
                    var cpuPlist: plist_t?
                    if let ffiError = sysmontap_next_sample(monitor, &processesPlist, &systemPlist, &cpuPlist) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to sample device performance")
                    }
                    defer {
                        if let processesPlist { plist_free(processesPlist) }
                        if let systemPlist { plist_free(systemPlist) }
                        if let cpuPlist { plist_free(cpuPlist) }
                    }

                    let systemValues = (try IdeviceBridge.plistObject(from: systemPlist) as? [Any]) ?? []
                    let systemMetrics = zip(attributes.system, systemValues).map {
                        DeviceDiagnosticEntry(key: $0.0, value: String(describing: $0.1))
                    }
                    let cpuValues = (try IdeviceBridge.plistObject(from: cpuPlist) as? [String: Any]) ?? [:]
                    let cpuMetrics = cpuValues.map {
                        DeviceDiagnosticEntry(key: $0.key, value: String(describing: $0.value))
                    }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                    let processValues = (try IdeviceBridge.plistObject(from: processesPlist) as? [String: Any]) ?? [:]

                    return PerformanceSnapshot(
                        systemMetrics: systemMetrics,
                        cpuMetrics: cpuMetrics,
                        processCount: processValues.count
                    )
                }
            }
        }
    }

    func energySamples(for pids: [UInt32]) throws -> [EnergySample] {
        guard !pids.isEmpty else {
            throw IdeviceBridge.makeError(message: "Enter at least one process ID to sample energy use")
        }
        return try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withRemoteServer(adapter: adapter, handshake: handshake) { server in
                try IdeviceBridge.withConnectedClient(
                    fallback: "Failed to connect to Energy Monitor",
                    missingClientMessage: "Energy Monitor was not created",
                    connect: { energy_monitor_new(server, $0) },
                    cleanup: { energy_monitor_free($0) }
                ) { monitor in
                    try pids.withUnsafeBufferPointer { buffer in
                        if let ffiError = energy_monitor_start_sampling(monitor, buffer.baseAddress, UInt(buffer.count)) {
                            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to start energy monitoring")
                        }
                        defer { _ = energy_monitor_stop_sampling(monitor, buffer.baseAddress, UInt(buffer.count)) }
                        Thread.sleep(forTimeInterval: 1)
                        var samples: UnsafeMutablePointer<IdeviceEnergySample>?
                        var count: UInt = 0
                        if let ffiError = energy_monitor_sample_attributes(monitor, buffer.baseAddress, UInt(buffer.count), &samples, &count) {
                            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to sample energy use")
                        }
                        defer {
                            if let samples { energy_monitor_samples_free(samples, count) }
                        }
                        guard let samples else { return [] }
                        return (0..<Int(count)).map { index in
                            let sample = samples[index]
                            return EnergySample(
                                pid: sample.pid,
                                timestamp: sample.timestamp,
                                total: sample.total_energy,
                                cpu: sample.cpu_energy,
                                gpu: sample.gpu_energy,
                                network: sample.networking_energy,
                                display: sample.display_energy
                            )
                        }
                    }
                }
            }
        }
    }

    func graphicsSample() throws -> GraphicsSample {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withRemoteServer(adapter: adapter, handshake: handshake) { server in
                try IdeviceBridge.withConnectedClient(
                    fallback: "Failed to connect to Graphics Monitor",
                    missingClientMessage: "Graphics Monitor was not created",
                    connect: { graphics_new(server, $0) },
                    cleanup: { graphics_free($0) }
                ) { monitor in
                    if let ffiError = graphics_start_sampling(monitor, 0) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to start graphics monitoring")
                    }
                    defer { _ = graphics_stop_sampling(monitor) }
                    var sample: UnsafeMutablePointer<IdeviceGraphicsSample>?
                    if let ffiError = graphics_next_sample(monitor, &sample) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to sample graphics performance")
                    }
                    guard let sample else { throw IdeviceBridge.makeError(message: "Graphics monitor returned no sample") }
                    defer { graphics_sample_free(sample) }
                    let value = sample.pointee
                    return GraphicsSample(
                        timestamp: value.timestamp,
                        framesPerSecond: value.fps,
                        allocatedMemory: value.alloc_system_memory,
                        usedMemory: value.in_use_system_memory,
                        driverMemory: value.in_use_system_memory_driver,
                        gpuProcess: IdeviceBridge.string(from: value.gpu_bundle_name) ?? "Unknown",
                        recoveryCount: value.recovery_count
                    )
                }
            }
        }
    }

    func pairedCompanionDevices() throws -> [String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to Companion Proxy",
                missingClientMessage: "Companion Proxy was not created",
                connect: { companion_proxy_connect_rsd(adapter, handshake, $0) },
                cleanup: { companion_proxy_client_free($0) }
            ) { client in
                var devices: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                var count: UInt = 0
                if let ffiError = companion_proxy_get_device_registry(client, &devices, &count) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to read companion-device registry")
                }
                defer {
                    if let devices {
                        for index in 0..<Int(count) { if let value = devices[index] { idevice_string_free(value) } }
                        idevice_outer_slice_free(UnsafeMutableRawPointer(devices), count)
                    }
                }
                guard let devices else { return [] }
                return (0..<Int(count)).compactMap { devices[$0].flatMap { String(validatingUTF8: $0) } }
            }
        }
    }

    func captureBluetoothPackets(for duration: TimeInterval = 30) throws -> URL {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to Bluetooth packet logger",
                missingClientMessage: "Bluetooth packet logger was not created",
                connect: { bt_packet_logger_connect_rsd(adapter, handshake, $0) },
                cleanup: { bt_packet_logger_client_free($0) }
            ) { client in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("StikDebug-Bluetooth-\(Int(Date().timeIntervalSince1970)).pcap")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                file.write(Data([0xd4, 0xc3, 0xb2, 0xa1, 0x02, 0x00, 0x04, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0xc9, 0x00, 0, 0]))
                let deadline = Date().addingTimeInterval(duration)
                while Date() < deadline {
                    var packet: UnsafeMutablePointer<BtPacketHandle>?
                    if let ffiError = bt_packet_logger_next_packet(client, &packet) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Bluetooth capture stopped")
                    }
                    guard let packet else { break }
                    defer { bt_packet_free(packet) }
                    let value = packet.pointee
                    guard let payload = value.h4_data else { continue }
                    var record = Data()
                    let headerLength = UInt32(value.h4_data_len + 4)
                    for rawValue in [value.ts_secs, value.ts_usecs, headerLength, headerLength] {
                        var value = rawValue.littleEndian
                        record.append(Data(bytes: &value, count: MemoryLayout<UInt32>.size))
                    }
                    var directionAndType = UInt32(value.kind).littleEndian
                    record.append(Data(bytes: &directionAndType, count: MemoryLayout<UInt32>.size))
                    record.append(Data(bytes: payload, count: Int(value.h4_data_len)))
                    file.write(record)
                }
                return url
            }
        }
    }
}

final class NetworkActivityStream {
    static let shared = NetworkActivityStream()

    private let queue = DispatchQueue(label: "com.stikdebug.network-monitor", qos: .userInitiated)
    private let lock = NSLock()
    private var server: OpaquePointer?
    private var client: OpaquePointer?
    private var running = false

    private init() { }

    func start(onActivity: @escaping (NetworkActivity) -> Void, onFailure: @escaping (Error) -> Void) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async {
            do {
                let handles = try IdeviceBridge.activeTunnelHandles(for: JITEnableContext.shared)
                let server = try IdeviceBridge.connectClient(
                    fallback: "Failed to connect to Instruments service",
                    missingClientMessage: "Instruments service was not created",
                    connect: { remote_server_connect_rsd(handles.adapter, handles.handshake, $0) }
                )
                let client = try IdeviceBridge.connectClient(
                    fallback: "Failed to connect to Network Monitor",
                    missingClientMessage: "Network Monitor was not created",
                    connect: { network_monitor_new(server, $0) }
                )
                if let ffiError = network_monitor_start(client) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to start network monitoring")
                }
                self.lock.lock(); self.server = server; self.client = client; self.lock.unlock()
                while self.isRunning {
                    var event: UnsafeMutablePointer<IdeviceNetworkEvent>?
                    if let ffiError = network_monitor_next_event(client, &event) {
                        if self.isRunning { throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Network monitor stopped") }
                        idevice_error_free(ffiError)
                        break
                    }
                    guard let event else { continue }
                    let value = event.pointee
                    let detail = [
                        IdeviceBridge.string(from: value.interface_name),
                        IdeviceBridge.string(from: value.local_addr.addr).map { "\($0):\(value.local_addr.port)" },
                        IdeviceBridge.string(from: value.remote_addr.addr).map { "\($0):\(value.remote_addr.port)" },
                        value.pid == 0 ? nil : "pid \(value.pid)",
                        value.rx_bytes == 0 && value.tx_bytes == 0 ? nil : "↓\(value.rx_bytes) ↑\(value.tx_bytes)"
                    ].compactMap { $0 }.joined(separator: "  ")
                    network_monitor_event_free(event)
                    DispatchQueue.main.async { onActivity(NetworkActivity(kind: "Network", detail: detail.isEmpty ? "Activity received" : detail)) }
                }
            } catch {
                if self.isRunning { DispatchQueue.main.async { onFailure(error) } }
            }
            self.finish()
        }
    }

    func stop() {
        lock.lock()
        running = false
        let client = client
        self.client = nil
        let server = server
        self.server = nil
        lock.unlock()
        if let client { _ = network_monitor_stop(client); network_monitor_free(client) }
        if let server { remote_server_free(server) }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func finish() {
        lock.lock()
        let client = client; self.client = nil
        let server = server; self.server = nil
        running = false
        lock.unlock()
        if let client { network_monitor_free(client) }
        if let server { remote_server_free(server) }
    }
}

final class CompanionForwardingSession {
    static let shared = CompanionForwardingSession()

    private let lock = NSLock()
    private var client: OpaquePointer?
    private var remotePort: UInt16?

    private init() { }

    func start(remotePort: UInt16) throws -> UInt16 {
        stop()
        let handles = try IdeviceBridge.activeTunnelHandles(for: JITEnableContext.shared)
        let client = try IdeviceBridge.connectClient(
            fallback: "Failed to connect to Companion Proxy",
            missingClientMessage: "Companion Proxy was not created",
            connect: { companion_proxy_connect_rsd(handles.adapter, handles.handshake, $0) }
        )
        var localPort: UInt16 = 0
        if let ffiError = companion_proxy_start_forwarding_service_port(client, remotePort, &localPort) {
            companion_proxy_client_free(client)
            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to forward companion service port")
        }
        lock.lock(); self.client = client; self.remotePort = remotePort; lock.unlock()
        return localPort
    }

    func stop() {
        lock.lock()
        let client = client; self.client = nil
        let remotePort = remotePort; self.remotePort = nil
        lock.unlock()
        if let client {
            if let remotePort { _ = companion_proxy_stop_forwarding_service_port(client, remotePort) }
            companion_proxy_client_free(client)
        }
    }
}
