import Foundation
import CoreGraphics
import Vision
import AppKit
import ScreenCaptureKit

/// Result of one analysis pass.
struct DetectedRow {
    /// Center point in screen coordinates of the detected row (CG, top-left origin).
    let screenPoint: CGPoint
    /// Recognized text from OCR (raw).
    let text: String
    /// Extracted callsign candidate, if any.
    let callsign: String?
}

enum MonitorError: Error {
    case noScreenshot
    case invalidRegion
}

/// Captures a region of the screen and looks for the bottom-most "highlighted"
/// row (predominantly green background with bright text) — the visual signature
/// of a freshly received message in iDigi.
struct ScreenMonitor {

    /// True when the process currently holds the Screen Recording TCC permission.
    /// Cheap (no IPC) — safe to call before every capture.
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system's one-time Screen Recording prompt if needed.
    /// Subsequent calls are no-ops once the user has granted access.
    /// On macOS 13 the request alone often isn't enough to make the app appear
    /// in the Privacy list — an actual capture attempt is what registers it
    /// with tccd. We therefore also issue a 1×1 throwaway capture.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        let granted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        // Tiny capture to force tccd registration even when no app settings
        // are configured yet (otherwise no SCK/CG capture ever fires).
        _ = CGWindowListCreateImage(CGRect(x: 0, y: 0, width: 1, height: 1),
                                    .optionOnScreenOnly,
                                    kCGNullWindowID,
                                    [])
        return granted
    }

    static func capture(region: CGRect) async -> CGImage? {
        guard region.width > 1, region.height > 1 else { return nil }
        // Gate every call on the TCC preflight. If permission is missing we
        // skip SCK entirely — never call SCShareableContent / captureImage
        // unauthenticated, otherwise macOS shows the prompt again and again.
        guard CGPreflightScreenCaptureAccess() else { return nil }
        if #available(macOS 14.0, *) {
            return await captureViaSCK(region: region)
        }
        // macOS 13 fallback: CGWindowListCreateImage still works (deprecated in macOS 15+).
        return CGWindowListCreateImage(region, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
    }

    @available(macOS 14.0, *)
    private static func captureViaSCK(region: CGRect) async -> CGImage? {
        guard let filter = await CaptureCache.shared.filter() else { return nil }
        do {
            let config = SCStreamConfiguration()
            config.sourceRect = region
            config.width  = max(1, Int(region.width))
            config.height = max(1, Int(region.height))
            config.scalesToFit = false
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            // Display config may have changed (e.g. monitor connected/disconnected).
            // Drop the cache so the next call rebuilds the filter once.
            await CaptureCache.shared.invalidate()
            return nil
        }
    }

    /// Find the bottom-most green-highlighted row inside `image`.
    /// Returns the y-range (in image pixels) of that row, or nil if none.
    static func findBottomHighlightedRow(in image: CGImage, settings: ClickerSettings) -> ClosedRange<Int>? {
        guard let pixels = PixelBuffer(image: image) else { return nil }
        let h = pixels.height
        let w = pixels.width

        var rowIsActive = [Bool](repeating: false, count: h)
        let step = max(1, w / 200)          // sample at most ~200 pixels per row for speed
        let samplesPerRow = w / step
        let greenThreshold = Int(Double(samplesPerRow) * settings.greenRowMinFraction)
        let whiteThreshold = max(1, Int(Double(samplesPerRow) * settings.whiteRowMinFraction))
        let wMin = settings.whiteMinChannel

        for y in 0..<h {
            var greenCount = 0
            var whiteCount = 0
            var x = 0
            while x < w {
                let (r, g, b) = pixels.rgb(x: x, y: y)
                if r >= settings.greenMinR, r <= settings.greenMaxR,
                   g >= settings.greenMinG, g <= settings.greenMaxG,
                   b >= settings.greenMinB, b <= settings.greenMaxB {
                    greenCount += 1
                }
                if r >= wMin, g >= wMin, b >= wMin {
                    whiteCount += 1
                }
                x += step
            }
            // Active CQ row needs BOTH a green background AND white text.
            // This is what distinguishes it from inactive grey-on-green rows.
            rowIsActive[y] = greenCount >= greenThreshold && whiteCount >= whiteThreshold
        }

        // Walk from bottom up; first contiguous block of "active" rows is our row.
        var endY: Int? = nil
        var y = h - 1
        while y >= 0 {
            if rowIsActive[y] { endY = y; break }
            y -= 1
        }
        guard let end = endY else { return nil }

        var startY = end
        while startY > 0, rowIsActive[startY - 1] {
            startY -= 1
        }
        // Require a minimum row thickness (1 pt to avoid single stray pixels).
        guard end - startY >= 4 else { return nil }
        return startY...end
    }

    /// OCR the target row. We pad the crop vertically so Vision has enough
    /// context — a single 16-px slice produces unreliable results — then keep
    /// only those text observations whose vertical center lies within the
    /// original target row.
    static func recognizeRowText(in image: CGImage, yRange: ClosedRange<Int>) -> String {
        let imgW = image.width
        let imgH = image.height
        let rowH = max(1, yRange.count)
        // Pad by a few row-heights so Vision sees neighboring lines and can
        // segment baselines reliably. Keep the original row near the middle.
        let pad = max(20, rowH * 3)
        let yLo = max(0, yRange.lowerBound - pad)
        let yHi = min(imgH - 1, yRange.upperBound + pad)
        let cropRect = CGRect(x: 0, y: yLo, width: imgW, height: yHi - yLo + 1)
        let safe = cropRect.integral.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard safe.width > 1, safe.height > 1,
              let cropped = image.cropping(to: safe) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let observations = request.results ?? []

        // Vision boundingBoxes are normalized (0..1) with origin BOTTOM-LEFT.
        // Convert to top-left pixel y inside the crop, then keep only
        // observations whose vertical center overlaps the target row.
        let cropH = Double(cropped.height)
        let targetLo = Double(yRange.lowerBound - Int(safe.minY))
        let targetHi = Double(yRange.upperBound - Int(safe.minY))
        let tolerance = Double(rowH) / 2.0 + 2.0

        let pieces: [String] = observations.compactMap { obs in
            let box = obs.boundingBox
            let yTop = (1.0 - (box.origin.y + box.size.height)) * cropH
            let yBot = (1.0 - box.origin.y) * cropH
            let center = (yTop + yBot) / 2.0
            guard center >= targetLo - tolerance, center <= targetHi + tolerance else { return nil }
            return obs.topCandidates(1).first?.string
        }
        return pieces.joined(separator: " ")
    }

    /// Loose ham radio callsign extractor.
    /// Bevorzugt: ein `CQ`-Token als Anker — das erste callsign-förmige Token DANACH
    /// ist das gesuchte Rufzeichen (typischer iDigi-CQ-Aufbau: "CQ [DX|EU|NA|...] <CALL> [GRID]").
    /// Fallback: erstes callsign-förmiges Token in der gesamten Zeile.
    /// `\bCQ\b` ist gegenüber häufigen OCR-Verwechslungen (`CO`, `C0`) tolerant.
    static func extractCallsign(from text: String) -> String? {
        let upper = text.uppercased()
        let cqPattern = #"\bC[QO0]\b"#
        if let cqRegex = try? NSRegularExpression(pattern: cqPattern, options: []),
           let cqMatch = cqRegex.firstMatch(in: upper, options: [], range: NSRange(upper.startIndex..<upper.endIndex, in: upper)),
           let cqRange = Range(cqMatch.range, in: upper) {
            let after = String(upper[cqRange.upperBound...])
            if let call = firstCallsignToken(in: after) { return call }
        }
        return firstCallsignToken(in: upper)
    }

    /// First substring matching the loose callsign shape: 1-3 alphanumerics, a digit, then 1-3 letters.
    /// Examples that match: W1AW, DK7XL, JA1ABC, 2E0AAA. "CQ", "DX", "EU" do not match (no digit).
    private static func firstCallsignToken(in text: String) -> String? {
        let pattern = #"\b([A-Z0-9]{1,3}[0-9][A-Z]{1,3})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
           let r = Range(match.range(at: 1), in: text) {
            return String(text[r])
        }
        return nil
    }

    /// Main analysis entry point. Captures the configured region and tries to
    /// detect the bottom-most highlighted message row. Returns nil if nothing
    /// detected. The screen point returned is the row's vertical center.
    static func analyze(settings: ClickerSettings) async -> DetectedRow? {
        let region = CGRect(origin: settings.windowOrigin, size: settings.windowSize)
        guard let image = await capture(region: region) else { return nil }
        let snapshot = settings
        return await Task.detached(priority: .userInitiated) {
            analyzeImage(image, region: region, settings: snapshot)
        }.value
    }

    /// Probes a small square around a button's click point and returns true
    /// when the area is dominated by the macOS "active blue" tint — i.e. the
    /// button is currently in its active/highlighted state.
    /// Returns nil if the screen could not be captured (treat as unknown).
    /// Captures a small probe rect around `point` and returns the mean RGB of all sampled pixels.
    static func sampleMeanRGB(at point: CGPoint, settings: ClickerSettings) async -> RGB? {
        let pw = max(4, settings.buttonProbeWidth)
        let ph = max(4, settings.buttonProbeHeight)
        let region = CGRect(
            x: point.x - CGFloat(pw) / 2,
            y: point.y - CGFloat(ph) / 2,
            width: CGFloat(pw),
            height: CGFloat(ph)
        )
        guard let image = await capture(region: region) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let pixels = PixelBuffer(image: image) else { return nil }
            var rs = 0, gs = 0, bs = 0, n = 0
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    let (r, g, b) = pixels.rgb(x: x, y: y)
                    rs += r; gs += g; bs += b; n += 1
                }
            }
            guard n > 0 else { return nil }
            return RGB(r: rs / n, g: gs / n, b: bs / n)
        }.value
    }

    /// Decides whether a button is currently active.
    /// - If both `activeRef` and `inactiveRef` are provided: returns the closer one.
    /// - If only one ref: thresholds against `colorMatchTolerance`.
    /// - If neither ref: falls back to the configured RGB range check.
    /// Returns nil only when the screen could not be captured.
    static func isButtonActive(at point: CGPoint,
                               activeRef: RGB?,
                               inactiveRef: RGB?,
                               settings: ClickerSettings) async -> Bool? {
        guard let mean = await sampleMeanRGB(at: point, settings: settings) else { return nil }
        if let a = activeRef, let i = inactiveRef {
            return colorDistance(mean, a) < colorDistance(mean, i)
        }
        if let a = activeRef {
            return colorDistance(mean, a) <= settings.colorMatchTolerance
        }
        if let i = inactiveRef {
            return colorDistance(mean, i) > settings.colorMatchTolerance
        }
        // No learned reference colors — we cannot decide. The auto-learn flow
        // populates both refs after Position-Lernen, so this is a transient state.
        return nil
    }

    /// Returns true when the probe area around `point` is red-dominant —
    /// i.e. iDigi's PTT button is currently lit / transmitting.
    /// Heuristic (no learned reference): red channel must dominate G and B
    /// AND be reasonably bright. Returns nil if capture failed.
    static func isPTTRed(at point: CGPoint, settings: ClickerSettings) async -> Bool? {
        guard let mean = await sampleMeanRGB(at: point, settings: settings) else { return nil }
        let dominance = mean.r - max(mean.g, mean.b)
        return mean.r > 120 && dominance > 50
    }

    static func colorDistance(_ a: RGB, _ b: RGB) -> Double {
        let dr = Double(a.r - b.r)
        let dg = Double(a.g - b.g)
        let db = Double(a.b - b.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private static func analyzeImage(_ image: CGImage, region: CGRect, settings: ClickerSettings) -> DetectedRow? {
        guard let yRange = findBottomHighlightedRow(in: image, settings: settings) else { return nil }

        // Image pixel coords → screen coords. The capture returns an image whose
        // origin matches the requested rect's top-left in display points.
        let imgH = image.height
        let scaleY = Double(imgH) / Double(region.height)
        let pixelMidY = Double(yRange.lowerBound + yRange.upperBound) / 2.0
        let screenY = region.minY + pixelMidY / scaleY
        let screenX = region.minX + region.width / 2.0

        let text = recognizeRowText(in: image, yRange: yRange)
        let call = extractCallsign(from: text)

        return DetectedRow(screenPoint: CGPoint(x: screenX, y: screenY), text: text, callsign: call)
    }
}

/// Caches the SCContentFilter for the main display so we hit TCC / SCK only
/// the first time. SCShareableContent.excludingDesktopWindows is the call that
/// interacts with the Screen Recording permission machinery — calling it on
/// every capture is what causes the "asks for permission again and again"
/// behaviour, even when the user has granted access.
private actor CaptureCache {
    static let shared = CaptureCache()

    private var cachedFilter: SCContentFilter?

    func filter() async -> SCContentFilter? {
        if let f = cachedFilter { return f }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let myBundle = Bundle.main.bundleIdentifier
            let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == myBundle }
            let f = SCContentFilter(display: display, excludingWindows: ownWindows)
            cachedFilter = f
            return f
        } catch {
            return nil
        }
    }

    func invalidate() {
        cachedFilter = nil
    }
}

/// Lightweight RGB pixel reader backed by a freshly drawn 8-bit RGBA bitmap.
private struct PixelBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: [UInt8]

    init?(image: CGImage) {
        let w = image.width
        let h = image.height
        let bytesPerPixel = 4
        let bpr = w * bytesPerPixel
        var buf = [UInt8](repeating: 0, count: bpr * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = buf.withUnsafeMutableBytes({ ptr -> CGContext? in
            guard let base = ptr.baseAddress else { return nil }
            return CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                             bytesPerRow: bpr, space: cs, bitmapInfo: info)
        }) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.width = w
        self.height = h
        self.bytesPerRow = bpr
        self.data = buf
    }

    @inline(__always)
    func rgb(x: Int, y: Int) -> (Int, Int, Int) {
        let i = y * bytesPerRow + x * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
}
