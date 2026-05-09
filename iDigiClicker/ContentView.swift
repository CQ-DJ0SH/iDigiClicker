import SwiftUI
import Charts

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader()
            TabView {
                MonitorTab().tabItem { Label("Monitor", systemImage: "play.circle") }
                SetupTab().tabItem   { Label("Setup",   systemImage: "scope") }
                SettingsTab().tabItem{ Label("Settings",systemImage: "slider.horizontal.3") }
                LogTab().tabItem     { Label("Log",     systemImage: "list.bullet.rectangle") }
            }
            .padding(8)
        }
    }
}

/// Renders the in-app logo from the Assets catalog. Falls back to a visible
/// red placeholder if the asset can't be found — that surfaces a build/asset
/// problem instead of silently rendering nothing.
private struct LogoImage: View {
    var body: some View {
        if let nsImage = NSImage(named: "iDigiLogo") {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                Color.red.opacity(0.2)
                Image(systemName: "questionmark.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.red)
                    .padding(4)
            }
        }
    }
}

/// Large red display of the most recent action next to the logo.
/// Changes are animated with a soft slide-up + crossfade; a single
/// headline stays put until replaced by the next one.
private struct LastActionHeadline: View {
    @EnvironmentObject var state: AppState

    private var event: ActionEvent? { state.lastHeadlineAction }

    private var bodyText: String? {
        guard let e = event else { return nil }
        switch e.kind {
        case .callsign:
            let call = e.label
            if let country = Callsign.country(for: call) {
                return "Reply \(call) · \(country)"
            }
            return "Reply \(call)"
        case .cq:
            return "CQ General Call"
        default:
            return nil
        }
    }

    /// Stable identity for transition triggering: every new action has its
    /// own UUID; the welcome state has a fixed ID so it's treated as a
    /// single item.
    private var transitionKey: String { event?.id.uuidString ?? "welcome" }

    private var content: Text {
        if let t = bodyText {
            return Text("--> ").foregroundColor(.primary)
                + Text(t).foregroundColor(.accentColor)
        } else {
            return Text("Welcome").foregroundColor(.primary)
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .font(.system(.title2, design: .rounded).weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                )
                .id(transitionKey)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal:   .move(edge: .top).combined(with: .opacity)
                ))
        }
        .frame(maxWidth: 420, alignment: .center)
        .clipped()
        .animation(.easeInOut(duration: 0.7), value: transitionKey)
    }
}

private struct BrandHeader: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            // Centered to the window width — independent of the side blocks.
            LastActionHeadline()

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    LogoImage()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("iDigi")
                            .font(.system(.title2, design: .rounded).weight(.regular))
                        Text("Clicker")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .foregroundStyle(.tint)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: state.screenCapturePermission ? "rectangle.dashed.badge.record" : "exclamationmark.triangle.fill")
                            .foregroundStyle(state.screenCapturePermission ? .green : .orange)
                            .font(.caption)
                        Text(state.screenCapturePermission ? "Capture OK" : "Capture denied")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help("Screen recording — click to re-check / re-request.")
                    .onTapGesture { state.recheckScreenCapturePermission() }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.isRunning ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Text(state.isRunning ? "running" : "stopped")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - Monitor

struct MonitorTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(state.isRunning ? .green : .gray)
                    .frame(width: 12, height: 12)
                Text(state.isRunning ? "Running" : "Stopped").font(.headline)
                Spacer()
                Button(state.isRunning ? "Stop" : "Start") {
                    state.isRunning ? state.stop() : state.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!state.settings.isCoordinatesValid)
                Button("Session reset") { state.resetSession() }
                Button("CQ + Answer now") {
                    Task { await state.clickCQAndAnswer(reason: "manual") }
                }
                .disabled(!state.settings.isCoordinatesValid)
            }

            HStack(alignment: .top, spacing: 12) {
                GroupBox("Status") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { Text("Seen callsigns:"); Text("\(state.clickedCallsigns.count)").monospacedDigit() }
                        GridRow {
                            Text("Last new callsign:")
                            Text(state.lastNewCallsignAt.map { Self.formatRelative($0) } ?? "—")
                        }
                        GridRow {
                            Text("Last CQ trigger:")
                            Text(state.lastCQTriggerAt.map { Self.formatRelative($0) } ?? "—")
                        }
                        GridRow {
                            Text("Last detected row:")
                            Text(state.lastDetected.map { "\($0.callsign ?? "—") • \"\($0.text)\"" } ?? "—")
                                .lineLimit(2)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Timer") {
                    TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                        HStack(spacing: 16) {
                            DialGauge(
                                title: "PTT",
                                elapsed: state.lastPTTChangeAt.map { ctx.date.timeIntervalSince($0) },
                                threshold: Double(state.settings.pttCooldownSec),
                                fillTint: .orange,
                                doneTint: .green,
                                doneLabel: "free"
                            )
                            DialGauge(
                                title: "Reply",
                                elapsed: state.lastDoubleClickAt.map { ctx.date.timeIntervalSince($0) },
                                threshold: Double(state.settings.clickStalenessOverrideSec),
                                fillTint: .blue,
                                doneTint: .red,
                                doneLabel: "override"
                            )
                        }
                        .padding(6)
                    }
                }
            }

            GroupBox("iDigi Buttons") {
                HStack(spacing: 12) {
                    ButtonStatusTile(
                        title: "CQ",
                        isActive: state.cqActive,
                        hasPosition: state.settings.cqButton != .zero,
                        action: { state.clickCQOnly(reason: "manual") }
                    )
                    ButtonStatusTile(
                        title: "Answer",
                        isActive: state.answerActive,
                        hasPosition: state.settings.answerButton != .zero,
                        action: { state.clickAnswerOnly(reason: "manual") }
                    )
                    ButtonStatusTile(
                        title: "PTT",
                        isActive: state.pttActive,
                        hasPosition: state.settings.pttButton != .zero,
                        action: nil,
                        activeColor: .red
                    )
                }
                .padding(6)
            }

            GroupBox("Seen callsigns (session)") {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 4, alignment: .leading)],
                        alignment: .leading,
                        spacing: 4
                    ) {
                        ForEach(state.clickedCallsigns.reversed()) { c in
                            ClickedCallsignChip(entry: c) {
                                state.removeClickedCallsign(id: c.id)
                            }
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
            }

            ActionTimelineView()

            Spacer(minLength: 0)
        }
        .padding(12)
    }

    static func formatRelative(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        return "\(secs)s ago"
    }
}

private struct ButtonStatusTile: View {
    let title: String
    let isActive: Bool?
    let hasPosition: Bool
    let action: (() -> Void)?
    var activeColor: Color = .blue

    var body: some View {
        if let action = action {
            Button(action: action) { tile }
                .buttonStyle(.plain)
                .disabled(!hasPosition)
                .help(hasPosition ? "Click sends a mouse click to iDigi" : "Learn position first")
        } else {
            tile
                .help(hasPosition ? "Status (not clickable)" : "Learn position first")
        }
    }

    private var tile: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(fillColor)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if action != nil {
                Image(systemName: "cursorarrow.click")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .underPageBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }

    private var fillColor: Color {
        guard hasPosition else { return .gray.opacity(0.4) }
        switch isActive {
        case .some(true):  return activeColor
        case .some(false): return .gray
        case .none:        return .gray.opacity(0.4)
        }
    }

    private var borderColor: Color {
        switch isActive {
        case .some(true):  return activeColor.opacity(0.6)
        default:           return .secondary.opacity(0.25)
        }
    }

    private var label: String {
        guard hasPosition else { return "Position missing" }
        switch isActive {
        case .some(true):  return "active"
        case .some(false): return "inactive"
        case .none:        return "Status …"
        }
    }
}

// MARK: - Clicked-callsign chip

private struct ClickedCallsignChip: View {
    let entry: ClickedCallsign
    let onRemove: () -> Void

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(Self.timeFmt.string(from: entry.at))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                Text(entry.call)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove callsign from the list — it will be clicked again next time it appears")
            }
            Text(Callsign.country(for: entry.call) ?? "—")
                .font(.system(size: 10))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Dial gauge

private struct DialGauge: View {
    let title: String
    let elapsed: TimeInterval?         // seconds since last event, nil = no event yet
    let threshold: Double              // gauge full = elapsed >= threshold
    let fillTint: Color                // arc color while filling
    let doneTint: Color                // arc color when full
    let doneLabel: String              // small label shown under the seconds when full

    // Progress 0..1: 0 = just happened, 1 = threshold reached.
    private var progress: Double {
        guard let e = elapsed, threshold > 0 else { return 0 }
        return min(1, max(0, e / threshold))
    }
    private var isFull: Bool { progress >= 1 }
    private var arcColor: Color { isFull ? doneTint : fillTint }
    // Arc runs backwards: full when it just happened; empty when threshold reached.
    private var arcAmount: Double { elapsed == nil ? 0 : max(0, 1.0 - progress) }
    private var centerSeconds: String {
        guard let e = elapsed else { return "—" }
        return "\(max(0, Int(threshold - e)))s"
    }
    private var subLabel: String {
        guard elapsed != nil else { return "—" }
        return isFull ? doneLabel : "\(Int(threshold))s"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.18), style: StrokeStyle(lineWidth: 6))
                Circle()
                    .trim(from: 0, to: arcAmount)
                    .stroke(arcColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: arcAmount)
                VStack(spacing: 0) {
                    Text(centerSeconds)
                        .font(.system(.title3, design: .monospaced))
                        .monospacedDigit()
                        .bold()
                    Text(subLabel)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 64, height: 64)
        }
    }
}

// MARK: - Action timeline

private struct ActionTimelineView: View {
    @EnvironmentObject var state: AppState
    @State private var windowSeconds: TimeInterval = 300

    private static let kindOrder: [String] = ActionEvent.Kind.allCases.map(\.displayName)

    var body: some View {
        GroupBox(label:
            HStack {
                Text("Recent action history")
                Spacer()
                Picker("", selection: $windowSeconds) {
                    Text("1 min").tag(TimeInterval(60))
                    Text("5 min").tag(TimeInterval(300))
                    Text("15 min").tag(TimeInterval(900))
                    Text("60 min").tag(TimeInterval(3600))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        ) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                let domainStart = now.addingTimeInterval(-windowSeconds)
                let visible = state.actions.filter { $0.date >= domainStart }

                Chart {
                    ForEach(visible) { event in
                        PointMark(
                            x: .value("Time", event.date),
                            y: .value("Type", event.kind.displayName)
                        )
                        .foregroundStyle(color(for: event.kind))
                        .symbolSize(40)
                        .annotation(position: .top, spacing: 2) {
                            if event.kind == .callsign || event.kind == .detected {
                                Text(event.label)
                                    .font(.system(size: 9, design: .monospaced).weight(.semibold))
                                    .foregroundColor(color(for: event.kind))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                    }
                }
                .chartXScale(domain: domainStart...now)
                .chartYScale(domain: Self.kindOrder)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.hour().minute().second())
                    }
                }
                .chartYAxis {
                    AxisMarks(preset: .extended, position: .leading) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 130)
                .padding(.top, 4)
                .overlay {
                    if visible.isEmpty {
                        Text("no actions in window yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func color(for kind: ActionEvent.Kind) -> Color {
        switch kind {
        case .detected: return .gray
        case .callsign: return .blue
        case .cq:       return .orange
        case .answer:   return .green
        }
    }
}

// MARK: - Setup

struct SetupTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Learn coordinates + colors").font(.title3).bold()
                Text("Click \"Learn position\", then click the button in iDigi. We remember the position, wait briefly, read the color, send a synthetic click (toggles back), wait, and read again — whichever of the two readings is bluer is the active one. You don't have to do anything else; the button is left in its original state.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                GroupBox("CQ button") {
                    ButtonLearnCard(
                        position: state.settings.cqButton,
                        active: state.settings.cqActiveColor,
                        inactive: state.settings.cqInactiveColor,
                        onLearnPosition: { state.learnCQ() },
                        onRelearnColors: { Task { await state.relearnCQColors() } }
                    )
                }

                GroupBox("Answer button") {
                    ButtonLearnCard(
                        position: state.settings.answerButton,
                        active: state.settings.answerActiveColor,
                        inactive: state.settings.answerInactiveColor,
                        onLearnPosition: { state.learnAnswer() },
                        onRelearnColors: { Task { await state.relearnAnswerColors() } }
                    )
                }

                GroupBox("PTT button") {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Position:").frame(width: 110, alignment: .leading)
                                Text(point: state.settings.pttButton)
                            }
                            Text("Detection: red-dominant pixels (R≫G,B). No color learning needed — and a synthetic click on PTT would actually transmit.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Learn position") { state.learnPTT() }
                    }
                    .padding(6)
                }

                GroupBox("Receive window") {
                    HStack {
                        Text("origin=(\(Int(state.settings.windowOrigin.x)),\(Int(state.settings.windowOrigin.y))) size=(\(Int(state.settings.windowSize.width))×\(Int(state.settings.windowSize.height)))")
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Learn (2 clicks)") { state.learnWindowTopLeft() }
                    }
                    .padding(6)
                }

                HStack {
                    Button("Cancel learn mode") { state.cancelLearning() }
                    Spacer()
                    Button("Check accessibility") {
                        if !Clicker.hasAccessibilityPermission(prompt: true) {
                            Clicker.openAccessibilitySettings()
                        }
                    }
                    Button("Open screen recording") { Clicker.openScreenRecordingSettings() }
                }

                GroupBox("Notes") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• iDigiClicker needs **Accessibility** (for clicks) and **Screen Recording** (for pixel analysis).")
                        Text("• The receive window area should fully contain the list of received messages — without the toolbar.")
                        Text("• Once both color references are learned, the comparison \"closer to active or inactive color?\" decides. Otherwise the RGB-range fallback from the Settings tab is used.")
                    }
                    .font(.callout)
                    .padding(6)
                }
            }
            .padding(12)
        }
    }
}

private struct ButtonLearnCard: View {
    let position: CGPoint
    let active: RGB?
    let inactive: RGB?
    let onLearnPosition: () -> Void
    let onRelearnColors: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Position:").frame(width: 110, alignment: .leading)
                Text(point: position)
                Spacer()
                Button("Learn position", action: onLearnPosition)
            }
            HStack {
                Text("Inactive (gray):").frame(width: 110, alignment: .leading)
                ColorSwatch(rgb: inactive)
                Text(inactive?.displayString ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(inactive == nil ? .secondary : .primary)
                Spacer()
            }
            HStack {
                Text("Active (blue):").frame(width: 110, alignment: .leading)
                ColorSwatch(rgb: active)
                Text(active?.displayString ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(active == nil ? .secondary : .primary)
                Spacer()
                Button("Relearn colors", action: onRelearnColors)
                    .disabled(position == .zero)
            }
        }
        .padding(6)
    }
}

private struct ColorSwatch: View {
    let rgb: RGB?
    var body: some View {
        let c = rgb.map { Color(red: Double($0.r)/255, green: Double($0.g)/255, blue: Double($0.b)/255) } ?? Color.clear
        RoundedRectangle(cornerRadius: 3)
            .fill(c)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
            .frame(width: 22, height: 14)
    }
}

private extension Text {
    init(point p: CGPoint) {
        if p == .zero {
            self = Text("—")
        } else {
            self = Text("x=\(Int(p.x)) y=\(Int(p.y))").font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Timing") {
                Stepper(value: Binding(get: { state.settings.pollIntervalMs }, set: { state.settings.pollIntervalMs = $0 }), in: 100...5000, step: 50) {
                    Text("Poll interval: \(state.settings.pollIntervalMs) ms")
                }
                Stepper(value: Binding(get: { state.settings.inactivityTimeoutSec }, set: { state.settings.inactivityTimeoutSec = $0 }), in: 5...600, step: 5) {
                    Text("Inactivity until CQ: \(state.settings.inactivityTimeoutSec) s")
                }
                Stepper(value: Binding(get: { state.settings.searchInactivitySec }, set: { state.settings.searchInactivitySec = $0 }), in: 1...300, step: 1) {
                    Text("Empty search before CQ: \(state.settings.searchInactivitySec) s")
                }
                Stepper(value: Binding(get: { state.settings.doubleClickDelayMs }, set: { state.settings.doubleClickDelayMs = $0 }), in: 30...400, step: 10) {
                    Text("Double-click delay: \(state.settings.doubleClickDelayMs) ms")
                }
                Stepper(value: Binding(get: { state.settings.cqToAnswerDelayMs }, set: { state.settings.cqToAnswerDelayMs = $0 }), in: 100...5000, step: 50) {
                    Text("CQ → Answer delay: \(state.settings.cqToAnswerDelayMs) ms")
                }
                Stepper(value: Binding(get: { state.settings.learnActiveDelayMs }, set: { state.settings.learnActiveDelayMs = $0 }), in: 100...2000, step: 50) {
                    Text("Active-color learn — delay after click: \(state.settings.learnActiveDelayMs) ms")
                }
                Stepper(value: Binding(get: { state.settings.pttCooldownSec }, set: { state.settings.pttCooldownSec = $0 }), in: 0...600, step: 5) {
                    Text("PTT cooldown after change: \(state.settings.pttCooldownSec) s")
                }
                Stepper(value: Binding(get: { state.settings.clickStalenessOverrideSec }, set: { state.settings.clickStalenessOverrideSec = $0 }), in: 30...3600, step: 30) {
                    Text("Click staleness override (ignore PTT cooldown after): \(state.settings.clickStalenessOverrideSec) s")
                }
            }
            Section("Green detection (background, RGB 0–255)") {
                rgbRow("Red",   min: $state.settings.greenMinR, max: $state.settings.greenMaxR)
                rgbRow("Green", min: $state.settings.greenMinG, max: $state.settings.greenMaxG)
                rgbRow("Blue",  min: $state.settings.greenMinB, max: $state.settings.greenMaxB)
                Stepper(value: Binding(get: { state.settings.greenRowMinFraction }, set: { state.settings.greenRowMinFraction = $0 }), in: 0.05...0.95, step: 0.05) {
                    Text("Min. fraction of green pixels per row: \(String(format: "%.2f", state.settings.greenRowMinFraction))")
                }
            }
            Section("White detection (text)") {
                Text("Active CQs have WHITE text on green. Inactive green rows with gray text are ignored.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: Binding(get: { state.settings.whiteMinChannel }, set: { state.settings.whiteMinChannel = $0 }), in: 150...255, step: 5) {
                    Text("White threshold (all channels ≥): \(state.settings.whiteMinChannel)")
                }
                Stepper(value: Binding(get: { state.settings.whiteRowMinFraction }, set: { state.settings.whiteRowMinFraction = $0 }), in: 0.005...0.30, step: 0.005) {
                    Text("Min. fraction of white pixels per row: \(String(format: "%.3f", state.settings.whiteRowMinFraction))")
                }
            }
            Section("Button probe") {
                Text("Sample rectangle W×H around the click point — must lie entirely inside the button, otherwise the surrounding chrome pulls the mean RGB toward chrome. The active/inactive reference colors are auto-filled by \"Learn position\".")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Stepper(value: Binding(get: { state.settings.buttonProbeWidth }, set: { state.settings.buttonProbeWidth = $0 }), in: 4...80, step: 2) {
                        Text("Probe width: \(state.settings.buttonProbeWidth) px")
                    }
                    Stepper(value: Binding(get: { state.settings.buttonProbeHeight }, set: { state.settings.buttonProbeHeight = $0 }), in: 4...60, step: 2) {
                        Text("Probe height: \(state.settings.buttonProbeHeight) px")
                    }
                }
                Stepper(value: Binding(get: { state.settings.colorMatchTolerance }, set: { state.settings.colorMatchTolerance = $0 }), in: 5...150, step: 5) {
                    Text("Color tolerance (only if a reference is missing): \(Int(state.settings.colorMatchTolerance))")
                }
            }
        }
        .padding(12)
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func rgbRow(_ label: String, min minB: Binding<Int>, max maxB: Binding<Int>) -> some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading)
            Stepper(value: minB, in: 0...255, step: 5) { Text("min \(minB.wrappedValue)") }
            Stepper(value: maxB, in: 0...255, step: 5) { Text("max \(maxB.wrappedValue)") }
        }
    }
}

// MARK: - Log

struct LogTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Log (\(state.logger.entries.count) entries)").font(.headline)
                Spacer()
                Button("Clear") { state.logger.clear() }
                Button("Print to console") {
                    for e in state.logger.entries { print(e.formatted) }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.logger.entries) { e in
                            HStack(alignment: .firstTextBaseline) {
                                Text(e.formatted)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(color(for: e.level))
                                    .textSelection(.enabled)
                                    .id(e.id)
                            }
                        }
                    }
                    .padding(6)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .onChange(of: state.logger.entries.count) { _ in
                    if let last = state.logger.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(12)
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info:   return .primary
        case .warn:   return .orange
        case .error:  return .red
        case .action: return .blue
        }
    }
}
