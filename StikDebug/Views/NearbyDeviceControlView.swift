//
//  NearbyDeviceControlView.swift
//  StikDebug
//

import SwiftUI
import UIKit

struct NearbyDeviceControlView: View {
    @StateObject private var browser = NearbyDeviceBrowser()
    @StateObject private var controller = NearbyRemoteControlModel()
    @State private var isFullscreen = false

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
            Section {
                Text("The other device must have Developer Mode enabled and its developer image mounted. Approve the pairing prompt on that device when asked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    Text("Pairing and starting display control…")
                    Text("Check the nearby device for a pairing prompt.")
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
