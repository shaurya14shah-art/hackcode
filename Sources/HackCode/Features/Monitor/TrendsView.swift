import SwiftUI
import Charts
import HackCodeKit

/// MONITOR › TRENDS: long-term disk, battery and memory health from hourly local samples, with simple forecasts.
struct TrendsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.monitor
        let samples = app.trends.within(days: vm.trendDays)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Picker("", selection: $vm.trendDays) {
                    Text("7D").tag(7.0)
                    Text("30D").tag(30.0)
                    Text("180D").tag(180.0)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Text("sampled hourly while HackCode runs · kept 180 days · stored locally (owner-only) · never sent to the model")
                    .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(samples.count) samples").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                BracketButton("CLEAR", color: Theme.textTertiary) { app.clearTrends() }
            }
            if samples.count < 2 {
                Panel {
                    InlineState(kind: .empty, title: "Collecting trend data…",
                                detail: "HackCode records one sample per hour while it is open. Charts appear after the second sample; forecasts after two days.")
                }
            }
            HStack(alignment: .top, spacing: Theme.Space.m) {
                DiskTrendCard(samples: samples)
                BatteryTrendCard(samples: samples)
                MemoryTrendCard(samples: samples)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct TrendPoint: Identifiable {
    let time: Date
    let value: Double
    var id: Date { time }
}

private struct TrendChart: View {
    let points: [TrendPoint]
    var color: Color = Theme.accent
    var yLabel: (Double) -> String
    var yDomain: ClosedRange<Double>? = nil

    var body: some View {
        let domain = yDomain ?? Self.autoDomain(points)
        Chart(points) { p in
            // Fill from the visible floor, not from zero, so the area never spills outside the plot.
            AreaMark(x: .value("time", p.time), yStart: .value("floor", domain.lowerBound), yEnd: .value("value", p.value))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("time", p.time), y: .value("value", p.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            if points.count < 40 {
                PointMark(x: .value("time", p.time), y: .value("value", p.value)).foregroundStyle(color).symbolSize(12)
            }
        }
        .chartYScale(domain: domain)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel { Text(v.as(Double.self).map(yLabel) ?? "").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary) }
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Trend chart with \(points.count) samples")
    }

    static func autoDomain(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vs = pts.map(\.value)
        guard let lo = vs.min(), let hi = vs.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.25, abs(hi) * 0.02, 0.0001)
        return max(0, lo - pad)...(hi + pad)
    }
}

private struct TrendCard<Content: View>: View {
    let title: String
    let value: String
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(title).font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                Text(value).font(Theme.Font.title).foregroundStyle(Theme.textPrimary).lineLimit(1)
                content
                Text(caption).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiskTrendCard: View {
    let samples: [TrendSample]

    var body: some View {
        let pts = samples.compactMap { s in s.diskFreeBytes.map { TrendPoint(time: s.time, value: Double($0)) } }
        let latest = samples.last { $0.diskFreeBytes != nil }
        TrendCard(title: "BOOT DISK · FREE SPACE",
                  value: latest?.diskFreeBytes.map { ByteFormat.string($0) + " free" } ?? "—",
                  caption: TrendForecast.diskSummary(samples)) {
            if pts.count > 1 {
                TrendChart(points: pts, yLabel: { ByteFormat.string(Int64($0)) })
            }
        }
    }
}

private struct BatteryTrendCard: View {
    let samples: [TrendSample]

    var body: some View {
        let pts = samples.compactMap { s in s.batteryHealth.map { TrendPoint(time: s.time, value: $0 * 100) } }
        let latest = samples.last { $0.batteryHealth != nil || $0.batteryCycles != nil }
        TrendCard(title: "BATTERY · HEALTH",
                  value: latest?.batteryHealth.map { String(format: "%.1f%% health", $0 * 100) } ?? (samples.isEmpty ? "—" : "no battery data"),
                  caption: caption(pts: pts, latest: latest)) {
            if pts.count > 1 {
                TrendChart(points: pts, color: Theme.info, yLabel: { String(format: "%.0f%%", $0) })
            }
        }
    }

    private func caption(pts: [TrendPoint], latest: TrendSample?) -> String {
        var parts: [String] = []
        if let c = latest?.batteryCycles { parts.append("\(c) cycles") }
        let cyclePts = samples.compactMap { s in s.batteryCycles.map { (s.time, Double($0)) } }
        if let perDay = TrendForecast.slopePerDay(cyclePts) { parts.append(String(format: "%.1f cycles/week", perDay * 7)) }
        if let slope = TrendForecast.slopePerDay(pts.map { ($0.time, $0.value) }, minSpanDays: 7) {
            parts.append(String(format: "%+.2f%% health/month", slope * 30))
        } else if !pts.isEmpty {
            parts.append("health trend after 7 days of samples")
        }
        return parts.isEmpty ? "This Mac reports no battery health data." : parts.joined(separator: " · ")
    }
}

private struct MemoryTrendCard: View {
    let samples: [TrendSample]

    var body: some View {
        let pts = samples.compactMap { s in s.swapUsedBytes.map { TrendPoint(time: s.time, value: Double($0)) } }
        let latest = samples.last { $0.swapUsedBytes != nil }
        let mem = samples.compactMap(\.memoryUsedFraction)
        let avg = mem.isEmpty ? nil : mem.reduce(0, +) / Double(mem.count)
        TrendCard(title: "MEMORY · SWAP USED",
                  value: latest?.swapUsedBytes.map { ByteFormat.string(Int64($0)) + " swap" } ?? "—",
                  caption: avg.map { String(format: "Average memory in use %.0f%% over this range. Swap that keeps growing between restarts suggests memory pressure.", $0 * 100) }
                      ?? "Swap and memory use are sampled hourly.") {
            if pts.count > 1 {
                TrendChart(points: pts, color: Theme.amber, yLabel: { ByteFormat.string(Int64($0)) })
            }
        }
    }
}
