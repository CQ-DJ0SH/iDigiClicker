import Foundation
import CoreGraphics

struct RGB: Codable, Equatable, Hashable {
    var r: Int
    var g: Int
    var b: Int
    var displayString: String { "(\(r),\(g),\(b))" }
}

struct ClickerSettings: Codable, Equatable {
    var cqButton: CGPoint = .zero
    var answerButton: CGPoint = .zero
    var pttButton: CGPoint = .zero
    var windowOrigin: CGPoint = .zero
    var windowSize: CGSize = .zero

    var pollIntervalMs: Int = 500
    var inactivityTimeoutSec: Int = 30
    var doubleClickDelayMs: Int = 80
    var cqToAnswerDelayMs: Int = 600
    var learnActiveDelayMs: Int = 350
    // Cooldown nach PTT-Wechsel: erst diese Anzahl Sekunden nach der letzten
    // PTT-Änderung wird ein neues Rufzeichen wieder angeklickt.
    var pttCooldownSec: Int = 30
    // Override: wenn der letzte Doppelklick auf ein Rufzeichen länger als
    // dieser Wert (in Sek.) zurückliegt, ignorieren wir den PTT-Cooldown
    // und klicken trotzdem — verhindert ein Festfahren bei Dauer-Streit.
    var clickStalenessOverrideSec: Int = 300
    // Additional gate before CQ+Answer fires: the row search must have been
    // unsuccessful (no callsign-bearing green row found) for at least this
    // many seconds. Counted from the last successful detection of a row with
    // an extractable callsign, regardless of whether we actually clicked it.
    var searchInactivitySec: Int = 10

    // Detection thresholds for the active-CQ row.
    // Active CQs in iDigi: WHITE text on GREEN background.
    // Inactive green rows have GRAY text — those must be ignored, hence the
    // dual condition (enough green pixels AND enough white pixels per row).
    var greenMinR: Int = 0
    var greenMaxR: Int = 120
    var greenMinG: Int = 110
    var greenMaxG: Int = 255
    var greenMinB: Int = 0
    var greenMaxB: Int = 120
    var greenRowMinFraction: Double = 0.35   // share of pixels per row that must look green

    // White-text thresholds: pixel counts as "white" when all channels are bright.
    var whiteMinChannel: Int = 220
    var whiteRowMinFraction: Double = 0.02   // text is sparse — a couple % is enough

    // Probe rectangle for button color sampling. CQ/Answer in iDigi are small
    // and elongated — the rectangle should fit inside the button so we don't
    // sample surrounding chrome.
    var buttonProbeWidth: Int = 12
    var buttonProbeHeight: Int = 8

    // Learned reference colors (auto-filled by the position-learn flow).
    // The active/inactive decision is "closer to which reference?".
    var cqInactiveColor: RGB? = nil
    var cqActiveColor: RGB? = nil
    var answerInactiveColor: RGB? = nil
    var answerActiveColor: RGB? = nil
    // Used only when exactly one reference is learned — distance threshold.
    var colorMatchTolerance: Double = 50.0

    var isCoordinatesValid: Bool {
        cqButton != .zero && answerButton != .zero && windowSize.width > 10 && windowSize.height > 10
    }

    static let storageKey = "iDigiClicker.settings.v1"

    static func load() -> ClickerSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(ClickerSettings.self, from: data) else {
            return ClickerSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // Tolerant decoder: any field missing from the stored JSON falls back to
    // the struct's default. This lets us add new fields (e.g. pttButton)
    // without invalidating users' saved settings.
    init() {}

    private enum CodingKeys: String, CodingKey {
        case cqButton, answerButton, pttButton, windowOrigin, windowSize
        case pollIntervalMs, inactivityTimeoutSec, doubleClickDelayMs, cqToAnswerDelayMs, learnActiveDelayMs, pttCooldownSec, clickStalenessOverrideSec, searchInactivitySec
        case greenMinR, greenMaxR, greenMinG, greenMaxG, greenMinB, greenMaxB, greenRowMinFraction
        case whiteMinChannel, whiteRowMinFraction
        case buttonProbeWidth, buttonProbeHeight
        case cqInactiveColor, cqActiveColor, answerInactiveColor, answerActiveColor
        case colorMatchTolerance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = ClickerSettings()
        s.cqButton             = try c.decodeIfPresent(CGPoint.self, forKey: .cqButton)            ?? s.cqButton
        s.answerButton         = try c.decodeIfPresent(CGPoint.self, forKey: .answerButton)        ?? s.answerButton
        s.pttButton            = try c.decodeIfPresent(CGPoint.self, forKey: .pttButton)           ?? s.pttButton
        s.windowOrigin         = try c.decodeIfPresent(CGPoint.self, forKey: .windowOrigin)        ?? s.windowOrigin
        s.windowSize           = try c.decodeIfPresent(CGSize.self,  forKey: .windowSize)          ?? s.windowSize
        s.pollIntervalMs       = try c.decodeIfPresent(Int.self,     forKey: .pollIntervalMs)      ?? s.pollIntervalMs
        s.inactivityTimeoutSec = try c.decodeIfPresent(Int.self,     forKey: .inactivityTimeoutSec) ?? s.inactivityTimeoutSec
        s.doubleClickDelayMs   = try c.decodeIfPresent(Int.self,     forKey: .doubleClickDelayMs)  ?? s.doubleClickDelayMs
        s.cqToAnswerDelayMs    = try c.decodeIfPresent(Int.self,     forKey: .cqToAnswerDelayMs)   ?? s.cqToAnswerDelayMs
        s.learnActiveDelayMs   = try c.decodeIfPresent(Int.self,     forKey: .learnActiveDelayMs)  ?? s.learnActiveDelayMs
        s.pttCooldownSec       = try c.decodeIfPresent(Int.self,     forKey: .pttCooldownSec)      ?? s.pttCooldownSec
        s.clickStalenessOverrideSec = try c.decodeIfPresent(Int.self, forKey: .clickStalenessOverrideSec) ?? s.clickStalenessOverrideSec
        s.searchInactivitySec  = try c.decodeIfPresent(Int.self,     forKey: .searchInactivitySec)  ?? s.searchInactivitySec
        s.greenMinR            = try c.decodeIfPresent(Int.self,     forKey: .greenMinR)           ?? s.greenMinR
        s.greenMaxR            = try c.decodeIfPresent(Int.self,     forKey: .greenMaxR)           ?? s.greenMaxR
        s.greenMinG            = try c.decodeIfPresent(Int.self,     forKey: .greenMinG)           ?? s.greenMinG
        s.greenMaxG            = try c.decodeIfPresent(Int.self,     forKey: .greenMaxG)           ?? s.greenMaxG
        s.greenMinB            = try c.decodeIfPresent(Int.self,     forKey: .greenMinB)           ?? s.greenMinB
        s.greenMaxB            = try c.decodeIfPresent(Int.self,     forKey: .greenMaxB)           ?? s.greenMaxB
        s.greenRowMinFraction  = try c.decodeIfPresent(Double.self,  forKey: .greenRowMinFraction) ?? s.greenRowMinFraction
        s.whiteMinChannel      = try c.decodeIfPresent(Int.self,     forKey: .whiteMinChannel)     ?? s.whiteMinChannel
        s.whiteRowMinFraction  = try c.decodeIfPresent(Double.self,  forKey: .whiteRowMinFraction) ?? s.whiteRowMinFraction
        s.buttonProbeWidth     = try c.decodeIfPresent(Int.self,     forKey: .buttonProbeWidth)    ?? s.buttonProbeWidth
        s.buttonProbeHeight    = try c.decodeIfPresent(Int.self,     forKey: .buttonProbeHeight)   ?? s.buttonProbeHeight
        s.cqInactiveColor      = try c.decodeIfPresent(RGB.self,     forKey: .cqInactiveColor)
        s.cqActiveColor        = try c.decodeIfPresent(RGB.self,     forKey: .cqActiveColor)
        s.answerInactiveColor  = try c.decodeIfPresent(RGB.self,     forKey: .answerInactiveColor)
        s.answerActiveColor    = try c.decodeIfPresent(RGB.self,     forKey: .answerActiveColor)
        s.colorMatchTolerance  = try c.decodeIfPresent(Double.self,  forKey: .colorMatchTolerance) ?? s.colorMatchTolerance
        self = s
    }
}
