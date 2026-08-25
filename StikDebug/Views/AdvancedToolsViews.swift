//
//  AdvancedToolsViews.swift
//  StikDebug
//

import SwiftUI
import UniformTypeIdentifiers

private struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct AdvancedToolsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Inspect") {
                    NavigationLink { DeviceDiagnosticsView() } label: {
                        Label("Device Diagnostics", systemImage: "heart.text.square")
                    }
                    NavigationLink { PerformanceDashboardView() } label: {
                        Label("Performance Dashboard", systemImage: "chart.xyaxis.line")
                    }
                    NavigationLink { EnergyMonitorView() } label: {
                        Label("Energy Monitor", systemImage: "bolt")
                    }
                    NavigationLink { GraphicsMonitorView() } label: {
                        Label("Graphics & FPS", systemImage: "speedometer")
                    }
                    NavigationLink { NetworkMonitorView() } label: {
                        Label("Network Monitor", systemImage: "network")
                    }
                    NavigationLink { CrashReportsView() } label: {
                        Label("Crash Reports", systemImage: "exclamationmark.triangle")
                    }
                    NavigationLink { AFCFileBrowserView(path: "/") } label: {
                        Label("Device Files", systemImage: "folder")
                    }
                    NavigationLink { SpringBoardView() } label: {
                        Label("SpringBoard", systemImage: "rectangle.3.group")
                    }
                }
                Section("Capture & Export") {
                    NavigationLink { CaptureToolsView() } label: {
                        Label("Captures", systemImage: "waveform.path.ecg")
                    }
                    NavigationLink { LocalBackupView() } label: {
                        Label("Create Local Backup", systemImage: "externaldrive.badge.plus")
                    }
                }
                Section("Device") {
                    NavigationLink { SideloadedAppsManagerView() } label: {
                        Label("Sideloaded Apps", systemImage: "app.badge")
                    }
                    NavigationLink { DeviceControlsView() } label: {
                        Label("Device Controls", systemImage: "power")
                    }
                    NavigationLink { NotificationToolsView() } label: {
                        Label("System Notifications", systemImage: "bell")
                    }
                    NavigationLink { CompanionDevicesView() } label: {
                        Label("Companion Devices", systemImage: "applewatch")
                    }
                }
            }
            .navigationTitle("Advanced Tools")
        }
    }
}

struct SideloadedAppsManagerView: View {
    @State private var apps: [ManagedApp] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var removalTarget: ManagedApp?
    @State private var isImportingIPA = false

    var body: some View {
        List(apps) { app in
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.subheadline.weight(.medium))
                Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .swipeActions {
                Button("Uninstall", role: .destructive) { removalTarget = app }
            }
        }
        .overlay {
            if isLoading && apps.isEmpty { ProgressView("Loading sideloaded apps…") }
            if !isLoading && apps.isEmpty { ContentUnavailableView("No Sideloaded Apps", systemImage: "app") }
        }
        .navigationTitle("Sideloaded Apps")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { isImportingIPA = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.disabled(isLoading)
            }
        }
        .task { load() }
        .fileImporter(
            isPresented: $isImportingIPA,
            allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first { install(url) }
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
        .confirmationDialog("Uninstall \(removalTarget?.name ?? "this app")?", isPresented: Binding(get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }), titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                guard let removalTarget else { return }
                uninstall(removalTarget)
                self.removalTarget = nil
            }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: { Text("This removes the app and its data from the device.") }
        .alert("Sideloaded Apps", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        isLoading = true
        Task.detached {
            do {
                let apps = try JITEnableContext.shared.sideloadedManagedApps()
                await MainActor.run { self.apps = apps; self.isLoading = false }
            } catch { await MainActor.run { self.error = error.localizedDescription; self.isLoading = false } }
        }
    }

    private func uninstall(_ app: ManagedApp) {
        Task.detached {
            do {
                try JITEnableContext.shared.uninstallSideloadedApp(bundleID: app.bundleID)
                await MainActor.run { self.apps.removeAll { $0.id == app.id } }
            } catch { await MainActor.run { self.error = error.localizedDescription } }
        }
    }

    private func install(_ ipaURL: URL) {
        isLoading = true
        Task.detached {
            do {
                try JITEnableContext.shared.installIPA(from: ipaURL)
                await MainActor.run { load() }
            } catch { await MainActor.run { self.error = error.localizedDescription; self.isLoading = false } }
        }
    }
}

struct DeviceDiagnosticsView: View {
    @State private var entries: [DeviceDiagnosticEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchText = ""

    private var filteredEntries: [DeviceDiagnosticEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter {
            $0.key.localizedCaseInsensitiveContains(searchText) ||
            $0.value.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List(filteredEntries) { entry in
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.key).font(.subheadline.weight(.medium))
                Text(entry.value).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .overlay {
            if isLoading && entries.isEmpty { ProgressView("Loading diagnostics…") }
        }
        .navigationTitle("Device Diagnostics")
        .searchable(text: $searchText)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.disabled(isLoading)
            }
        }
        .task { load() }
        .alert("Diagnostics", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        isLoading = true
        Task.detached {
            do {
                let entries = try JITEnableContext.shared.deviceDiagnostics()
                await MainActor.run { self.entries = entries; self.isLoading = false }
            } catch { await MainActor.run { self.error = error.localizedDescription; self.isLoading = false } }
        }
    }
}

struct CrashReportsView: View {
    @State private var reports: [CrashReportEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var shareFile: SharedFile?
    @State private var deleteTarget: CrashReportEntry?

    var body: some View {
        List {
            if isLoading && reports.isEmpty {
                ProgressView("Loading crash reports…")
            } else if reports.isEmpty {
                ContentUnavailableView("No Crash Reports", systemImage: "checkmark.shield", description: Text("No reports were returned by the device service."))
            } else {
                ForEach(reports) { report in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.name).font(.subheadline.weight(.medium))
                        HStack {
                            Button("Export") { export(report) }
                            Button("Delete", role: .destructive) { deleteTarget = report }
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Crash Reports")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isLoading)
            }
        }
        .task { load() }
        .alert("Crash Reports", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("Delete this crash report?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let deleteTarget else { return }
                remove(deleteTarget)
                self.deleteTarget = nil
            }
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(items: [file.url])
        }
    }

    private func load() {
        isLoading = true
        Task.detached {
            do {
                let reports = try JITEnableContext.shared.crashReports()
                await MainActor.run { self.reports = reports; self.isLoading = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.isLoading = false }
            }
        }
    }

    private func export(_ report: CrashReportEntry) {
        Task.detached {
            do {
                let url = try JITEnableContext.shared.downloadCrashReport(at: report.path)
                await MainActor.run { self.shareFile = SharedFile(url: url) }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    private func remove(_ report: CrashReportEntry) {
        Task.detached {
            do {
                try JITEnableContext.shared.deleteCrashReport(at: report.path)
                await MainActor.run { self.reports.removeAll { $0.id == report.id } }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}

struct AFCFileBrowserView: View {
    let path: String
    @State private var entries: [RemoteFileEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var shareFile: SharedFile?
    @State private var isImporting = false
    @State private var deleteTarget: RemoteFileEntry?

    var body: some View {
        List {
            if isLoading && entries.isEmpty {
                ProgressView("Loading files…")
            } else {
                ForEach(entries) { entry in
                    if entry.isDirectory {
                        NavigationLink { AFCFileBrowserView(path: entry.path) } label: { entryLabel(entry) }
                    } else {
                        entryLabel(entry)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Export") { download(entry) }.tint(.blue)
                                Button("Delete", role: .destructive) { deleteTarget = entry }
                            }
                    }
                }
            }
        }
        .navigationTitle(path)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Upload Here", systemImage: "square.and.arrow.up") { isImporting = true }
                    Button("Refresh", systemImage: "arrow.clockwise") { load() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { load() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { upload(url) }
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
        .confirmationDialog("Delete this file from the device?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let deleteTarget else { return }
                remove(deleteTarget)
                self.deleteTarget = nil
            }
        }
        .alert("Device Files", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .sheet(item: $shareFile) { file in ShareSheet(items: [file.url]) }
    }

    @ViewBuilder private func entryLabel(_ entry: RemoteFileEntry) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text(entry.name)
                if let size = entry.size, !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: { Image(systemName: entry.isDirectory ? "folder" : "doc") }
    }

    private func load() {
        isLoading = true
        Task.detached {
            do {
                let entries = try JITEnableContext.shared.remoteFiles(at: path)
                await MainActor.run { self.entries = entries; self.isLoading = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.isLoading = false }
            }
        }
    }

    private func download(_ entry: RemoteFileEntry) {
        Task.detached {
            do {
                let url = try JITEnableContext.shared.downloadRemoteFile(at: entry.path)
                await MainActor.run { self.shareFile = SharedFile(url: url) }
            } catch { await MainActor.run { self.error = error.localizedDescription } }
        }
    }

    private func upload(_ url: URL) {
        let destination = path == "/" ? "/\(url.lastPathComponent)" : "\(path)/\(url.lastPathComponent)"
        Task.detached {
            do {
                try JITEnableContext.shared.uploadRemoteFile(from: url, to: destination)
                await MainActor.run { load() }
            } catch { await MainActor.run { self.error = error.localizedDescription } }
        }
    }

    private func remove(_ entry: RemoteFileEntry) {
        Task.detached {
            do {
                try JITEnableContext.shared.deleteRemotePath(entry.path)
                await MainActor.run { self.entries.removeAll { $0.id == entry.id } }
            } catch { await MainActor.run { self.error = error.localizedDescription } }
        }
    }
}

struct CaptureToolsView: View {
    @State private var isWorking = false
    @State private var shareFile: SharedFile?
    @State private var error: String?

    var body: some View {
        List {
            Section("Screen") {
                Button { screenshot() } label: { Label("Capture Device Screenshot", systemImage: "camera") }
                    .disabled(isWorking)
            }
            Section("Network") {
                Button { pcap() } label: {
                    VStack(alignment: .leading) {
                        Label("Capture Network Traffic", systemImage: "point.3.connected.trianglepath.dotted")
                        Text("Captures 30 seconds and exports a PCAP file.").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(isWorking)
            }
            Section("Bluetooth") {
                Button { bluetooth() } label: {
                    VStack(alignment: .leading) {
                        Label("Capture Bluetooth HCI", systemImage: "dot.radiowaves.left.and.right")
                        Text("Captures Bluetooth HCI traffic for 30 seconds as a PCAP file. Apple's Bluetooth logging profile is required for data.").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(isWorking)
            }
            Section("System") {
                Button { sysdiagnose() } label: {
                    VStack(alignment: .leading) {
                        Label("Capture Sysdiagnose", systemImage: "stethoscope")
                        Text("This may take several minutes and produce a very large archive.").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(isWorking)
            }
            if isWorking { ProgressView("Capturing…") }
        }
        .navigationTitle("Captures")
        .sheet(item: $shareFile) { file in ShareSheet(items: [file.url]) }
        .alert("Capture Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func screenshot() {
        run {
            let image = try JITEnableContext.shared.takeDeviceScreenshot()
            guard let data = image.pngData() else { throw NSError(domain: "StikDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not encode screenshot"]) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("StikDebug-Screenshot.png")
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    private func pcap() { run { try JITEnableContext.shared.capturePackets() } }
    private func bluetooth() { run { try JITEnableContext.shared.captureBluetoothPackets() } }
    private func sysdiagnose() { run { try JITEnableContext.shared.captureSysdiagnose() } }

    private func run(_ work: @escaping () throws -> URL) {
        isWorking = true
        Task.detached {
            do {
                let url = try work()
                await MainActor.run { self.shareFile = SharedFile(url: url); self.isWorking = false }
            } catch { await MainActor.run { self.error = error.localizedDescription; self.isWorking = false } }
        }
    }
}

struct DeviceControlsView: View {
    @State private var pendingAction: DevicePowerAction?
    @State private var isWorking = false
    @State private var error: String?
    @State private var message: String?
    @State private var deviceName = ""

    var body: some View {
        List {
            Section("Device Name") {
                TextField("New device name", text: $deviceName)
                Button("Rename Device") { rename() }
                    .disabled(isWorking || deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Developer Mode") {
                Button("Request Developer Mode") { developerMode() }.disabled(isWorking)
                Text("iOS may require confirmation and a restart before Developer Mode becomes active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Power") {
                ForEach(DevicePowerAction.allCases) { action in
                    Button(action.title, role: action == .shutdown ? .destructive : nil) { pendingAction = action }
                }
            }
            if isWorking { ProgressView("Sending request…") }
            if let message { Text(message).foregroundStyle(.green) }
        }
        .navigationTitle("Device Controls")
        .confirmationDialog(pendingAction?.title ?? "", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button(pendingAction?.title ?? "", role: pendingAction == .shutdown ? .destructive : nil) {
                if let pendingAction { power(pendingAction) }
                pendingAction = nil
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { Text(pendingAction?.message ?? "") }
        .alert("Device Controls", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func developerMode() {
        isWorking = true
        Task.detached {
            do {
                try JITEnableContext.shared.setDeveloperMode(enabled: true)
                await MainActor.run { self.message = "Developer Mode request sent."; self.isWorking = false }
            } catch { await MainActor.run { self.error = error.localizedDescription; self.isWorking = false } }
        }
    }

    private func rename() {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        Task.detached {
            do {
                try JITEnableContext.shared.renameDevice(to: name)
                await MainActor.run { self.message = "Device renamed to \(name)."; self.isWorking = false }
            } catch { await MainActor.run { self.error = error.localizedDescription; self.isWorking = false } }
        }
    }

    private func power(_ action: DevicePowerAction) {
        isWorking = true
        Task.detached {
            do {
                try JITEnableContext.shared.performPowerAction(action)
                await MainActor.run { self.message = "\(action.title) request sent."; self.isWorking = false }
            } catch { await MainActor.run { self.error = error.localizedDescription; self.isWorking = false } }
        }
    }
}

struct NotificationToolsView: View {
    @State private var name = ""
    @State private var error: String?
    @State private var message: String?
    @State private var observedNames: [String] = []
    @State private var isObserving = false

    var body: some View {
        Form {
            Section("Post a Darwin notification") {
                TextField("Notification name", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                HStack {
                    Button("Post") { post() }
                    Spacer()
                    Button(isObserving ? "Stop Observing" : "Observe") {
                        isObserving ? stopObserving() : observe()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isObserving)
                Text("Posting a notification can affect running system and third-party software. Use only a notification whose purpose you understand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !observedNames.isEmpty {
                Section("Observed") {
                    ForEach(observedNames.indices, id: \.self) { index in
                        Text(observedNames[index]).font(.caption.monospaced())
                    }
                }
            }
            if let message { Text(message).foregroundStyle(.green) }
        }
        .navigationTitle("System Notifications")
        .alert("Notification Proxy", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .onDisappear { stopObserving() }
    }

    private func post() {
        let notificationName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached {
            do {
                try JITEnableContext.shared.postDeviceNotification(notificationName)
                await MainActor.run { self.message = "Posted \(notificationName)." }
            } catch { await MainActor.run { self.error = error.localizedDescription } }
        }
    }

    private func observe() {
        let notificationName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notificationName.isEmpty else { return }
        observedNames = []
        isObserving = true
        DeviceNotificationStream.shared.start(
            observing: notificationName,
            onNotification: { value in
                observedNames.insert(value, at: 0)
                if observedNames.count > 100 { observedNames.removeLast(observedNames.count - 100) }
            },
            onFailure: { failure in
                error = failure.localizedDescription
                isObserving = false
            }
        )
    }

    private func stopObserving() {
        guard isObserving else { return }
        DeviceNotificationStream.shared.stop()
        isObserving = false
    }
}

struct SpringBoardView: View {
    @State private var snapshot: SpringBoardSnapshot?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let snapshot {
                    LabeledContent("Interface orientation", value: orientationName(snapshot.orientation))
                    if let image = snapshot.homeScreenWallpaper {
                        Text("Home Screen Wallpaper").font(.headline)
                        Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let image = snapshot.lockScreenWallpaper {
                        Text("Lock Screen Wallpaper").font(.headline)
                        Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    ProgressView("Loading SpringBoard…")
                }
            }
            .padding()
        }
        .navigationTitle("SpringBoard")
        .task { load() }
        .alert("SpringBoard", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        Task.detached {
            do {
                let snapshot = try JITEnableContext.shared.springBoardSnapshot()
                await MainActor.run { self.snapshot = snapshot }
            } catch { await MainActor.run { self.error = error.localizedDescription } }
        }
    }

    private func orientationName(_ value: UInt8) -> String {
        switch value {
        case 1: "Portrait"
        case 2: "Portrait Upside Down"
        case 3: "Landscape Left"
        case 4: "Landscape Right"
        default: "Unknown (\(value))"
        }
    }
}



struct LocalBackupView: View {
    @State private var isPickingFolder = false
    @State private var isBackingUp = false
    @State private var progress: DeviceBackupProgress?
    @State private var completedLocation: URL?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button("Choose Folder and Start Backup") { isPickingFolder = true }
                    .disabled(isBackingUp)
                Text("Creates a Finder-compatible local backup in the folder you choose. Restore is intentionally not included in StikDebug.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let progress {
                Section("Progress") {
                    ProgressView(value: max(0, min(progress.fraction / 100, 1)))
                    if progress.bytesTotal > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(progress.bytesDone), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(progress.bytesTotal), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(progress.bytesDone), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let completedLocation {
                Section("Completed") {
                    Text(completedLocation.lastPathComponent)
                    Text(completedLocation.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if isBackingUp { ProgressView("Backing up device…") }
        }
        .navigationTitle("Local Backup")
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let directory = urls.first else { return }
            start(directory)
        }
        .alert("Local Backup", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func start(_ directory: URL) {
        isBackingUp = true
        completedLocation = nil
        progress = nil
        Task.detached {
            do {
                let result = try JITEnableContext.shared.createLocalBackup(in: directory) { progress in
                    DispatchQueue.main.async {
                        self.progress = progress
                    }
                }
                await MainActor.run {
                    self.completedLocation = result
                    self.isBackingUp = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isBackingUp = false
                }
            }
        }
    }
}


struct PerformanceDashboardView: View {
    @State private var snapshot: PerformanceSnapshot?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            if let snapshot {
                Section("Overview") {
                    LabeledContent("Reported processes", value: "\(snapshot.processCount)")
                }
                Section("CPU") {
                    ForEach(snapshot.cpuMetrics) { entry in
                        LabeledContent(entry.key, value: entry.value)
                    }
                }
                Section("System") {
                    ForEach(snapshot.systemMetrics) { entry in
                        LabeledContent(entry.key, value: entry.value)
                    }
                }
            } else if isLoading {
                ProgressView("Sampling device performance…")
            } else {
                ContentUnavailableView("No Sample", systemImage: "chart.xyaxis.line")
            }
        }
        .navigationTitle("Performance")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.disabled(isLoading)
            }
        }
        .task { load() }
        .alert("Performance Dashboard", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        isLoading = true
        Task.detached {
            do {
                let snapshot = try JITEnableContext.shared.performanceSnapshot()
                await MainActor.run { self.snapshot = snapshot; self.isLoading = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.isLoading = false }
            }
        }
    }
}

struct EnergyMonitorView: View {
    @State private var pids = ""
    @State private var samples: [EnergySample] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("Process IDs, e.g. 123, 456", text: $pids)
                    .keyboardType(.numbersAndPunctuation)
                Button("Sample Energy") { load() }.disabled(isLoading)
                Text("Use Process Inspector to find process IDs. The values are Apple's per-process energy counters.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !samples.isEmpty {
                Section("Samples") {
                    ForEach(samples) { sample in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("PID \(sample.pid)").font(.headline)
                            Text("Total \(sample.total, format: .number.precision(.fractionLength(3)))  •  CPU \(sample.cpu, format: .number.precision(.fractionLength(3)))  •  GPU \(sample.gpu, format: .number.precision(.fractionLength(3)))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Network \(sample.network, format: .number.precision(.fractionLength(3)))  •  Display \(sample.display, format: .number.precision(.fractionLength(3)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if isLoading { ProgressView("Sampling energy…") }
        }
        .navigationTitle("Energy Monitor")
        .alert("Energy Monitor", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        let processIDs = pids
            .split(separator: ",")
            .compactMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        isLoading = true
        Task.detached {
            do {
                let samples = try JITEnableContext.shared.energySamples(for: processIDs)
                await MainActor.run { self.samples = samples; self.isLoading = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.isLoading = false }
            }
        }
    }
}

struct GraphicsMonitorView: View {
    @State private var sample: GraphicsSample?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            if let sample {
                Section("Frame Rate") {
                    LabeledContent("Frames per second", value: sample.framesPerSecond, format: .number.precision(.fractionLength(1)))
                    LabeledContent("GPU process", value: sample.gpuProcess)
                    LabeledContent("Recovery count", value: "\(sample.recoveryCount)")
                }
                Section("Graphics Memory") {
                    LabeledContent("Allocated", value: ByteCountFormatter.string(fromByteCount: Int64(sample.allocatedMemory), countStyle: .memory))
                    LabeledContent("In use", value: ByteCountFormatter.string(fromByteCount: Int64(sample.usedMemory), countStyle: .memory))
                    LabeledContent("Driver", value: ByteCountFormatter.string(fromByteCount: Int64(sample.driverMemory), countStyle: .memory))
                }
            } else if isLoading {
                ProgressView("Sampling graphics…")
            } else {
                ContentUnavailableView("No Sample", systemImage: "speedometer")
            }
        }
        .navigationTitle("Graphics & FPS")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.disabled(isLoading)
            }
        }
        .task { load() }
        .alert("Graphics Monitor", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        isLoading = true
        Task.detached {
            do {
                let sample = try JITEnableContext.shared.graphicsSample()
                await MainActor.run { self.sample = sample; self.isLoading = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.isLoading = false }
            }
        }
    }
}

struct NetworkMonitorView: View {
    @State private var activities: [NetworkActivity] = []
    @State private var isMonitoring = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button(isMonitoring ? "Stop Monitoring" : "Start Monitoring") {
                    isMonitoring ? stop() : start()
                }
                Text("Shows connection and interface events generated while this screen is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if activities.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "network")
            } else {
                Section("Activity") {
                    ForEach(activities) { activity in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(activity.kind).font(.subheadline.weight(.medium))
                            Text(activity.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Network Monitor")
        .onDisappear { stop() }
        .alert("Network Monitor", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func start() {
        activities = []
        isMonitoring = true
        NetworkActivityStream.shared.start(
            onActivity: { event in
                activities.insert(event, at: 0)
                if activities.count > 100 { activities.removeLast(activities.count - 100) }
            },
            onFailure: { failure in
                error = failure.localizedDescription
                isMonitoring = false
            }
        )
    }

    private func stop() {
        guard isMonitoring else { return }
        NetworkActivityStream.shared.stop()
        isMonitoring = false
    }
}

struct CompanionDevicesView: View {
    @State private var devices: [String] = []
    @State private var remotePort = ""
    @State private var message: String?
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        List {
            Section("Paired companions") {
                if devices.isEmpty && !isLoading {
                    Text("No paired companion devices were returned.").foregroundStyle(.secondary)
                }
                ForEach(devices, id: \.self) { device in
                    Text(device).font(.caption.monospaced())
                }
                Button("Reload") { load() }.disabled(isLoading)
            }
            Section("Forward a companion service") {
                TextField("Remote port", text: $remotePort).keyboardType(.numberPad)
                Button("Start Forwarding") { forward() }.disabled(remotePort.isEmpty)
                Button("Stop Forwarding", role: .destructive) {
                    CompanionForwardingSession.shared.stop()
                    message = "Forwarding stopped."
                }
                Text("Keeps a selected Apple Watch service port available through the active StikDebug tunnel until you stop it or leave the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isLoading { ProgressView("Loading companions…") }
            if let message { Text(message).foregroundStyle(.green) }
        }
        .navigationTitle("Companion Devices")
        .task { load() }
        .onDisappear { CompanionForwardingSession.shared.stop() }
        .alert("Companion Proxy", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        isLoading = true
        Task.detached {
            do {
                let devices = try JITEnableContext.shared.pairedCompanionDevices()
                await MainActor.run { self.devices = devices; self.isLoading = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.isLoading = false }
            }
        }
    }

    private func forward() {
        guard let port = UInt16(remotePort) else {
            error = "Enter a valid port number."
            return
        }
        Task.detached {
            do {
                let localPort = try CompanionForwardingSession.shared.start(remotePort: port)
                await MainActor.run { self.message = "Remote port \(port) is forwarded on local port \(localPort)." }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}


private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
