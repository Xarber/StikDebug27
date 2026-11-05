// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine
import Network
import Darwin

struct DiscoveredStikServer: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
}

/// Discovery is optional: copied private links remain usable inside hosts such as LiveContainer.
final class StikServerBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = StikServerBrowser()
    @Published private(set) var servers: [DiscoveredStikServer] = []
    @Published private(set) var discoveryMessage: String?
    private var browsers: [NetServiceBrowser] = []
    private var services: [String: NetService] = [:]
    private var resolved: [String: DiscoveredStikServer] = [:]
    private var lastSeen: [String: Date] = [:]
    private var retry: Timer?
    private let pathMonitor = NWPathMonitor()
    private var running = false

    override init() {
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { if self?.running == true { self?.refresh() } }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.xarber.stikserver.path"))
    }

    func start() {
        guard !running else { return }
        running = true
        search()
        retry = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard running else { start(); return }
        let expired = lastSeen.filter { Date().timeIntervalSince($0.value) > 120 }.map(\.key)
        expired.forEach { resolved.removeValue(forKey: $0); lastSeen.removeValue(forKey: $0) }
        publish()
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        services.values.forEach { $0.stop() }
        services.removeAll()
        search()
    }

    private func search() {
        // Compatibility type is already declared by older StikDebug/host versions.
        for type in ["_stikserver._tcp.", "_stikdebug._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.includesPeerToPeer = true
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard services.count < 64 else { return }
        services[service.type + service.name] = service
        service.delegate = self
        service.includesPeerToPeer = true
        service.resolve(withTimeout: 8)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeValue(forKey: service.type + service.name)?.stop()
        resolved.removeValue(forKey: service.type + service.name)
        lastSeen.removeValue(forKey: service.type + service.name)
        publish()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        discoveryMessage = "Discovery is unavailable in this app host or network. Paste a private StikServer link below; it works independently of Bonjour."
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        guard services[service.type + service.name] === service, service.port > 0 else { return }
        let txt = service.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        guard txt["role"].flatMap({ String(data: $0, encoding: .utf8) }) == "stikserver" else { return }
        let addresses = (service.addresses ?? []).compactMap { data -> String? in
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = data.withUnsafeBytes { bytes -> Int32 in
                guard let base = bytes.baseAddress else { return -1 }
                return getnameinfo(base.assumingMemoryBound(to: sockaddr.self), socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
            return result == 0 ? String(cString: host) : nil
        }.sorted {
            func rank(_ address: String) -> Int {
                if address.hasPrefix("192.168.") || address.hasPrefix("10.") || address.hasPrefix("172.") { return 0 }
                return address.contains(":") ? 2 : 1
            }
            return rank($0) == rank($1) ? $0 < $1 : rank($0) < rank($1)
        }
        guard let host = addresses.first else { return }
        let authority = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        let displayName = txt["name"].flatMap { String(data: $0, encoding: .utf8) } ?? service.name
        resolved[service.type + service.name] = DiscoveredStikServer(id: service.name, name: displayName, address: "http://\(authority):\(service.port)")
        lastSeen[service.type + service.name] = Date()
        discoveryMessage = nil
        publish()
    }

    private func publish() {
        var unique: [String: DiscoveredStikServer] = [:]
        for value in resolved.values { unique[value.id] = value }
        servers = unique.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
