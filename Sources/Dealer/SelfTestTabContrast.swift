import AppKit

// MARK: - Self-test section: tab contrast (#87, Theme.chromeColor, TabButton.draw)
//
// Across dark, near-black and light themes: the active tab (`Theme.surface`) stands at least
// `Theme.chromeContrast` (WCAG) off the strip (`Theme.chrome`), and a hovered tab (`Theme.hover`)
// sits strictly between the two in luminance, so it never looks more selected than the active
// one. Checked on the formulas and on pixels of real tab buttons, in both tab styles. On a
// translucent window the active connected tab follows `TabStyle.translucent`.
// Self-contained (`DEALER_SELFTEST_ONLY=tab contrast:`); restores the launch config.

extension TerminalWindowController {
    func tabContrastSelfTestSteps(_ t: SelfTestKit) {
        func hex(_ c: NSColor?) -> String {
            guard let c = c?.usingColorSpace(.sRGB) else { return "nil" }
            return c.hexString + (c.alphaComponent < 1 ? String(format: "@%.2f", c.alphaComponent) : "")
        }
        func ratio(_ c: CGFloat) -> String { String(format: "%.2f", c) }
        /// (name, background, foreground, whether the strip should be darker than the terminal).
        /// Kanso Mist is the user's theme; it's near the darkest background that can still reach the
        /// target by darkening. Catppuccin Mocha and the near-black ones can't, so their strip lightens.
        let themes: [(String, String, String, Bool)] = [
            ("Kanso Mist", "#22262d", "#c5c9c7", true),
            ("Ghostty default dark", "#282c34", "#ffffff", true),
            ("Nord", "#2e3440", "#d8dee9", true),
            ("Catppuccin Mocha", "#1e1e2e", "#cdd6f4", false),
            ("near-black", "#0a0a0a", "#d0d0d0", false),
            ("black", "#000000", "#ffffff", false),
            ("Catppuccin Latte", "#eff1f5", "#4c4f69", true),
            ("Solarized light", "#fdf6e3", "#657b83", true),
            ("white", "#ffffff", "#000000", true),
        ]
        let tolerance: CGFloat = 0.005
        let direction = Theme.chromeDarkDirection

        func writeSettings(_ text: String) {
            let url = Settings.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            Settings.reload()
        }
        /// The order and the ratio in every theme at the current `[colors] chrome_contrast`. At 1.0
        /// the three are one color (nothing can lie strictly between); attention outlines keep 3:1
        /// on the chrome up to the default (above about 1.5 dark themes' chrome lightens and the
        /// red, then the blue, drop under 3:1, so that's not asserted there).
        func orderProblems() -> [String] {
            var p: [String] = []
            let target = Theme.chromeContrast
            for (name, bg, fg, darker) in themes {
                Theme.withBackground(NSColor(hex: bg)!, foreground: NSColor(hex: fg)!) {
                    let strip = Theme.chrome, hover = Theme.hover, active = Theme.surface
                    let (ls, lh, la) = (strip.luminance, hover.luminance, active.luminance)
                    let c = active.contrast(with: strip)
                    let at = "\(name) @\(ratio(target))"
                    if c < target - tolerance || c > target + 0.02 {
                        p.append("\(at): active \(hex(active)) vs strip \(hex(strip)) is \(ratio(c)):1, want \(ratio(target))")
                    }
                    let between = target <= 1 ? min(ls, la) <= lh && lh <= max(ls, la) : min(ls, la) < lh && lh < max(ls, la)
                    if !between {
                        p.append("\(at): hover \(hex(hover)) isn't between the strip \(hex(strip)) and the active tab \(hex(active)) in luminance")
                    }
                    // Darkens when it can reach the target that way (the table's flag is for 1.35).
                    let canDarken = active.contrast(with: .black) >= target
                    let wantDarker = !Theme.isDark || (canDarken && direction == .darken)
                    if target > 1, (ls < la) != wantDarker || (abs(target - 1.35) < 0.001 && wantDarker != (darker || !Theme.isDark)) {
                        p.append("\(at): the strip \(hex(strip)) should be \(wantDarker ? "darker" : "lighter") than the terminal \(hex(active))")
                    }
                    if target <= 1.35 {
                        for (what, color) in [("waiting", Theme.attentionWaiting), ("failed", Theme.attentionFailed)] {
                            let r = color.contrast(with: strip)
                            if r < 3 { p.append("\(at): the \(what) outline is only \(ratio(r)):1 on the strip \(hex(strip))") }
                        }
                    }
                }
            }
            return p
        }

        t.step("tab contrast: in every theme the active tab stands chromeContrast off the strip, and hover sits strictly between them", nil, {
            let p = orderProblems()
            return Settings.chromeContrast == 1.35 ? (p.isEmpty ? nil : p.joined(separator: "; ")) : "the default chrome_contrast should be 1.35, is \(Settings.chromeContrast)"
        }) {
            writeSettings("")
        }
        // #87: `[colors] chrome_contrast` lowers it (the user's main use) or raises it, live.
        for value in ["1.0", "1.1", "1.2", "1.6", "2.5"] {
            t.step("tab contrast: [colors] chrome_contrast = \(value) holds in every theme", nil, {
                let p = orderProblems()
                return abs(Theme.chromeContrast - CGFloat(Double(value)!)) < 0.001 ? (p.isEmpty ? nil : p.joined(separator: "; "))
                    : "chrome_contrast should read \(value), reads \(Theme.chromeContrast)"
            }) {
                writeSettings("[colors]\nchrome_contrast = \(value)\n")
            }
        }
        t.step("tab contrast: a bad chrome_contrast is reported and the default used", nil, {
            let reported = Settings.problems.contains { $0.contains("colors.chrome_contrast") }
            return reported && Settings.chromeContrast == 1.35 ? nil
                : "chrome_contrast = 3 should be reported (\(reported)) and read as 1.35 (\(Settings.chromeContrast))"
        }) {
            writeSettings("[colors]\nchrome_contrast = 3\n")
        }
        t.step("tab contrast: a settings reload re-themes open windows: window background and strip in the new chrome", nil, {
            guard let dv = self.focusedDeck?.view, let w = self.window else { return "no deck" }
            let want = Theme.chrome
            guard Theme.surface.contrast(with: want) > 1.55 else { return "chrome_contrast = 1.6 didn't apply: \(ratio(Theme.surface.contrast(with: want))):1" }
            let s = dv.strip
            let past = s.convert(CGPoint(x: s.addButton.frame.maxX + 12, y: s.bounds.midY), to: self.contentView)
            let px = PixelProbe.sample(self.contentView, at: past)
            return [PixelProbe.matches(w.backgroundColor, want) ? nil : "the window background is \(hex(w.backgroundColor)), want \(hex(want))",
                    PixelProbe.matches(px, want) ? nil : "the strip reads \(hex(px)), want \(hex(want))"].compactMap { $0 }.first
        }) {
            writeSettings("[colors]\nchrome_contrast = 1.6\n")
        }
        t.step("tab contrast: back to the default chrome_contrast", nil, {
            Settings.chromeContrast == 1.35 && Settings.problems.isEmpty ? nil : "settings should be back to the defaults"
        }) {
            writeSettings("")
        }

        t.step("tab contrast: real tab buttons fill active, hovered and inactive in that order, connected and pill, at 2x and 1x", nil, {
            var p: [String] = []
            for (name, bg, fg, _) in themes {
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
                        if let s = px[2]?.luminance, let hv = px[1]?.luminance, let ac = px[0]?.luminance,
                           !(min(s, ac) < hv && hv < max(s, ac)) {
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
