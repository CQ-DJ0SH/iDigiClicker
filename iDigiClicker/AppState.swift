import Foundation
import Combine
import CoreGraphics
import AppKit

struct ClickedCallsign: Identifiable, Equatable {
    let id = UUID()
    let call: String
    let at: Date
}

struct ActionEvent: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let kind: Kind
    let label: String

    enum Kind: String, CaseIterable {
        case detected, callsign, cq, answer
        var displayName: String {
            switch self {
            case .detected: return "Callsign"
            case .callsign: return "Reply"
            case .cq:       return "CQ"
            case .answer:   return "Answer"
            }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var settings: ClickerSettings = ClickerSettings.load() {
        didSet { settings.save() }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var clickedCallsigns: [ClickedCallsign] = []
    @Published private(set) var lastDetected: DetectedRow?
    @Published private(set) var lastNewCallsignAt: Date?
    @Published private(set) var lastCQTriggerAt: Date?
    @Published private(set) var lastPTTChangeAt: Date?
    @Published private(set) var actions: [ActionEvent] = []
    @Published private(set) var cqActive: Bool? = nil
    @Published private(set) var answerActive: Bool? = nil
    @Published private(set) var pttActive: Bool? = nil
    @Published private(set) var screenCapturePermission: Bool = false

    let logger = AppLogger()
    let learner = CoordinateLearner()

    private var pollTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var lastClickedRowSignature: String? = nil   // suppress double-trigger of the same row
    private var lastPTTState: Bool? = nil               // for change detection across poll ticks
    private var lastCooldownLogAt: Date? = nil          // throttle the cooldown log
    @Published private(set) var lastDoubleClickAt: Date? = nil   // last click on a callsign (for staleness override + UI gauge)
    // Anchor for the inactivity trigger. Separate from lastNewCallsignAt
    // (which only feeds the UI display) so that PTT pauses, CQ triggers,
    // and session reset don't overwrite the user-facing "last new callsign"
    // value.
    private var inactivityAnchorAt: Date? = nil
    // Tracks the last time the row search succeeded (analyze() returned a green
    // row whose callsign could be extracted). Whether we actually clicked or
    // skipped because of cooldowns/already-seen does not matter — the search
    // itself was successful. CQ+Answer is gated by this so we don't trigger
    // it while iDigi is still showing decodable callsign rows.
    private var lastSearchHitAt: Date? = nil
    private let maxActions = 500

    init() {
        // Trigger the system's one-time Screen Recording prompt at launch.
        // After the user approves once, every subsequent capture is silent.
        let granted = ScreenMonitor.requestScreenRecordingPermission()
        screenCapturePermission = granted
        if !granted {
            logger.log(.warn, "Screen recording permission missing — please enable it in System Settings.")
        } else {
            logger.log(.info, "Screen recording permission OK.")
        }
        startStatusPolling()
    }

    /// Manual re-check / re-request — exposed in the UI when the user thinks
    /// they granted access but the app still behaves as if it has none.
    func recheckScreenCapturePermission() {
        let granted = ScreenMonitor.requestScreenRecordingPermission()
        screenCapturePermission = granted
        logger.log(.info, "Screen recording permission: \(granted ? "OK" : "missing")")
    }

    private func startStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    if ScreenMonitor.hasScreenRecordingPermission() {
                        await self.refreshButtonStatus()
                        await MainActor.run { self.screenCapturePermission = true }
                    } else {
                        await MainActor.run { self.screenCapturePermission = false }
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func refreshButtonStatus() async {
        let snapshot = settings
        guard snapshot.cqButton != .zero || snapshot.answerButton != .zero || snapshot.pttButton != .zero else { return }
        if snapshot.cqButton != .zero {
            cqActive = await ScreenMonitor.isButtonActive(
                at: snapshot.cqButton,
                activeRef: snapshot.cqActiveColor,
                inactiveRef: snapshot.cqInactiveColor,
                settings: snapshot
            )
        }
        if snapshot.answerButton != .zero {
            answerActive = await ScreenMonitor.isButtonActive(
                at: snapshot.answerButton,
                activeRef: snapshot.answerActiveColor,
                inactiveRef: snapshot.answerInactiveColor,
                settings: snapshot
            )
        }
        if snapshot.pttButton != .zero {
            pttActive = await ScreenMonitor.isPTTRed(at: snapshot.pttButton, settings: snapshot)
        }
    }

    // MARK: - Run control

    func start() {
        guard !isRunning else { return }
        guard settings.isCoordinatesValid else {
            logger.log(.warn, "Start refused: coordinates incomplete. Please learn CQ, Answer, and Window first.")
            return
        }
        if !Clicker.hasAccessibilityPermission(prompt: true) {
            logger.log(.warn, "Accessibility permission missing. Please enable it in System Settings.")
        }
        isRunning = true
        inactivityAnchorAt = Date()
        lastSearchHitAt = Date()
        lastClickedRowSignature = nil
        logger.log(.info, "Monitor started. Interval=\(settings.pollIntervalMs)ms, Inactivity=\(settings.inactivityTimeoutSec)s.")
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        logger.log(.info, "Monitor stopped.")
    }

    func resetSession() {
        clickedCallsigns.removeAll()
        actions.removeAll()
        lastNewCallsignAt = nil
        inactivityAnchorAt = Date()
        lastSearchHitAt = Date()
        lastClickedRowSignature = nil
        // Reset the cooldown timers as well, so clicking is allowed again
        // immediately after reset and the dial gauges start empty (—).
        lastPTTChangeAt = nil
        lastDoubleClickAt = nil
        lastPTTState = nil
        lastCooldownLogAt = nil
        logger.log(.info, "Session reset — seen callsigns, history, and cooldown timers cleared.")
    }

    private func hasClicked(_ call: String) -> Bool {
        clickedCallsigns.contains { $0.call == call }
    }

    /// Removes a callsign from the seen-callsigns list. The next time it
    /// shows up it will be treated as new and clicked again — useful when
    /// you want to call the same station a second time.
    func removeClickedCallsign(id: UUID) {
        clickedCallsigns.removeAll { $0.id == id }
    }

    private func recordAction(_ kind: ActionEvent.Kind, _ label: String) {
        actions.append(ActionEvent(date: Date(), kind: kind, label: label))
        if actions.count > maxActions { actions.removeFirst(actions.count - maxActions) }
    }

    /// Last action that's relevant for the header banner (callsign double-click
    /// or CQ). Detected/Answer are hidden — Detected is noise, and Answer
    /// follows immediately after CQ and would overwrite the CQ display.
    var lastHeadlineAction: ActionEvent? {
        actions.last(where: { $0.kind == .callsign || $0.kind == .cq })
    }

    // MARK: - Coordinate learning

    func learnCQ() {
        logger.log(.info, "Learn CQ: please click the CQ button in iDigi now …")
        learner.start { [weak self] p in
            guard let self else { return }
            self.settings.cqButton = p
            self.logger.log(.action, "CQ position learned: x=\(Int(p.x)) y=\(Int(p.y)) — auto-learning both colors now …")
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let colors = await self.autoLearnButtonColors(label: "CQ", at: p) {
                    self.settings.cqActiveColor = colors.active
                    self.settings.cqInactiveColor = colors.inactive
                }
            }
        }
    }

    func learnPTT() {
        logger.log(.info, "Learn PTT: please click the PTT button in iDigi now …")
        learner.start { [weak self] p in
            guard let self else { return }
            self.settings.pttButton = p
            self.logger.log(.action, "PTT position learned: x=\(Int(p.x)) y=\(Int(p.y))")
        }
    }

    func learnAnswer() {
        logger.log(.info, "Learn Answer: please click the Answer button in iDigi now …")
        learner.start { [weak self] p in
            guard let self else { return }
            self.settings.answerButton = p
            self.logger.log(.action, "Answer position learned: x=\(Int(p.x)) y=\(Int(p.y)) — auto-learning both colors now …")
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let colors = await self.autoLearnButtonColors(label: "Answer", at: p) {
                    self.settings.answerActiveColor = colors.active
                    self.settings.answerInactiveColor = colors.inactive
                }
            }
        }
    }

    /// Manual re-trigger of the color auto-learn sequence. Requires the
    /// position to already be known and iDigi to have focus right now (e.g.
    /// because the user just clicked back and forth). Sends two synthetic
    /// clicks and identifies which state is the active one based on which
    /// reading is bluer.
    func relearnCQColors() async {
        guard settings.cqButton != .zero else {
            logger.log(.warn, "CQ color relearn: learn the position first.")
            return
        }
        logger.log(.info, "CQ color relearn: starting toggle sequence …")
        // First click gives iDigi focus + flips the state. After that the
        // same toggle logic as in the initial learn runs.
        Clicker.click(at: settings.cqButton)
        if let colors = await autoLearnButtonColors(label: "CQ", at: settings.cqButton) {
            settings.cqActiveColor = colors.active
            settings.cqInactiveColor = colors.inactive
        }
    }

    func relearnAnswerColors() async {
        guard settings.answerButton != .zero else {
            logger.log(.warn, "Answer color relearn: learn the position first.")
            return
        }
        logger.log(.info, "Answer color relearn: starting toggle sequence …")
        Clicker.click(at: settings.answerButton)
        if let colors = await autoLearnButtonColors(label: "Answer", at: settings.answerButton) {
            settings.answerActiveColor = colors.active
            settings.answerInactiveColor = colors.inactive
        }
    }

    /// Toggle dance: wait + read color A, synthetic click, wait + read color B.
    /// Whichever of the two is bluer is the active one. The second click
    /// restores the original button state (the user's click flipped it,
    /// our click flips it back).
    private func autoLearnButtonColors(label: String, at p: CGPoint) async -> (active: RGB, inactive: RGB)? {
        let delayMs = settings.learnActiveDelayMs
        let delayNs = UInt64(delayMs) * 1_000_000

        try? await Task.sleep(nanoseconds: delayNs)
        guard let colorA = await ScreenMonitor.sampleMeanRGB(at: p, settings: settings) else {
            logger.log(.error, "\(label): could not read color A.")
            return nil
        }
        logger.log(.info, "\(label) color A (before toggle): \(colorA.displayString)")

        Clicker.click(at: p)
        try? await Task.sleep(nanoseconds: delayNs)
        guard let colorB = await ScreenMonitor.sampleMeanRGB(at: p, settings: settings) else {
            logger.log(.error, "\(label): could not read color B.")
            return nil
        }
        logger.log(.info, "\(label) color B (after toggle): \(colorB.displayString)")

        let aBluness = colorA.b - max(colorA.r, colorA.g)
        let bBluness = colorB.b - max(colorB.r, colorB.g)
        let active: RGB
        let inactive: RGB
        if bBluness > aBluness {
            active = colorB
            inactive = colorA
        } else {
            active = colorA
            inactive = colorB
        }
        logger.log(.action, "\(label) colors learned — active: \(active.displayString), inactive: \(inactive.displayString)")
        return (active, inactive)
    }

    /// Single click on CQ — used by Monitor's tap handler.
    func clickCQOnly(reason: String) {
        guard settings.cqButton != .zero else { return }
        logger.log(.action, "CQ click (\(reason)) at (\(Int(settings.cqButton.x)),\(Int(settings.cqButton.y)))")
        recordAction(.cq, reason)
        Clicker.click(at: settings.cqButton)
    }

    func clickAnswerOnly(reason: String) {
        guard settings.answerButton != .zero else { return }
        logger.log(.action, "Answer click (\(reason)) at (\(Int(settings.answerButton.x)),\(Int(settings.answerButton.y)))")
        recordAction(.answer, reason)
        Clicker.click(at: settings.answerButton)
    }

    private var pendingWindowTopLeft: CGPoint? = nil
    func learnWindowTopLeft() {
        logger.log(.info, "Learn mode: please click the TOP-LEFT corner of the receive window now …")
        learner.start { [weak self] p in
            guard let self else { return }
            self.pendingWindowTopLeft = p
            self.logger.log(.action, "Receive window top-left learned: x=\(Int(p.x)) y=\(Int(p.y)). Now click the bottom-right corner.")
            self.learner.start { [weak self] p2 in
                guard let self, let tl = self.pendingWindowTopLeft else { return }
                let origin = CGPoint(x: min(tl.x, p2.x), y: min(tl.y, p2.y))
                let size   = CGSize(width: abs(p2.x - tl.x), height: abs(p2.y - tl.y))
                self.settings.windowOrigin = origin
                self.settings.windowSize = size
                self.pendingWindowTopLeft = nil
                self.logger.log(.action, "Receive window learned: origin=(\(Int(origin.x)),\(Int(origin.y))) size=(\(Int(size.width))x\(Int(size.height)))")
            }
        }
    }

    func cancelLearning() {
        learner.cancel()
        pendingWindowTopLeft = nil
        logger.log(.info, "Learn mode cancelled.")
    }

    // MARK: - Manual actions

    func clickCQAndAnswer(reason: String) async {
        let cq = settings.cqButton
        let ans = settings.answerButton
        let snapshot = settings

        // CQ — skip if already active.
        let cqState = await ScreenMonitor.isButtonActive(
            at: cq,
            activeRef: snapshot.cqActiveColor,
            inactiveRef: snapshot.cqInactiveColor,
            settings: snapshot
        )
        if cqState == true {
            logger.log(.info, "CQ already active — click skipped.")
            recordAction(.detected, "CQ active")
        } else {
            logger.log(.action, "CQ click (\(reason)) at (\(Int(cq.x)),\(Int(cq.y)))")
            recordAction(.cq, reason)
            Clicker.click(at: cq)
        }

        try? await Task.sleep(nanoseconds: UInt64(settings.cqToAnswerDelayMs) * 1_000_000)

        // Answer — skip if already active.
        let ansState = await ScreenMonitor.isButtonActive(
            at: ans,
            activeRef: snapshot.answerActiveColor,
            inactiveRef: snapshot.answerInactiveColor,
            settings: snapshot
        )
        if ansState == true {
            logger.log(.info, "Answer already active — click skipped.")
            recordAction(.detected, "Answer active")
        } else {
            logger.log(.action, "Answer click at (\(Int(ans.x)),\(Int(ans.y)))")
            recordAction(.answer, reason)
            Clicker.click(at: ans)
        }

        lastCQTriggerAt = Date()
        inactivityAnchorAt = Date()   // restart inactivity window
    }

    // MARK: - Poll loop

    private func pollLoop() async {
        let logger = self.logger
        while !Task.isCancelled {
            let intervalMs = max(100, settings.pollIntervalMs)
            // ScreenMonitor.analyze handles its own off-main pixel work.
            let snapshot = settings

            // PTT red = iDigi is transmitting. While that is the case,
            // suppress the inactivity-driven CQ trigger by pushing the
            // inactivity anchor to "now". The user-facing "last new
            // callsign" timestamp (lastNewCallsignAt) is unaffected.
            // Plus: track every PTT state change so the click-on-callsign
            // path below can enforce the post-PTT cooldown.
            var pttState: Bool? = nil
            if snapshot.pttButton != .zero {
                pttState = await ScreenMonitor.isPTTRed(at: snapshot.pttButton, settings: snapshot)
                pttActive = pttState
                if let prev = lastPTTState, let cur = pttState, prev != cur {
                    lastPTTChangeAt = Date()
                }
                lastPTTState = pttState
                if pttState == true {
                    inactivityAnchorAt = Date()
                    try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
                    continue
                }
            }

            let detection: DetectedRow? = await ScreenMonitor.analyze(settings: snapshot)

            if Task.isCancelled { break }

            if let det = detection {
                lastDetected = det
                if det.callsign != nil {
                    // Search was successful — a doubleclick-eligible row was
                    // found, regardless of whether we actually click it.
                    lastSearchHitAt = Date()
                }
                let signature = "\(Int(det.screenPoint.y))|\(det.callsign ?? det.text)"
                if signature != lastClickedRowSignature, let call = det.callsign {
                    if !hasClicked(call) {
                        // Two hard gates before the doubleclick:
                        //  • PTT cooldown: no click for pttCooldownSec
                        //    after every PTT change.
                        //  • Reply cooldown: no new doubleclick for
                        //    clickStalenessOverrideSec after every
                        //    doubleclick.
                        // Both timers must have expired.
                        let pttGate: Bool = {
                            guard snapshot.pttButton != .zero,
                                  let last = lastPTTChangeAt else { return true }
                            return Date().timeIntervalSince(last) >= Double(snapshot.pttCooldownSec)
                        }()
                        let answerGate: Bool = {
                            guard let lastClick = lastDoubleClickAt else { return true }
                            return Date().timeIntervalSince(lastClick) >= Double(snapshot.clickStalenessOverrideSec)
                        }()
                        if !pttGate || !answerGate {
                            // Skip click. Don't add to clickedCallsigns
                            // and don't set lastClickedRowSignature, so
                            // the callsign stays clickable once the
                            // cooldowns expire. Throttle the log to avoid
                            // spam.
                            let now = Date()
                            if lastCooldownLogAt.map({ now.timeIntervalSince($0) >= 5 }) ?? true {
                                var reasons: [String] = []
                                if !pttGate, let last = lastPTTChangeAt {
                                    reasons.append("PTT \(Int(now.timeIntervalSince(last)))s/\(snapshot.pttCooldownSec)s")
                                }
                                if !answerGate, let lastClick = lastDoubleClickAt {
                                    reasons.append("Reply \(Int(now.timeIntervalSince(lastClick)))s/\(snapshot.clickStalenessOverrideSec)s")
                                }
                                logger.log(.info, "Callsign \(call): cooldown — \(reasons.joined(separator: ", ")) — click delayed.")
                                lastCooldownLogAt = now
                            }
                        } else {
                            let now = Date()
                            clickedCallsigns.append(ClickedCallsign(call: call, at: now))
                            lastNewCallsignAt = now
                            inactivityAnchorAt = now
                            lastClickedRowSignature = signature
                            lastDoubleClickAt = now
                            logger.log(.action, "New callsign \(call) detected — doubleclick at (\(Int(det.screenPoint.x)),\(Int(det.screenPoint.y))). OCR=\"\(det.text)\"")
                            recordAction(.callsign, call)
                            Clicker.doubleClick(at: det.screenPoint, gapMs: settings.doubleClickDelayMs)
                        }
                    } else {
                        // Known callsign — don't click, but inactivity counts as "active".
                        if signature != lastClickedRowSignature {
                            logger.log(.info, "Callsign \(call) already seen — no click.")
                            recordAction(.detected, call)
                        }
                        lastClickedRowSignature = signature
                    }
                } else if det.callsign == nil {
                    // Row detected, but no callsign extractable.
                    if signature != lastClickedRowSignature {
                        logger.log(.warn, "Green row detected, no callsign extracted from OCR. Text=\"\(det.text)\"")
                        lastClickedRowSignature = signature
                    }
                }
            }

            // Inactivity → CQ. Two anchors must both be expired:
            //  • inactivityAnchorAt: time since the last "real" activity
            //    (PTT, doubleclick, CQ trigger, session reset).
            //  • lastSearchHitAt: time since the row search last succeeded.
            //    Prevents CQ+Answer from firing while decodable callsign
            //    rows are still showing in the receive window.
            if let last = inactivityAnchorAt {
                let elapsed = Date().timeIntervalSince(last)
                if elapsed >= Double(settings.inactivityTimeoutSec) {
                    let searchElapsed = lastSearchHitAt.map { Date().timeIntervalSince($0) } ?? Double.greatestFiniteMagnitude
                    if searchElapsed >= Double(settings.searchInactivitySec) {
                        logger.log(.info, "Inactivity \(Int(elapsed))s ≥ \(settings.inactivityTimeoutSec)s, search idle \(Int(searchElapsed))s ≥ \(settings.searchInactivitySec)s — CQ + Answer.")
                        await clickCQAndAnswer(reason: "Inactivity")
                    }
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }
    }
}

// MARK: - Callsign → Country

/// Best-effort DXCC prefix resolution. Covers the entities common in FT8
/// traffic; anything unknown returns nil and the header shows just the callsign.
enum Callsign {
    static func country(for raw: String) -> String? {
        let upper = raw.uppercased().trimmingCharacters(in: .whitespaces)
        guard !upper.isEmpty else { return nil }
        // Longer prefixes win (e.g. "EA8" over "EA", "UA9" over "UA").
        for length in stride(from: min(upper.count, 4), through: 1, by: -1) {
            let prefix = String(upper.prefix(length))
            if let name = prefixMap[prefix] { return name }
        }
        return nil
    }

    private static let prefixMap: [String: String] = {
        var m: [String: String] = [:]
        // Germany (all DA–DR)
        for c in ["DA","DB","DC","DD","DE","DF","DG","DH","DI","DJ","DK","DL","DM","DN","DO","DP","DQ","DR"] { m[c] = "Germany" }
        // UK & Crown Dependencies (M, G…) — coarse resolution
        for c in ["G","M","2E"] { m[c] = "England" }
        m["GM"] = "Scotland";    m["MM"] = "Scotland"
        m["GW"] = "Wales";        m["MW"] = "Wales"
        m["GI"] = "N. Ireland";   m["MI"] = "N. Ireland"
        m["GD"] = "Isle of Man";  m["MD"] = "Isle of Man"
        m["GJ"] = "Jersey";       m["MJ"] = "Jersey"
        m["GU"] = "Guernsey";     m["MU"] = "Guernsey"
        // Western/Southern Europe
        m["F"] = "France"
        m["TK"] = "Corsica"
        m["I"] = "Italy"; m["IS0"] = "Sardinia"
        m["EA"] = "Spain"; m["EA6"] = "Balearic Is."; m["EA8"] = "Canary Is."; m["EA9"] = "Ceuta & Melilla"
        m["CT"] = "Portugal"; m["CT3"] = "Madeira"; m["CU"] = "Azores"
        m["ON"] = "Belgium"; m["OO"] = "Belgium"; m["OP"] = "Belgium"; m["OQ"] = "Belgium"; m["OR"] = "Belgium"; m["OS"] = "Belgium"; m["OT"] = "Belgium"
        m["PA"] = "Netherlands"; m["PB"] = "Netherlands"; m["PD"] = "Netherlands"; m["PE"] = "Netherlands"; m["PF"] = "Netherlands"; m["PG"] = "Netherlands"; m["PH"] = "Netherlands"; m["PI"] = "Netherlands"
        m["LX"] = "Luxembourg"
        m["HB"] = "Switzerland"; m["HB0"] = "Liechtenstein"; m["HB9"] = "Switzerland"
        m["OE"] = "Austria"
        m["3A"] = "Monaco"; m["T7"] = "San Marino"; m["9H"] = "Malta"; m["1A"] = "Sov. Mil. Order Malta"
        // Northern Europe
        m["OH"] = "Finland"; m["OH0"] = "Aland Is."; m["OJ0"] = "Market Reef"
        m["SM"] = "Sweden"; m["SA"] = "Sweden"; m["SB"] = "Sweden"; m["SC"] = "Sweden"; m["SD"] = "Sweden"; m["SE"] = "Sweden"; m["SF"] = "Sweden"; m["SG"] = "Sweden"; m["SH"] = "Sweden"; m["SI"] = "Sweden"; m["SJ"] = "Sweden"; m["SK"] = "Sweden"
        m["LA"] = "Norway"; m["LB"] = "Norway"; m["LC"] = "Norway"; m["LD"] = "Norway"; m["LE"] = "Norway"; m["LF"] = "Norway"; m["LG"] = "Norway"; m["LH"] = "Norway"; m["LI"] = "Norway"; m["LJ"] = "Norway"; m["LK"] = "Norway"; m["LL"] = "Norway"; m["LM"] = "Norway"; m["LN"] = "Norway"
        m["JX"] = "Jan Mayen"; m["JW"] = "Svalbard"
        m["OZ"] = "Denmark"; m["OU"] = "Denmark"; m["OV"] = "Denmark"; m["OW"] = "Denmark"; m["OX"] = "Greenland"; m["OY"] = "Faroe Is."
        m["TF"] = "Iceland"
        // Central/Eastern Europe
        m["OK"] = "Czech Rep."; m["OL"] = "Czech Rep."
        m["OM"] = "Slovakia"
        m["HA"] = "Hungary"; m["HG"] = "Hungary"
        m["SP"] = "Poland"; m["SQ"] = "Poland"; m["SO"] = "Poland"; m["SN"] = "Poland"; m["3Z"] = "Poland"; m["HF"] = "Poland"
        m["YL"] = "Latvia"; m["LY"] = "Lithuania"; m["ES"] = "Estonia"
        m["9A"] = "Croatia"; m["S5"] = "Slovenia"; m["E7"] = "Bosnia-Herz."; m["YU"] = "Serbia"; m["YT"] = "Serbia"
        m["Z3"] = "N. Macedonia"; m["ZA"] = "Albania"; m["LZ"] = "Bulgaria"; m["YO"] = "Romania"; m["YP"] = "Romania"; m["YQ"] = "Romania"; m["YR"] = "Romania"
        m["SV"] = "Greece"; m["SY"] = "Greece"; m["SZ"] = "Greece"; m["SW"] = "Greece"; m["J4"] = "Greece"
        m["TA"] = "Turkey"; m["YM"] = "Turkey"; m["TC"] = "Turkey"
        m["5B"] = "Cyprus"; m["P3"] = "Cyprus"; m["H2"] = "Cyprus"
        m["ER"] = "Moldova"
        m["UR"] = "Ukraine"; m["UT"] = "Ukraine"; m["UU"] = "Ukraine"; m["UV"] = "Ukraine"; m["UW"] = "Ukraine"; m["UX"] = "Ukraine"; m["UY"] = "Ukraine"; m["UZ"] = "Ukraine"; m["EM"] = "Ukraine"; m["EN"] = "Ukraine"; m["EO"] = "Ukraine"
        m["EW"] = "Belarus"; m["EU"] = "Belarus"; m["EV"] = "Belarus"
        // Russia (UA1–UA9 coarse; single-letter R prefixes as Russia)
        m["R"] = "Russia"; m["RA"] = "Russia"; m["RC"] = "Russia"; m["RD"] = "Russia"; m["RE"] = "Russia"; m["RF"] = "Russia"; m["RG"] = "Russia"; m["RJ"] = "Russia"; m["RK"] = "Russia"; m["RL"] = "Russia"; m["RM"] = "Russia"; m["RN"] = "Russia"; m["RO"] = "Russia"; m["RP"] = "Russia"; m["RQ"] = "Russia"; m["RT"] = "Russia"; m["RU"] = "Russia"; m["RV"] = "Russia"; m["RW"] = "Russia"; m["RX"] = "Russia"; m["RY"] = "Russia"; m["RZ"] = "Russia"; m["UA"] = "Russia"; m["UB"] = "Russia"; m["UC"] = "Russia"; m["UD"] = "Russia"; m["UE"] = "Russia"; m["UF"] = "Russia"; m["UG"] = "Russia"; m["UH"] = "Russia"; m["UI"] = "Russia"
        m["RA9"] = "Russia (Asian)"; m["UA9"] = "Russia (Asian)"; m["RA8"] = "Russia (Asian)"; m["UA8"] = "Russia (Asian)"; m["RA0"] = "Russia (Asian)"; m["UA0"] = "Russia (Asian)"
        m["4L"] = "Georgia"; m["EK"] = "Armenia"; m["4K"] = "Azerbaijan"
        // Middle East
        m["4X"] = "Israel"; m["4Z"] = "Israel"
        m["9K"] = "Kuwait"; m["A6"] = "UAE"; m["A7"] = "Qatar"; m["A4"] = "Oman"; m["A9"] = "Bahrain"; m["HZ"] = "Saudi Arabia"; m["7Z"] = "Saudi Arabia"; m["YI"] = "Iraq"; m["EP"] = "Iran"; m["EQ"] = "Iran"; m["YK"] = "Syria"; m["JY"] = "Jordan"; m["OD"] = "Lebanon"
        // Africa (selection)
        m["SU"] = "Egypt"; m["3V"] = "Tunisia"; m["7X"] = "Algeria"; m["CN"] = "Morocco"; m["5A"] = "Libya"
        m["ZS"] = "South Africa"; m["ZR"] = "South Africa"; m["V5"] = "Namibia"; m["A2"] = "Botswana"; m["3DA"] = "Eswatini"; m["7P"] = "Lesotho"
        m["5R"] = "Madagascar"; m["3B8"] = "Mauritius"; m["3B9"] = "Rodrigues"; m["5T"] = "Mauritania"; m["5N"] = "Nigeria"; m["9G"] = "Ghana"; m["6W"] = "Senegal"; m["TZ"] = "Mali"; m["TJ"] = "Cameroon"; m["TR"] = "Gabon"; m["5H"] = "Tanzania"; m["5X"] = "Uganda"; m["5Z"] = "Kenya"; m["9J"] = "Zambia"; m["Z2"] = "Zimbabwe"
        // North America
        for c in ["W","K","N","AA","AB","AC","AD","AE","AF","AG","AH","AI","AJ","AK","AL","KA","KB","KC","KD","KE","KF","KG","KH","KI","KJ","KK","KL","KM","KN","KO","KP","KQ","KR","KS","KT","KU","KV","KW","KX","KY","KZ","NA","NB","NC","ND","NE","NF","NG","NH","NI","NJ","NK","NL","NM","NN","NO","NP","NQ","NR","NS","NT","NU","NV","NW","NX","NY","NZ","WA","WB","WC","WD","WE","WF","WG","WH","WI","WJ","WK","WL","WM","WN","WO","WP","WQ","WR","WS","WT","WU","WV","WW","WX","WY","WZ"] { m[c] = "USA" }
        m["KH6"] = "Hawaii"; m["KL7"] = "Alaska"; m["KP4"] = "Puerto Rico"; m["KP2"] = "US Virgin Is."; m["KG4"] = "Guantanamo"
        m["VE"] = "Canada"; m["VA"] = "Canada"; m["VO"] = "Canada"; m["VY"] = "Canada"; m["CY"] = "Canada"
        m["XE"] = "Mexico"; m["XF"] = "Mexico"; m["4A"] = "Mexico"; m["4B"] = "Mexico"; m["4C"] = "Mexico"; m["6D"] = "Mexico"; m["6E"] = "Mexico"; m["6F"] = "Mexico"; m["6G"] = "Mexico"; m["6H"] = "Mexico"; m["6I"] = "Mexico"; m["6J"] = "Mexico"
        m["CO"] = "Cuba"; m["CM"] = "Cuba"; m["CL"] = "Cuba"; m["T4"] = "Cuba"
        m["HI"] = "Dominican Rep."; m["HK"] = "Colombia"; m["HJ"] = "Colombia"; m["YV"] = "Venezuela"; m["YY"] = "Venezuela"; m["8R"] = "Guyana"; m["FY"] = "French Guiana"; m["PJ"] = "Caribbean NL"
        m["PY"] = "Brazil"; m["PT"] = "Brazil"; m["PP"] = "Brazil"; m["PR"] = "Brazil"; m["PS"] = "Brazil"; m["PU"] = "Brazil"; m["PV"] = "Brazil"; m["PW"] = "Brazil"; m["PX"] = "Brazil"; m["ZV"] = "Brazil"; m["ZW"] = "Brazil"; m["ZX"] = "Brazil"; m["ZY"] = "Brazil"; m["ZZ"] = "Brazil"
        m["LU"] = "Argentina"; m["AY"] = "Argentina"; m["AZ"] = "Argentina"; m["L2"] = "Argentina"; m["L3"] = "Argentina"; m["L4"] = "Argentina"; m["L5"] = "Argentina"; m["L6"] = "Argentina"; m["L7"] = "Argentina"; m["L8"] = "Argentina"; m["L9"] = "Argentina"
        m["CE"] = "Chile"; m["CA"] = "Chile"; m["CB"] = "Chile"; m["CC"] = "Chile"; m["CD"] = "Chile"; m["3G"] = "Chile"; m["XQ"] = "Chile"; m["XR"] = "Chile"; m["CE0"] = "Easter Island"
        m["CX"] = "Uruguay"; m["ZP"] = "Paraguay"; m["CP"] = "Bolivia"; m["OA"] = "Peru"; m["HC"] = "Ecuador"
        // Asia-Pacific
        m["JA"] = "Japan"; m["JE"] = "Japan"; m["JF"] = "Japan"; m["JG"] = "Japan"; m["JH"] = "Japan"; m["JI"] = "Japan"; m["JJ"] = "Japan"; m["JK"] = "Japan"; m["JL"] = "Japan"; m["JM"] = "Japan"; m["JN"] = "Japan"; m["JO"] = "Japan"; m["JP"] = "Japan"; m["JQ"] = "Japan"; m["JR"] = "Japan"; m["JS"] = "Japan"; m["7J"] = "Japan"; m["7K"] = "Japan"; m["7L"] = "Japan"; m["7M"] = "Japan"; m["7N"] = "Japan"; m["8J"] = "Japan"; m["8N"] = "Japan"
        m["BY"] = "China"; m["BG"] = "China"; m["BD"] = "China"; m["BH"] = "China"; m["BA"] = "China"; m["B"] = "China"
        m["BV"] = "Taiwan"; m["BU"] = "Taiwan"; m["BX"] = "Taiwan"
        m["VR"] = "Hong Kong"; m["XX9"] = "Macao"
        m["HL"] = "South Korea"; m["DS"] = "South Korea"; m["6K"] = "South Korea"; m["6L"] = "South Korea"; m["6M"] = "South Korea"; m["6N"] = "South Korea"; m["DT"] = "South Korea"
        m["P5"] = "North Korea"
        m["VU"] = "India"; m["AT"] = "India"; m["8T"] = "India"; m["8U"] = "India"; m["8V"] = "India"; m["8W"] = "India"; m["8Y"] = "India"
        m["4S"] = "Sri Lanka"; m["AP"] = "Pakistan"; m["S2"] = "Bangladesh"; m["A5"] = "Bhutan"; m["9N"] = "Nepal"
        m["HS"] = "Thailand"; m["E2"] = "Thailand"; m["XU"] = "Cambodia"; m["XW"] = "Laos"; m["XV"] = "Vietnam"; m["3W"] = "Vietnam"; m["9V"] = "Singapore"; m["9M"] = "Malaysia"; m["9W"] = "Malaysia"; m["DU"] = "Philippines"; m["DV"] = "Philippines"; m["DW"] = "Philippines"; m["DX"] = "Philippines"; m["DY"] = "Philippines"; m["DZ"] = "Philippines"; m["YB"] = "Indonesia"; m["YC"] = "Indonesia"; m["YD"] = "Indonesia"; m["YE"] = "Indonesia"; m["YF"] = "Indonesia"; m["YG"] = "Indonesia"; m["YH"] = "Indonesia"
        // Oceania
        m["VK"] = "Australia"; m["AX"] = "Australia"; m["VK9"] = "Australia (outer)"; m["VK0"] = "Antarctica/Heard"
        m["ZL"] = "New Zealand"; m["ZK"] = "Cook Is."; m["ZM"] = "New Zealand"
        m["KH8"] = "Amer. Samoa"; m["5W"] = "Samoa"; m["A3"] = "Tonga"; m["3D2"] = "Fiji"; m["FK"] = "New Caledonia"; m["FO"] = "Fr. Polynesia"
        return m
    }()
}
