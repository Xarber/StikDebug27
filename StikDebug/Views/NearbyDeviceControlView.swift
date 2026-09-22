//
//  NearbyDeviceControlView.swift
//  StikDebug
//

import SwiftUI
import UIKit

struct NearbyDeviceControlView: View {
    @StateObject private var browser = NearbyDeviceBrowser()
    @StateObject private var controller = NearbyRemoteControlModel()
    @StateObject private var pairing = RemotePairingCoordinator()
    @State private var isFullscreen = false
    @State private var isShowingPairing = false
    @State private var remoteKeyboardText = ""

    var body: some View {
        Group {
            if controller.connectedDeviceName != nil {
                connectedView
            } else {
                discoveryView
            }
        }
        .navigationTitle("Nearby Control")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if controller.connectedDeviceName == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(controller.isConnecting)
                }
            }
        }
        .onAppear { browser.start() }
        .onDisappear {
            if controller.connectedDeviceName == nil { browser.stop() }
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            RemoteFullscreenView(controller: controller, isPresented: $isFullscreen)
        }
        .sheet(isPresented: $isShowingPairing, onDismiss: {
            pairing.cancel()
            browser.refresh()
        }) {
            RemotePairingView(pairing: pairing, isPresented: $isShowingPairing)
        }
        .alert(
            "Nearby Control",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private var discoveryView: some View {
        List {
            Section("Pair a Device") {
                Button {
                    browser.stop()
                    isShowingPairing = true
                    pairing.start()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pair New iPhone or iPad")
                            Text("Make StikDebug appear as a Mac in Developer Mode")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "plus.circle.fill")
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
                        Button {
                            browser.stop()
                            controller.connect(to: device)
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name).foregroundStyle(.primary)
                                        Text("Remote pairing").font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                                }
                                Spacer()
                                if controller.isConnecting {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .disabled(controller.isConnecting)
                    }
                }
            }
        }
        .overlay {
            if controller.isConnecting {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Verifying pairing and starting control…")
                    Text("Keep the other device awake and unlocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private var connectedView: some View {
        VStack(spacing: 12) {
            RemoteScreenSurface(image: controller.frame) { gesture in
                send(gesture)
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.secondary.opacity(0.35), lineWidth: 1)
            }

            HStack {
                Text(controller.connectedDeviceName ?? "Nearby Device")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    isFullscreen = true
                } label: {
                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderedProminent)
            }

            Label("All StikDebug tools now target this device", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)

            RemoteHardwareControls(controller: controller)

            HStack(spacing: 8) {
                TextField("Type on remote device", text: $remoteKeyboardText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(sendKeyboardText)
                Button(action: sendKeyboardText) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(remoteKeyboardText.isEmpty)
                Button { controller.backspace() } label: {
                    Image(systemName: "delete.left")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Remote Backspace")
            }

            Button("Disconnect", role: .destructive) {
                controller.disconnect()
                browser.refresh()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func send(_ gesture: RemoteScreenGesture) {
        switch gesture {
        case .tap(let point):
            controller.tap(x: point.x, y: point.y)
        case .drag(let start, let end):
            controller.drag(from: (start.x, start.y), to: (end.x, end.y))
        }
    }

    private func sendKeyboardText() {
        let text = remoteKeyboardText
        remoteKeyboardText = ""
        controller.type(text)
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
                pairingStep(3, "Under Other Devices, choose Pair with StikDebug.")
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
        case .advertising: return "Ready on This Device"
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
        default: return "iphone.gen3.radiowaves.left.and.right"
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            RemoteScreenSurface(image: controller.frame) { gesture in
                switch gesture {
                case .tap(let point):
                    controller.tap(x: point.x, y: point.y)
                case .drag(let start, let end):
                    controller.drag(from: (start.x, start.y), to: (end.x, end.y))
                }
            }
            .ignoresSafeArea()

            Button {
                isPresented = false
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)
            .padding(16)
            .accessibilityLabel("Exit Fullscreen")
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

private enum RemoteScreenGesture {
    case tap(RemoteNormalizedPoint)
    case drag(RemoteNormalizedPoint, RemoteNormalizedPoint)
}

private struct RemoteNormalizedPoint {
    let x: UInt16
    let y: UInt16
}

private struct RemoteScreenSurface: View {
    let image: UIImage?
    let action: (RemoteScreenGesture) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image {
                    let fittedSize = aspectFit(image.size, inside: geometry.size)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let start = normalized(value.startLocation, in: fittedSize)
                                    let end = normalized(value.location, in: fittedSize)
                                    let distance = hypot(
                                        value.location.x - value.startLocation.x,
                                        value.location.y - value.startLocation.y
                                    )
                                    if distance < 8 {
                                        action(.tap(end))
                                    } else {
                                        action(.drag(start, end))
                                    }
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
        .aspectRatio(image.map { $0.size.width / $0.size.height } ?? 9 / 19.5, contentMode: .fit)
    }

    private func aspectFit(_ source: CGSize, inside destination: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return destination }
        let scale = min(destination.width / source.width, destination.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> RemoteNormalizedPoint {
        let x = min(max(point.x / max(size.width, 1), 0), 1)
        let y = min(max(point.y / max(size.height, 1), 0), 1)
        return RemoteNormalizedPoint(
            x: UInt16((x * Double(UInt16.max)).rounded()),
            y: UInt16((y * Double(UInt16.max)).rounded())
        )
    }
}
