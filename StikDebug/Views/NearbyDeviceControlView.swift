//
//  NearbyDeviceControlView.swift
//  StikDebug
//

import SwiftUI
import UIKit
import Photos
import UniformTypeIdentifiers

struct NearbyDeviceControlView: View {
    @ObservedObject private var browser = NearbyDeviceBrowser.shared
    @ObservedObject private var deviceTarget = DeviceTargetManager.shared
    @StateObject private var pairing = RemotePairingCoordinator()
    @State private var isShowingPairing = false
    @State private var isImportingPairingFile = false
    @State private var importMessage: String?

    var body: some View {
        deviceList
        .navigationTitle("Nearby Control")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onAppear { browser.start() }
        .sheet(isPresented: $isShowingPairing, onDismiss: {
            pairing.cancel()
            browser.refresh()
        }) {
            RemotePairingView(pairing: pairing, isPresented: $isShowingPairing)
        }
        .fileImporter(
            isPresented: $isImportingPairingFile,
            allowedContentTypes: PairingFileStore.supportedContentTypes + [.data],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                try RemotePairingStore.importPairingFile(from: url)
                importMessage = "Remote pairing file imported. Nearby matching devices will now appear as paired."
                browser.refresh()
            } catch {
                importMessage = error.localizedDescription
            }
        }
        .alert("Pairing File", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("OK", role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    private var deviceList: some View {
        List {
            Section("Command Target") {
                targetPicker
                Text("Every StikDebug tool uses this device. Screen mirroring is controlled separately from each device's page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pair a Device") {
                Button {
                    browser.stop()
                    isShowingPairing = true
                    pairing.start()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pair New Device")
                            Text("Make \(DevicePresentation.localControllerName) appear as a Mac in Developer Mode")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "plus.circle.fill")
                    }
                }

                Button {
                    isImportingPairingFile = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import Remote Pairing File")
                            Text("Use an existing compatible RPPairing identity")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "doc.badge.plus")
                    }
                }
            }

            Section("Nearby Devices") {
                if browser.devices.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(browser.isSearching ? "Searching the local network…" : "No development devices found")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(browser.devices) { device in
                        NavigationLink {
                            RemoteDeviceDetailView(device: device)
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name).foregroundStyle(.primary)
                                        Text(device.isPaired ? "Paired \(device.kind)" : "Unpaired \(device.kind)")
                                            .font(.caption)
                                            .foregroundStyle(device.isPaired ? .green : .secondary)
                                        Text("UUID: \(device.displayedIdentifier)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                } icon: {
                                    Image(systemName: device.isPaired ? "checkmark.circle.fill" : device.systemImage)
                                        .foregroundStyle(device.isPaired ? .green : .secondary)
                                }
                            }
                        }
                        .disabled(!device.isPaired)
                    }
                }
            }
        }
    }

    private var targetPicker: some View {
        Menu {
            Button {
                NotificationCenter.default.post(name: .stopRemoteMirroring, object: nil)
                deviceTarget.selectThisDevice()
            } label: {
                Label("This \(DevicePresentation.localKind)", systemImage: deviceTarget.selectedTargetID == "local" ? "checkmark" : DevicePresentation.localSystemImage)
            }
            ForEach(browser.devices.filter(\.isPaired)) { device in
                Button {
                    guard let pairingFileURL = device.pairingFileURL else { return }
                    deviceTarget.selectRemoteDevice(device, pairingFileURL: pairingFileURL)
                } label: {
                    Label(device.name, systemImage: deviceTarget.selectedTargetID == device.id ? "checkmark" : device.systemImage)
                }
            }
        } label: {
            LabeledContent("Selected Device") {
                Text(deviceTarget.remoteDeviceName ?? "This \(DevicePresentation.localKind)")
            }
        }
    }
}

private struct RemoteDeviceDetailView: View {
    // Keep the StikDebug-as-relay implementation available as a dormant fallback.
    // StikServer normally discovers and controls devices directly on its own network.
    private static let showsStikServerRelay = false

    let device: NearbyDevelopmentDevice
    @StateObject private var controller = NearbyRemoteControlModel()
    @StateObject private var relay = StikServerRelay()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("stikServerAddress") private var serverAddress = ""
    @AppStorage("stikServerToken") private var serverToken = ""
    @State private var isFullscreen = false
    @State private var keyboardActive = false
    @State private var resultMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 3) {
                    Text(device.name).font(.headline)
                    Text(device.kind).font(.subheadline).foregroundStyle(.secondary)
                    Text("UUID: \(device.displayedIdentifier)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                mirrorPanel

                if controller.isMirroring {
                    RemoteHardwareControls(controller: controller)
                    viewerActions
                    if Self.showsStikServerRelay {
                        stikServerControls
                    }
                    RemoteKeyboardCapture(isActive: $keyboardActive, controller: controller)
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                }

                Button {
                    guard let url = device.pairingFileURL else { return }
                    DeviceTargetManager.shared.selectRemoteDevice(device, pairingFileURL: url)
                } label: {
                    Label("Use for All StikDebug Tools", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            relay.disconnect()
            if !isFullscreen { controller.stopMirroring() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive: controller.suspendMirroring()
            case .active: controller.resumeMirroring()
            @unknown default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopRemoteMirroring)) { _ in
            keyboardActive = false
            isFullscreen = false
            relay.disconnect()
            controller.stopMirroring()
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            RemoteFullscreenView(
                controller: controller,
                isPresented: $isFullscreen,
                saveScreenshot: saveScreenshot,
                stopMirroring: {
                    relay.disconnect()
                    controller.stopMirroring()
                }
            )
        }
        .alert("Nearby Control", isPresented: Binding(
            get: { controller.errorMessage != nil || resultMessage != nil },
            set: { if !$0 { controller.errorMessage = nil; resultMessage = nil } }
        )) {
            Button("OK", role: .cancel) { controller.errorMessage = nil; resultMessage = nil }
        } message: {
            Text(controller.errorMessage ?? resultMessage ?? "")
        }
    }

    @ViewBuilder
    private var mirrorPanel: some View {
        if controller.isMirroring {
            RemoteScreenSurface(video: controller.video, orientation: controller.orientation, action: send)
                .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 560)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.secondary.opacity(0.35), lineWidth: 1)
                }
        } else {
            ContentUnavailableView(
                "Screen Mirroring Is Off",
                systemImage: "rectangle.slash",
                description: Text("Viewing the screen is optional and only stays active while this page is open.")
            )
            .frame(minHeight: 260)

            Button {
                controller.startMirroring(to: device)
            } label: {
                Label(controller.isConnecting ? "Connecting…" : "View Screen", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isConnecting)
        }
    }

    private var viewerActions: some View {
        VStack(spacing: 10) {
            HStack {
                Button { isFullscreen = true } label: {
                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button(action: saveScreenshot) {
                    Label("Screenshot", systemImage: "camera")
                }
                Button {
                    keyboardActive.toggle()
                } label: {
                    Label(keyboardActive ? "Hide Keyboard" : "Keyboard", systemImage: "keyboard")
                }
            }
            .buttonStyle(.bordered)

            Button("Stop Mirroring", role: .destructive) {
                keyboardActive = false
                relay.disconnect()
                controller.stopMirroring()
            }
            .buttonStyle(.bordered)
        }
    }

    private var stikServerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Share This Screen with StikServer", systemImage: "network")
                .font(.headline)
            Text("Optional. This sends the active screen and controls to your private StikServer so another browser or Android device can control it. It does not change the selected StikDebug command target.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if relay.state != .connected {
                TextField("Server address, for example 100.64.0.10:8765", text: $serverAddress)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                SecureField("Private token (optional)", text: $serverToken)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                if relay.state == .connected {
                    Button("Disconnect", role: .destructive) { relay.disconnect() }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        relay.connect(
                            serverAddress: serverAddress,
                            token: serverToken,
                            device: device,
                            controller: controller
                        )
                    } label: {
                        Label("Start Web Sharing", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
                Text(relay.state.title)
                    .font(.caption)
                    .foregroundStyle(relay.state == .connected ? .green : .secondary)
                    .lineLimit(1)
            }
            Text("Sharing automatically stops when this device page or its screen stream closes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private func send(_ gesture: RemoteScreenGesture) {
        switch gesture {
        case .touch(let phase, let point):
            controller.touch(phase, x: point.x, y: point.y)
        }
    }

    private func saveScreenshot() {
        guard let image = controller.video.image else {
            resultMessage = "No remote frame is available yet."
            return
        }
        RemotePhotoSaver.save(image, orientation: controller.orientation) { result in
            switch result {
            case .success:
                resultMessage = "Screenshot saved to Photos."
            case .failure(let error):
                resultMessage = error.localizedDescription
            }
        }
    }
}

private struct RemotePairingView: View {
    @ObservedObject var pairing: RemotePairingCoordinator
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: icon)
                        .font(.system(size: 52, weight: .medium))
                        .foregroundStyle(iconColor)
                        .padding(.top, 12)

                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    content
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Pair Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(pairing.isActive ? "Cancel" : "Close") {
                        pairing.cancel()
                        isPresented = false
                    }
                }
            }
        }
        .interactiveDismissDisabled(pairing.isActive)
    }

    @ViewBuilder
    private var content: some View {
        switch pairing.phase {
        case .idle, .preparing:
            ProgressView("Preparing secure pairing…")
                .controlSize(.large)

        case .advertising:
            VStack(alignment: .leading, spacing: 18) {
                Text("On the device you want to control:")
                    .font(.headline)
                pairingStep(1, "Open Settings.")
                pairingStep(2, "Choose Privacy & Security, then Developer Mode.")
                pairingStep(3, "Under Other Devices, choose \(DevicePresentation.localControllerName).")
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for the other device…")
                }
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }

        case .waitingForCode(let code):
            VStack(spacing: 16) {
                Text("Enter this code on the other device:")
                    .foregroundStyle(.secondary)
                Text(code.map(String.init).joined(separator: " "))
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .tracking(2)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
            }

        case .saving:
            ProgressView("Saving trusted device identity…")
                .controlSize(.large)

        case .completed(let message):
            VStack(spacing: 18) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }

        case .failed(let message):
            VStack(spacing: 18) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { pairing.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var title: String {
        switch pairing.phase {
        case .idle, .preparing: return "Preparing Pairing"
        case .advertising: return "Ready on This \(DevicePresentation.localKind)"
        case .waitingForCode: return "Confirm Pairing"
        case .saving: return "Finishing Pairing"
        case .completed: return "Device Paired"
        case .failed: return "Pairing Failed"
        }
    }

    private var icon: String {
        switch pairing.phase {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .waitingForCode: return "number.circle.fill"
        default: return "ipad.and.iphone"
        }
    }

    private var iconColor: Color {
        switch pairing.phase {
        case .completed: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }

    private func pairingStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: Circle())
            Text(text)
        }
    }
}

private struct RemoteHardwareControls: View {
    @ObservedObject var controller: NearbyRemoteControlModel

    var body: some View {
        HStack(spacing: 10) {
            control(.volumeDown)
            control(.home)
            control(.lock)
            control(.volumeUp)
            Menu {
                Button { controller.press(.mute) } label: { Label("Mute", systemImage: "speaker.slash") }
                Button { controller.press(.siri) } label: { Label("Siri", systemImage: "waveform.circle") }
                Divider()
                Button { controller.toggleSoftwareKeyboard() } label: {
                    Label(
                        controller.isSoftwareKeyboardVisible ? "Hide Software Keyboard" : "Show Software Keyboard",
                        systemImage: "keyboard"
                    )
                }
                Divider()
                Button { controller.rotate(.left) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                Button { controller.rotate(.right) } label: { Label("Rotate Right", systemImage: "rotate.right") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .labelStyle(.iconOnly)
    }

    private func control(_ button: RemoteHardwareButton) -> some View {
        Button { controller.press(button) } label: {
            Image(systemName: button.systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(button.title)
    }
}

private struct RemoteFullscreenView: View {
    @ObservedObject var controller: NearbyRemoteControlModel
    @Binding var isPresented: Bool
    let saveScreenshot: () -> Void
    let stopMirroring: () -> Void
    @State private var controlsExpanded = true
    @State private var keyboardActive = false
    @State private var bubbleLocation: CGPoint?
    @State private var dragOrigin: CGPoint?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteScreenSurface(video: controller.video, orientation: controller.orientation) { gesture in
                switch gesture {
                case .touch(let phase, let point):
                    controller.touch(phase, x: point.x, y: point.y)
                }
            }
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            GeometryReader { geometry in
                floatingControls
                    .frame(maxWidth: controlsExpanded ? min(geometry.size.width - 24, 520) : nil)
                    .position(controlLocation(in: geometry.size))
                    .gesture(
                        DragGesture(coordinateSpace: .local)
                            .onChanged { value in
                                let origin = dragOrigin ?? controlLocation(in: geometry.size)
                                if dragOrigin == nil { dragOrigin = origin }
                                bubbleLocation = clamped(
                                    CGPoint(
                                        x: origin.x + value.translation.width,
                                        y: origin.y + value.translation.height
                                    ),
                                    in: geometry.size
                                )
                            }
                            .onEnded { _ in dragOrigin = nil }
                    )
                    .onAppear {
                        if bubbleLocation == nil { bubbleLocation = defaultControlLocation(in: geometry.size) }
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        bubbleLocation = clamped(controlLocation(in: newSize), in: newSize)
                    }
            }

            RemoteKeyboardCapture(isActive: $keyboardActive, controller: controller)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var floatingControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) { controlsExpanded.toggle() }
                } label: {
                    Image(systemName: controlsExpanded ? "chevron.down" : "chevron.up")
                        .frame(width: 36, height: 24)
                }
                .accessibilityLabel(controlsExpanded ? "Collapse Controls" : "Expand Controls")

            }
            .buttonStyle(.bordered)

            if controlsExpanded {
                RemoteHardwareControls(controller: controller)
                HStack {
                    Button { isPresented = false } label: {
                        Label("Exit Fullscreen", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    Button(action: saveScreenshot) { Label("Screenshot", systemImage: "camera") }
                    Button { keyboardActive.toggle() } label: {
                        Label(keyboardActive ? "Hide Input Keyboard" : "Input Keyboard", systemImage: "keyboard.badge.ellipsis")
                    }
                    Button { controller.toggleSoftwareKeyboard() } label: {
                        Label(
                            controller.isSoftwareKeyboardVisible ? "Hide Device Keyboard" : "Show Device Keyboard",
                            systemImage: "keyboard"
                        )
                    }
                    Button("Stop", role: .destructive) {
                        keyboardActive = false
                        stopMirroring()
                        isPresented = false
                    }
                }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
            }
        }
        .padding(10)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func defaultControlLocation(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - 62, y: size.height - 62)
    }

    private func controlLocation(in size: CGSize) -> CGPoint {
        let compactLocation = clamped(bubbleLocation ?? defaultControlLocation(in: size), in: size)
        guard controlsExpanded else { return compactLocation }
        return CGPoint(
            x: size.width / 2,
            y: min(max(compactLocation.y, 110), max(110, size.height - 110))
        )
    }

    private func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 54), max(54, size.width - 54)),
            y: min(max(point.y, 54), max(54, size.height - 54))
        )
    }
}

private enum RemoteScreenGesture {
    case touch(RemoteTouchPhase, RemoteNormalizedPoint)
}

private struct RemoteNormalizedPoint {
    let x: UInt16
    let y: UInt16
}

private struct RemoteScreenSurface: View {
    @ObservedObject var video: RemoteVideoFrameStore
    let orientation: RemoteScreenOrientation
    let action: (RemoteScreenGesture) -> Void
    @State private var isTouchActive = false

    private var image: UIImage? { video.image }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image {
                    let fittedSize = aspectFit(orientedSize(image.size), inside: geometry.size)
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(
                                width: orientation.isLandscape ? fittedSize.height : fittedSize.width,
                                height: orientation.isLandscape ? fittedSize.width : fittedSize.height
                            )
                            .rotationEffect(rotationAngle)
                        Color.clear
                            .frame(width: fittedSize.width, height: fittedSize.height)
                    }
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let point = normalized(value.location, in: fittedSize)
                                    if isTouchActive {
                                        action(.touch(.move, point))
                                    } else {
                                        isTouchActive = true
                                        action(.touch(.down, point))
                                    }
                                }
                                .onEnded { value in
                                    let end = normalized(value.location, in: fittedSize)
                                    action(.touch(.up, end))
                                    isTouchActive = false
                                }
                        )
                } else {
                    ProgressView("Waiting for display…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(image.map { orientedSize($0.size).width / orientedSize($0.size).height } ?? 9 / 19.5, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var rotationAngle: Angle {
        switch orientation {
        case .portrait, .unknown: .zero
        case .portraitUpsideDown: .degrees(180)
        case .landscapeRight: .degrees(90)
        case .landscapeLeft: .degrees(-90)
        }
    }

    private func orientedSize(_ source: CGSize) -> CGSize {
        orientation.isLandscape ? CGSize(width: source.height, height: source.width) : source
    }

    private func aspectFit(_ source: CGSize, inside destination: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return destination }
        let scale = min(destination.width / source.width, destination.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> RemoteNormalizedPoint {
        let displayX = min(max(point.x / max(size.width, 1), 0), 1)
        let displayY = min(max(point.y / max(size.height, 1), 0), 1)
        let (x, y): (Double, Double) = switch orientation {
        case .portrait, .unknown: (displayX, displayY)
        case .portraitUpsideDown: (1 - displayX, 1 - displayY)
        case .landscapeRight: (displayY, 1 - displayX)
        case .landscapeLeft: (1 - displayY, displayX)
        }
        return RemoteNormalizedPoint(
            x: UInt16((x * Double(UInt16.max)).rounded()),
            y: UInt16((y * Double(UInt16.max)).rounded())
        )
    }
}

private struct RemoteKeyboardCapture: UIViewRepresentable {
    @Binding var isActive: Bool
    let controller: NearbyRemoteControlModel

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.delegate = context.coordinator
        field.text = " "
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .send
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.controller = controller
        if isActive, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isActive, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var controller: NearbyRemoteControlModel

        init(controller: NearbyRemoteControlModel) {
            self.controller = controller
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if string.isEmpty, range.length > 0 {
                controller.backspace()
            } else if !string.isEmpty {
                controller.type(string)
            }
            textField.text = " "
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            controller.type("\n")
            return false
        }
    }
}

private enum RemotePhotoSaver {
    static func save(
        _ image: UIImage,
        orientation: RemoteScreenOrientation,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let image = oriented(image, orientation: orientation)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "StikDebug.RemoteScreenshot",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Photos access was not granted."]
                    )))
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { saved, error in
                DispatchQueue.main.async {
                    if saved {
                        completion(.success(()))
                    } else {
                        completion(.failure(error ?? NSError(
                            domain: "StikDebug.RemoteScreenshot",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Photos did not save the screenshot."]
                        )))
                    }
                }
            }
        }
    }

    private static func oriented(_ image: UIImage, orientation: RemoteScreenOrientation) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let value: UIImage.Orientation = switch orientation {
        case .portrait, .unknown: .up
        case .portraitUpsideDown: .down
        case .landscapeRight: .right
        case .landscapeLeft: .left
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: value)
    }
}
