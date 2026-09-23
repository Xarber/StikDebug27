//
//  DeviceEnvironmentView.swift
//  StikDebug
//

import SwiftUI

struct DeviceEnvironmentView: View {
    @ObservedObject private var target = DeviceTargetManager.shared
    @State private var appearance: DeviceAppearance?
    @State private var groups: [DeviceConditionGroup] = []
    @State private var activeProfileID: String?
    @State private var isLoading = false
    @State private var pendingAction: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Target") {
                LabeledContent("Device", value: target.remoteDeviceName ?? "This Device")
                Text("Appearance and conditions are applied to the command target selected in Nearby Device Control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                if let appearance {
                    Picker("Appearance", selection: Binding(
                        get: { appearance },
                        set: { setAppearance($0) }
                    )) {
                        ForEach(DeviceAppearance.allCases) { style in
                            Label(style.title, systemImage: style.systemImage).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(pendingAction != nil)
                } else {
                    HStack {
                        ProgressView()
                        Text("Reading appearance…").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if groups.isEmpty, !isLoading {
                    ContentUnavailableView(
                        "No Conditions Available",
                        systemImage: "gauge.with.dots.needle.33percent",
                        description: Text("This iOS version did not advertise any developer condition profiles.")
                    )
                }

                ForEach(groups) { group in
                    DisclosureGroup(group.title) {
                        ForEach(group.profiles) { profile in
                            Button { enable(profile) } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.detail).foregroundStyle(.primary)
                                        if profile.detail != profile.identifier {
                                            Text(profile.identifier)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if activeProfileID == profile.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else if pendingAction == profile.id {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(pendingAction != nil)
                        }
                    }
                }
            } header: {
                Text("Network & Performance Conditions")
            } footer: {
                Text("These are the same developer condition profiles advertised to Xcode. Available network and performance throttles depend on the target device and iOS version.")
            }

            if activeProfileID != nil {
                Section {
                    Button("Stop Active Condition", role: .destructive) { disableCondition() }
                        .disabled(pendingAction != nil)
                }
            }
        }
        .navigationTitle("Device Environment")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading { ProgressView("Loading conditions…") }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isLoading || pendingAction != nil)
            }
        }
        .task(id: target.selectedTargetID) { load() }
        .alert("Device Environment", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        appearance = nil
        Task.detached {
            do {
                let style = try JITEnableContext.shared.currentDeviceAppearance()
                let conditions = try JITEnableContext.shared.availableDeviceConditions()
                await MainActor.run {
                    appearance = style
                    groups = conditions
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func setAppearance(_ style: DeviceAppearance) {
        let previous = appearance
        appearance = style
        pendingAction = "appearance"
        Task.detached {
            do {
                try JITEnableContext.shared.setDeviceAppearance(style)
                await MainActor.run { pendingAction = nil }
            } catch {
                await MainActor.run {
                    appearance = previous
                    pendingAction = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func enable(_ profile: DeviceConditionProfile) {
        pendingAction = profile.id
        Task.detached {
            do {
                try JITEnableContext.shared.enableDeviceCondition(profile)
                await MainActor.run {
                    activeProfileID = profile.id
                    pendingAction = nil
                }
            } catch {
                await MainActor.run {
                    pendingAction = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func disableCondition() {
        pendingAction = "disable"
        Task.detached {
            do {
                try JITEnableContext.shared.disableDeviceCondition()
                await MainActor.run {
                    activeProfileID = nil
                    pendingAction = nil
                }
            } catch {
                await MainActor.run {
                    pendingAction = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
