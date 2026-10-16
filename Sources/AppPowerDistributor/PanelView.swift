import PowerKit
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    @State private var expanded: UUID?

    init(model: AppModel, initiallyExpanded: UUID? = nil) {
        self.model = model
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    limitsSection
                    usingPowerSection
                }
                .padding(14)
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("App Power Distributor").font(.headline)
                Text(model.isPaused ? "Limits paused" : activeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let watts = model.macWatts {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.watts(watts)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text("whole Mac").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }

    private var activeSummary: String {
        let throttled = model.rules.filter { model.status(of: $0)?.state == .throttled }.count
        let enabled = model.rules.filter(\.isEnabled).count
        if throttled > 0 { return "Throttling \(throttled) app\(throttled == 1 ? "" : "s")" }
        if enabled > 0 { return "\(enabled) limit\(enabled == 1 ? "" : "s") on, nothing over" }
        return "No limits yet"
    }

    // MARK: - Limits

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Limits")
            if model.rules.isEmpty {
                Text("Pick an app below, or choose one that isn't running yet. Its limit applies whenever it runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach($model.rules) { $rule in
                RuleCard(
                    rule: $rule,
                    status: model.status(of: rule),
                    icon: model.icon(for: rule.target),
                    isPaused: model.isPaused,
                    isExpanded: expanded == rule.id,
                    toggleExpanded: { expanded = expanded == rule.id ? nil : rule.id },
                    remove: { model.removeRule(rule.id) }
                )
            }
            Button {
                model.chooseAppToLimit()
            } label: {
                Label("Choose an app…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
    }

    // MARK: - Using power now

    private var usingPowerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Using power now")
            let rows = model.topApps.filter { $0.watts >= 0.05 }.prefix(7)
            if rows.isEmpty {
                Text(model.topApps.isEmpty ? "Measuring…" : "Nothing is using noticeable power.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(rows)) { row in
                HStack(spacing: 8) {
                    Image(nsImage: model.icon(for: row.app.target)).resizable().frame(width: 18, height: 18)
                    Text(row.app.name).lineLimit(1)
                    Spacer()
                    Text(Format.watts(row.watts))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if model.hasRule(for: row.app) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .help("Has a limit")
                            .frame(width: 44)
                    } else {
                        Button("Limit") { model.addRule(for: row.app.target) }
                            .controlSize(.small)
                            .frame(width: 44)
                    }
                }
                .font(.callout)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(model.isPaused ? "Resume limits" : "Pause limits") { model.isPaused.toggle() }
            Spacer()
            Menu {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchesAtLogin($0) }
                ))
                Toggle("Show Mac power in menu bar", isOn: $model.showPowerInMenuBar)
                if let error = model.loginItemError {
                    Divider()
                    Text(error)
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Rule card

struct RuleCard: View {
    @Binding var rule: Rule
    let status: LimiterStatus?
    let icon: NSImage
    let isPaused: Bool
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.target.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(rule.settings.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: toggleExpanded) {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Edit limit")
                Toggle("", isOn: $rule.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if rule.isEnabled && !isPaused {
                StatusLine(settings: rule.settings, status: status)
            }
            if isExpanded {
                Divider()
                RuleEditor(settings: $rule.settings, remove: remove)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusLine: View {
    let settings: LimitSettings
    let status: LimiterStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if settings.capKind != nil, let measured = status?.measured, status?.state != .notRunning {
                LoadBar(fraction: measured / max(settings.capValue, 0.001), throttled: status?.state == .throttled)
            }
            Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let note = status?.note {
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var text: String {
        guard let status else { return "Starting…" }
        switch status.state {
        case .notRunning:
            return "Not running. Applies when it opens."
        case .measuring:
            return "Measuring…"
        case .unthrottled, .throttled:
            var parts: [String] = []
            if let kind = settings.capKind, let measured = status.measured {
                parts.append("\(kind.format(measured)) of \(kind.formatLimit(settings.capValue))")
            }
            if let usage = status.usage, settings.capKind != .appPower {
                parts.append("app \(Format.watts(usage.watts))")
            }
            if settings.capKind != nil {
                parts.append(status.state == .throttled ? "running \(Format.percent(status.duty * 100)) of the time" : "not throttled")
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// Usage relative to the cap. The bar fills to the cap at 3/4 of its width, so going
/// over shows as spilling past the tick.
private struct LoadBar: View {
    let fraction: Double
    let throttled: Bool

    var body: some View {
        GeometryReader { geometry in
            let capX = geometry.size.width * 0.75
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fraction > 1.05 ? Color.orange : (throttled ? Color.accentColor : Color.green))
                    .frame(width: max(4, min(fraction, 1.333) * capX))
                Rectangle().fill(.primary.opacity(0.5)).frame(width: 1.5).offset(x: capX)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

// MARK: - Editor

struct RuleEditor: View {
    @Binding var settings: LimitSettings
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Limit", selection: kindBinding) {
                Text("Mac W").tag(CapKind?.some(.macPower))
                Text("App W").tag(CapKind?.some(.appPower))
                Text("CPU").tag(CapKind?.some(.cpu))
                Text("GPU").tag(CapKind?.some(.gpu))
                Text("None").tag(CapKind?.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let kind = settings.capKind {
                HStack {
                    Slider(value: Binding(
                        get: { settings.capValue },
                        set: { settings.capValue = ($0 / Self.step(for: kind)).rounded() * Self.step(for: kind) }
                    ), in: Self.range(for: kind))
                    Text(kind.formatLimit(settings.capValue))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Efficiency cores only", isOn: $settings.efficiencyCoresOnly)
                .help("Runs the app on the low-power cores only, with lower disk and network priority.")
            Toggle("Keep window responsive", isOn: $settings.spareMainProcess)
                .help("Never pauses the app's main process; only its helper processes are throttled. Works for apps that render in helpers, like Topaz Video AI's ffmpeg.")
                .disabled(settings.capKind == nil)

            HStack {
                Spacer()
                Button("Remove limit", role: .destructive, action: remove)
                    .controlSize(.small)
            }
        }
        .font(.callout)
    }

    private var kindBinding: Binding<CapKind?> {
        Binding(
            get: { settings.capKind },
            set: { kind in
                guard kind != settings.capKind else { return }
                settings.capKind = kind
                if let kind { settings.capValue = Self.defaultValue(for: kind) }
            }
        )
    }

    private var explanation: String {
        switch settings.capKind {
        case .macPower?:
            "Keeps the whole Mac under this, by slowing only this app. Like Low Power Mode, but for one app."
        case .appPower?:
            "The app's own CPU, GPU and Neural Engine power. Memory, fans and the display add more on top."
        case .cpu?:
            "100% is one core; \(Self.coreCount * 100)% is every core."
        case .gpu?:
            "Share of the time the GPU spends on this app."
        case nil:
            "No cap. Use “Efficiency cores only” to slow the app down gently."
        }
    }

    static let coreCount = ProcessInfo.processInfo.activeProcessorCount

    static func range(for kind: CapKind) -> ClosedRange<Double> {
        switch kind {
        case .macPower: 15...160
        case .appPower: 2...150
        case .cpu: 25...Double(coreCount * 100)
        case .gpu: 5...100
        }
    }

    static func step(for kind: CapKind) -> Double {
        switch kind {
        case .macPower, .appPower: 1
        case .cpu: 25
        case .gpu: 5
        }
    }

    static func defaultValue(for kind: CapKind) -> Double {
        switch kind {
        case .macPower: 60
        case .appPower: 30
        case .cpu: Double(coreCount * 50)
        case .gpu: 50
        }
    }
}
