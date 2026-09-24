import Charts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class BatteryHealthViewModel: ObservableObject {
    @Published var samples: [BatteryHealthSample] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    let target = DeviceConnectionContext.current

    init() {
        samples = (try? BatteryAnalyticsService.storedSamples(for: target.id)) ?? []
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        statusMessage = nil
        Task.detached { [target] in
            do {
                let samples = try BatteryAnalyticsService.syncFromDevice(target: target)
                await MainActor.run {
                    self.samples = samples
                    self.isLoading = false
                    self.statusMessage = samples.isEmpty ? "No battery metrics were found in the available analytics files." : "Battery history updated."
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func importFiles(_ urls: [URL]) {
        isLoading = true
        Task.detached { [target] in
            do {
                let samples = try BatteryAnalyticsService.importFiles(urls, targetID: target.id)
                await MainActor.run {
                    self.samples = samples
                    self.isLoading = false
                    self.statusMessage = "Imported \(urls.count) analytics file\(urls.count == 1 ? "" : "s")."
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct BatteryHealthView: View {
    @StateObject private var model = BatteryHealthViewModel()
    @State private var isImporting = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                targetHeader
                latestMetrics
                healthChart
                insights
                history
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Battery Health")
        .task {
            model.refresh()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { isImporting = true } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel("Import Analytics Files")
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isLoading)
            }
        }
        .overlay { if model.isLoading { ProgressView("Reading analytics…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json, .plainText, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .alert("Battery Health", isPresented: Binding(
            get: { model.errorMessage != nil || model.statusMessage != nil },
            set: { if !$0 { model.errorMessage = nil; model.statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil; model.statusMessage = nil }
        } message: {
            Text(model.errorMessage ?? model.statusMessage ?? "")
        }
    }

    private var targetHeader: some View {
        Label {
            VStack(alignment: .leading) {
                Text(model.target.displayName).font(.headline)
                Text("Reads Analytics and log-aggregated reports from the selected StikDebug device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "battery.100percent")
                .font(.title2)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var latestMetrics: some View {
        if let latest = model.samples.last {
            HStack(spacing: 10) {
                metricCard("Health", latest.healthPercent.map { String(format: "%.1f%%", $0) } ?? "—", "heart.fill")
                metricCard("Cycles", latest.cycleCount.map(String.init) ?? "—", "arrow.triangle.2.circlepath")
                metricCard("Capacity", latest.availableCapacity.map { "\($0) mAh" } ?? "—", "bolt.fill")
                metricCard("Average", latest.averageTemperature.map { String(format: "%.1f °C", $0) } ?? "—", "thermometer.medium")
            }
        } else {
            ContentUnavailableView(
                "No Battery History Yet",
                systemImage: "battery.0percent",
                description: Text("StikDebug automatically reads the available Analytics history from the selected device. You can also import Analytics/log-aggregated files from Files.")
            )
        }
    }

    @ViewBuilder
    private var healthChart: some View {
        let points = model.samples.compactMap { sample in sample.healthPercent.map { (sample.date, $0) } }
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Health Over Time").font(.headline)
                Chart(model.samples) { sample in
                    if let health = sample.healthPercent {
                        LineMark(x: .value("Date", sample.date), y: .value("Health", health))
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("Date", sample.date), y: .value("Health", health))
                    }
                }
                .chartYScale(domain: chartDomain(points.map(\.1)))
                .chartYAxisLabel("Maximum capacity (%)")
                .frame(height: 230)
                .padding()
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    @ViewBuilder
    private var insights: some View {
        if !model.samples.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Insights").font(.headline)
                ForEach(insightLines, id: \.self) { insight in
                    Label(insight, systemImage: "sparkles")
                        .font(.subheadline)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var history: some View {
        if !model.samples.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Measurements").font(.headline)
                ForEach(model.samples.reversed()) { sample in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(sample.date, format: .dateTime.day().month().year())
                            Text(sample.sourceName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(sample.healthPercent.map { String(format: "%.1f%%", $0) } ?? "—").monospacedDigit()
                        Text(sample.cycleCount.map { "\($0) cycles" } ?? "—").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }

    private var insightLines: [String] {
        var result: [String] = []
        let health = model.samples.compactMap { sample in sample.healthPercent.map { (sample, $0) } }
        if let first = health.first, let last = health.last, health.count > 1 {
            let change = last.1 - first.1
            result.append(String(format: "Maximum capacity changed by %+.1f points across %d measurements.", change, health.count))
            if let firstCycles = first.0.cycleCount, let lastCycles = last.0.cycleCount, lastCycles > firstCycles {
                let perHundred = -change / Double(lastCycles - firstCycles) * 100
                result.append(String(format: "Observed degradation is %.2f points per 100 added cycles.", perHundred))
            }
        } else {
            result.append("More analytics dates are needed before StikDebug can calculate a health trend.")
        }
        if let latest = model.samples.last?.healthPercent {
            result.append(latest >= 80 ? "The latest maximum capacity is above Apple's common 80% service threshold." : "The latest maximum capacity is below 80%; reduced runtime is likely.")
        }
        let temperatures = model.samples.compactMap(\.averageTemperature)
        if let maxTemperature = temperatures.max() {
            result.append(maxTemperature >= 35 ? String(format: "Analytics show a warm %.1f °C average at least once, which can accelerate aging.", maxTemperature) : "Recorded average battery temperatures have stayed below 35 °C.")
        }
        return result
    }

    private func metricCard(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(.green)
            Text(value).font(.headline).minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func chartDomain(_ values: [Double]) -> ClosedRange<Double> {
        let minimum = max(0, (values.min() ?? 80) - 3)
        let maximum = min(110, (values.max() ?? 100) + 3)
        return minimum ... max(minimum + 1, maximum)
    }
}
