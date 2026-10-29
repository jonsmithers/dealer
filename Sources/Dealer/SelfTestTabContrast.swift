import AppKit

// MARK: - Self-test section: tab contrast (#87, Theme.chromeColor, TabButton.draw)
//
// `[colors] chrome_contrast` is a signed dial (−1…+1, default +0.3): 0 is the terminal background,
// + deepens the chrome away from the foreground, − raises it toward the foreground. Across dark,
// near-black and light themes the strip moves steadily one way as the dial turns (it never flips
// by itself, as the old WCAG-target solve did past 1.38:1 in Kanso Mist), a hovered tab
// (`Theme.hover`) sits between the strip and the active tab (`Theme.surface`), and at the default
// dark themes' strips stand ≥ 1.08:1 off the active tab (light themes and black/near-black are
// nearly flat there: only their direction is checked), with attention outlines ≥ 3:1 on every
// theme's strip. Checked on the formulas
// and on pixels of real tab buttons, in both tab styles. On a translucent window the active
// connected tab follows `TabStyle.translucent`.
// Self-contained (`DEALER_SELFTEST_ONLY=tab contrast:`); restores the settings and launch config.

extension TerminalWindowController {
    func tabContrastSelfTestSteps(_ t: SelfTestKit) {
        func hex(_ c: NSColor?) -> String {
            guard let c = c?.usingColorSpace(.sRGB) else { return "nil" }
            return c.hexString + (c.alphaComponent < 1 ? String(format: "@%.2f", c.alphaComponent) : "")
        }
        func ratio(_ c: CGFloat) -> String { String(format: "%.2f", c) }
        /// (name, background, foreground). Kanso Mist is the user's theme.
        let themes: [(String, String, String)] = [
            ("Kanso Mist", "#22262d", "#c5c9c7"),
            ("Ghostty default dark", "#282c34", "#ffffff"),
            ("Nord", "#2e3440", "#d8dee9"),
            ("Catppuccin Mocha", "#1e1e2e", "#cdd6f4"),
            ("near-black", "#0a0a0a", "#d0d0d0"),
            ("black", "#000000", "#ffffff"),
            ("Catppuccin Latte", "#eff1f5", "#4c4f69"),
            ("Solarized light", "#fdf6e3", "#657b83"),
            ("white", "#ffffff", "#000000"),
        ]
        /// Nearly flat at the default (+0.3, the user's call): light themes, which deepen toward
        /// white, and black/near-black, which can't deepen much. Only the strip's direction is
        /// asserted for them; dark themes get a ratio floor.
        let flatAtDefault: Set<String> = ["Catppuccin Latte", "Solarized light", "white", "near-black", "black"]
        func writeSettings(_ text: String) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
        }
        func inTheme<T>(_ th: (String, String, String), _ body: () -> T) -> T {
            Theme.withBackground(NSColor(hex: th.1)!, foreground: NSColor(hex: th.2)!, body)
        }
        /// Luminance of strip, hover and active tab in every theme, at the current setting.
        func shades() -> [(strip: NSColor, hover: NSColor, active: NSColor)] {
            themes.map { th in inTheme(th) { (Theme.chrome, Theme.hover, Theme.surface) } }
        }

        // Through the setting (not the formula), so the same step runs on older code: across the
        // whole range the strip's luminance falls steadily on dark themes and rises on light ones.
        t.step("tab contrast: turning chrome_contrast across its range moves the strip one way in every theme, never flipping", nil, {
            let r = Settings.chromeContrastRange
            let values = (0...20).map { r.lowerBound + (r.upperBound - r.lowerBound) * Double($0) / 20 }
            var runs: [[(Double, NSColor, NSColor)]] = Array(repeating: [], count: themes.count)
            for v in values {
                writeSettings("[colors]\nchrome_contrast = \(v)\n")
                for (i, s) in shades().enumerated() { runs[i].append((v, s.strip, s.active)) }
            }
            writeSettings("")
            var p: [String] = []
            for (i, run) in runs.enumerated() {
                let name = themes[i].0, dark = run[0].2.luminance < 0.25
                for (a, b) in zip(run, run.dropFirst()) {
                    let (la, lb) = (a.1.luminance, b.1.luminance)
                    if dark ? lb > la + 1e-6 : lb < la - 1e-6 {
                        p.append("\(name): the strip went \(dark ? "lighter" : "darker") from \(hex(a.1)) at \(a.0) to \(hex(b.1)) at \(b.0)")
                        break
                    }
                }
            }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }) {}

        t.step("tab contrast: 0 is the terminal background; hover sits between strip and active tab at every setting", nil, {
            var p: [String] = []
            for v in ["0", "-1", "-0.6", "-0.3", "0.3", "0.5", "1"] {
                writeSettings("[colors]\nchrome_contrast = \(v)\n")
                for (i, s) in shades().enumerated() {
                    let (ls, lh, la) = (s.strip.luminance, s.hover.luminance, s.active.luminance)
                    let at = "\(themes[i].0) @\(v)"
                    if v == "0", !PixelProbe.matches(s.strip, s.active) { p.append("\(at): the strip \(hex(s.strip)) should be the background \(hex(s.active))") }
                    // Equal colors (0, or a black/white theme that can't deepen) count as between.
                    let between = PixelProbe.matches(s.strip, s.active) ? PixelProbe.matches(s.hover, s.active)
                        : min(ls, la) < lh && lh < max(ls, la)
                    if !between { p.append("\(at): hover \(hex(s.hover)) isn't between the strip \(hex(s.strip)) and the active tab \(hex(s.active))") }
                }
            }
            writeSettings("")
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }) {}

        t.step("tab contrast: at the default (+0.3) dark strips stand ≥ 1.08:1 off the active tab, light ones are lighter or equal, and attention outlines keep 3:1", nil, {
            guard Settings.chromeContrast == 0.3 else { return "the default chrome_contrast should be 0.3, is \(Settings.chromeContrast)" }
            var p: [String] = []
            for th in themes {
                inTheme(th) {
                    let strip = Theme.chrome, c = Theme.surface.contrast(with: strip)
                    let blue = Theme.attentionWaiting.contrast(with: strip), red = Theme.attentionFailed.contrast(with: strip)
                    print("      tab contrast @+0.3: \(th.0): strip \(hex(strip)) active \(ratio(c)):1, waiting \(ratio(blue)):1, failed \(ratio(red)):1")
                    if flatAtDefault.contains(th.0) {
                        // Deepening: away from the foreground, never toward it.
                        let (ls, la) = (strip.luminance, Theme.surface.luminance)
                        if Theme.isDark ? ls > la + 1e-6 : ls < la - 1e-6 {
                            p.append("\(th.0): the strip \(hex(strip)) should be \(Theme.isDark ? "darker" : "lighter") than or equal to the terminal")
                        }
                    } else if c < 1.08 {
                        p.append("\(th.0): active vs strip \(hex(strip)) is \(ratio(c)):1, want ≥ 1.08")
                    }
                    if blue < 3 { p.append("\(th.0): the waiting outline is \(ratio(blue)):1 on the strip") }
                    if red < 3 { p.append("\(th.0): the failed outline is \(ratio(red)):1 on the strip") }
                }
            }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }) {
            writeSettings("")
        }
        t.step("tab contrast: an out-of-range chrome_contrast (the old 1.35) is reported with the range and reads as the default", nil, {
            let problem = Settings.problems.first { $0.contains("colors.chrome_contrast") }
            return problem?.contains("-1.0 and 1.0") == true && Settings.chromeContrast == 0.3 ? nil
                : "chrome_contrast = 1.35 should be reported with the range (\(problem ?? "not reported")) and read as 0.3 (\(Settings.chromeContrast))"
        }) {
            writeSettings("[colors]\nchrome_contrast = 1.35\n")
        }
        var before: NSColor?
        t.step("tab contrast: a settings reload re-themes open windows: window background and strip in the new chrome", nil, {
            guard let dv = self.focusedDeck?.view, let w = self.window else { return "no deck" }
            let want = Theme.chrome
            guard let before, !PixelProbe.matches(before, want) else { return "chrome_contrast = 0.6 didn't change the chrome (\(hex(want)))" }
            let s = dv.strip
            let past = s.convert(CGPoint(x: s.addButton.frame.maxX + 12, y: s.bounds.midY), to: self.contentView)
            let px = PixelProbe.sample(self.contentView, at: past)
            return [PixelProbe.matches(w.backgroundColor, want) ? nil : "the window background is \(hex(w.backgroundColor)), want \(hex(want))",
                    PixelProbe.matches(px, want) ? nil : "the strip reads \(hex(px)), want \(hex(want))"].compactMap { $0 }.first
        }) {
            writeSettings("")
            before = Theme.chrome
            writeSettings("[colors]\nchrome_contrast = 0.6\n")
        }
        t.step("tab contrast: back to the default chrome_contrast", nil, {
            Settings.chromeContrast == 0.3 && Settings.problems.isEmpty ? nil : "settings should be back to the defaults"
        }) {
            writeSettings("")
        }

        t.step("tab contrast: real tab buttons fill active, hovered and inactive in that order, connected and pill, at 2x and 1x", nil, {
            var p: [String] = []
            for (name, bg, fg) in themes {
                p += PixelProbe.atEachScale { _ in Theme.withBackground(NSColor(hex: bg)!, foreground: NSColor(hex: fg)!) {
                    var q: [String] = []
                    for style in TabStyle.allCases {
                        // On an opaque window an inactive tab has no fill: it is the strip it sits on.
                        let host = StripFill(frame: CGRect(x: 0, y: 0, width: 360, height: 40))
                        func button(_ x: CGFloat, active: Bool, hovered: Bool) -> TabButton {
                            let b = TabButton(frame: CGRect(x: x, y: 4, width: 100, height: Theme.Metrics.tabHeight + style.overlap))
                            b.style = style; b.title = ""; b.isActive = active
                            b.setHoveringForTest(hovered)
                            host.addSubview(b)
                            return b
                        }
                        let a = button(4, active: true, hovered: false)
                        let h = button(120, active: false, hovered: true)
                        let i = button(236, active: false, hovered: false)
                        // The left end of the body, clear of the title, the underline and the ×.
                        let px = [a, h, i].map { PixelProbe.sample(host, at: CGPoint(x: $0.frame.minX + 5, y: $0.frame.minY + 8)) }
                        let what = "\(name) \(style.rawValue)"
                        for (got, want, label) in [(px[0], Theme.surface, "active"), (px[1], Theme.hover, "hovered"), (px[2], Theme.chrome, "inactive")]
                            where !PixelProbe.matches(got, want) {
                            q.append("\(what): the \(label) tab reads \(hex(got)), want \(hex(want))")
                        }
                        // A strip that can't deepen (black, white at the default) equals the active
                        // tab; the hovered one then equals both, which counts as between.
                        let flat = PixelProbe.matches(px[2], px[0])
                        if let s = px[2]?.luminance, let hv = px[1]?.luminance, let ac = px[0]?.luminance,
                           flat ? !PixelProbe.matches(px[1], px[0]) : !(min(s, ac) < hv && hv < max(s, ac)) {
                            q.append("\(what): the hovered tab isn't between the inactive and the active one")
                        }
                    }
                    return q
                } }
            }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }) {}

        // #87: on a translucent window a connected active tab is opaque by default (`.opaque`, #67's
        // full-opacity tabs), the same as on an opaque window; the other options show the terminal
        // with a foreground tint, and `.clearInactive` drops the inactive pills.
        let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("dealer-selftest-tabcontrast-\(getpid())", isDirectory: true)
        func loadConfig(_ text: String?) {
            if let text {
                let file = configDir.appendingPathComponent("config")
                try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                try? ("background = #22262d\nforeground = #c5c9c7\n" + text).write(to: file, atomically: true, encoding: .utf8)
                GhosttyRuntime.configFileOverride = file.path
            } else {
                GhosttyRuntime.configFileOverride = nil
                try? FileManager.default.removeItem(at: configDir)
            }
            GhosttyRuntime.shared.reloadConfig()
            layoutNow()
            refreshChrome()
        }
        t.step("tab contrast: under glass the active connected tab is the opaque terminal background over opaque inactive pills; the other options tint it or drop the pills", nil, {
            guard Theme.transparency.isTranslucent, Theme.transparency.blur.isGlass else { return "the test config should be glass" }
            let saved = TabStyle.translucent
            defer { TabStyle.translucent = saved }
            var p: [String?] = []
            func sample(active: Bool) -> NSColor? {
                let b = TabButton(frame: CGRect(x: 0, y: 0, width: 100, height: Theme.Metrics.tabHeight + 1))
                b.style = .connected; b.title = ""; b.isActive = active
                return PixelProbe.sample(b, at: CGPoint(x: 5, y: 8))
            }
            TabStyle.translucent = .opaque
            p.append(saved == .opaque ? nil : "the default should be .opaque, is \(saved)")
            p.append(PixelProbe.matches(sample(active: true), Theme.surface) ? nil : "opaque: the active tab reads \(hex(sample(active: true))), want \(hex(Theme.surface))")
            p.append(PixelProbe.matches(sample(active: false), Theme.chrome) ? nil : "opaque: an inactive tab reads \(hex(sample(active: false))), want the opaque pill \(hex(Theme.chrome))")
            TabStyle.translucent = .tinted
            // Over nothing (glass: the tab's own fill is clear) only the tint shows; at 8% alpha its
            // 8-bit color is too coarse to compare, so check its alpha.
            let tinted = sample(active: true)?.alphaComponent ?? 0
            p.append(abs(tinted - TabStyle.activeTint) < 0.02 ? nil : "tinted: the active tab's alpha is \(ratio(tinted)), want the \(ratio(TabStyle.activeTint)) tint")
            p.append(PixelProbe.matches(sample(active: false), Theme.chrome) ? nil : "tinted: inactive tabs keep their opaque pill")
            TabStyle.translucent = .clearInactive
            p.append((sample(active: false)?.alphaComponent ?? 1) < 0.02 ? nil : "clearInactive: an inactive tab should draw no pill, reads \(hex(sample(active: false)))")
            let s = p.compactMap { $0 }
            return s.isEmpty ? nil : s.joined(separator: "; ")
        }) {
            loadConfig("background-opacity = 0.5\nbackground-blur = macos-glass-regular\n")
        }
        t.step("tab contrast: clean up (launch config)", nil, {
            GhosttyRuntime.configFileOverride == nil && !Theme.transparency.isTranslucent ? nil : "the launch config should be back"
        }) {
            loadConfig(nil)
        }
    }
}

/// A strip-colored backdrop for the tab buttons (#87): on an opaque window an inactive tab has no
/// fill and shows the strip.
private final class StripFill: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
    }
}
