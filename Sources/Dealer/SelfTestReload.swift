import AppKit
import GhosttyKit

// MARK: - Self-test section: ⌘⇧, reloads the ghostty config and re-themes the chrome live (#33)

extension TerminalWindowController {
    func reloadSelfTestSteps(_ t: SelfTestKit) {
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        let fm = FileManager.default
        // ghostty reads $XDG_CONFIG_HOME/ghostty/config (and its themes/ directory) at every load.
        let home = fm.temporaryDirectory.appendingPathComponent("dealer-selftest-ghostty-\(getpid())", isDirectory: true)
        let dir = home.appendingPathComponent("ghostty", isDirectory: true)
        let savedXDG = getenv("XDG_CONFIG_HOME").map { String(cString: $0) }
        struct Look { let name, background, foreground: String; let fontSize: Int }
        // Catppuccin Frappé and Latte (background/foreground), as theme files of our own so the
        // test doesn't depend on an installed Ghostty.app's themes.
        let frappe = Look(name: "dealer-test-frappe", background: "303446", foreground: "c6d0f5", fontSize: 13)
        let latte = Look(name: "dealer-test-latte", background: "eff1f5", foreground: "4c4f69", fontSize: 18)

        func writeConfig(_ text: String) {
            try? fm.createDirectory(at: dir.appendingPathComponent("themes"), withIntermediateDirectories: true)
            for l in [frappe, latte] {
                try? "background = #\(l.background)\nforeground = #\(l.foreground)\n"
                    .write(to: dir.appendingPathComponent("themes/\(l.name)"), atomically: true, encoding: .utf8)
            }
            try? text.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        func use(_ l: Look) { writeConfig("theme = \(l.name)\nfont-size = \(l.fontSize)\n") }

        /// ⌘⇧, through the menu item, the way a key press resolves it.
        var menuItem: NSMenuItem?
        func findItem() -> NSMenuItem? {
            func find(_ m: NSMenu) -> [NSMenuItem] {
                m.items.flatMap { i -> [NSMenuItem] in
                    (i.keyEquivalent == "," && i.keyEquivalentModifierMask == [.command, .shift] ? [i] : []) + (i.submenu.map(find) ?? [])
                }
            }
            let hits = NSApp.mainMenu.map(find) ?? []
            return hits.count == 1 ? hits[0] : nil
        }
        func pressReload() {
            guard let item = menuItem ?? findItem(), let action = item.action else { return }
            NSApp.sendAction(action, to: nil, from: item)
        }
        func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) {
            let end = Date().addingTimeInterval(timeout)
            while !cond() && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }

        // The panes the checks look at: a split (so one pane is veiled) in a fresh tab, plus the sidebar.
        var tab: Tab?
        var surfaces: [ObjectIdentifier: ghostty_surface_t] = [:]
        var cellHeight: UInt32 = 0
        func paneA() -> Pane { t.pane("rlA") }
        func paneB() -> Pane { t.pane("rlB") }
        func cell() -> UInt32 { paneA().surface.surface.map { ghostty_surface_size($0).cell_height_px } ?? 0 }
        func recordSurfaces() {
            for p in allDecks.flatMap(\.tabs).flatMap(\.panes) { if let s = p.surface.surface { surfaces[ObjectIdentifier(p)] = s } }
        }
        func surfacesKept() -> String? {
            let panes = allDecks.flatMap(\.tabs).flatMap(\.panes)
            for (id, s) in surfaces {
                guard let p = panes.first(where: { ObjectIdentifier($0) == id }) else { return "a pane disappeared" }
                if p.surface.surface != s { return "\(t.name(p))'s surface was recreated" }
                if ghostty_surface_process_exited(s) { return "\(t.name(p))'s process exited" }
            }
            return nil
        }

        func near(_ a: NSColor?, _ b: NSColor) -> Bool { PixelProbe.matches(a, b) }
        func hex(_ c: NSColor?) -> String { c?.usingColorSpace(.sRGB)?.hexString ?? "nil" }
        /// The theme-derived colors chrome may hold, for the stale-copy scan.
        func themeColors() -> [NSColor] {
            [Theme.background, Theme.foreground, Theme.chrome, Theme.surface, Theme.paneBar, Theme.hover,
             Theme.hairline, Theme.divider, Theme.unfocusedFill, Theme.text, Theme.textMuted, Theme.textFaint,
             Theme.accentNeutral, Theme.foreground.withAlphaComponent(0.16), Theme.foreground.withAlphaComponent(0.14),
             Theme.attentionWaiting, Theme.attentionFailed]
        }
        var oldColors: [NSColor] = []
        /// Same color including alpha, within the probe's tolerance.
        func same(_ a: NSColor, _ b: NSColor) -> Bool {
            guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
            return max(abs(x.redComponent - y.redComponent), abs(x.greenComponent - y.greenComponent),
                       abs(x.blueComponent - y.blueComponent), abs(x.alphaComponent - y.alphaComponent)) <= PixelProbe.tolerance
        }
        /// No visible layer or control anywhere in the window (or in parked deck views) still holds a
        /// color of the previous theme that the new theme doesn't also have.
        func noStaleColors() -> String? {
            let current = themeColors()
            let stale = oldColors.filter { o in !current.contains { same($0, o) } }
            var hits: [String] = []
            func check(_ cg: CGColor?, _ what: String) {
                guard let cg, let c = NSColor(cgColor: cg), c.alphaComponent > 0 else { return }
                if stale.contains(where: { same($0, c) }) { hits.append("\(what) \(hex(c))") }
            }
            func walk(_ l: CALayer, _ owner: String) {
                guard !l.isHidden else { return }
                check(l.backgroundColor, "\(owner) layer \(l.name ?? "") background")
                check(l.borderColor, "\(owner) layer \(l.name ?? "") border")
                l.sublayers?.forEach { walk($0, owner) }
            }
            func walk(_ v: NSView) {
                guard !v.isHidden else { return }
                let owner = String(describing: type(of: v))
                if let l = v.layer {
                    check(l.backgroundColor, "\(owner) background")
                    check(l.borderColor, "\(owner) border")
                    l.sublayers?.filter { s in !v.subviews.contains { $0.layer === s } }.forEach { walk($0, owner) }
                }
                if let f = v as? NSTextField { check(f.textColor?.cgColor, "\(owner) text") }
                if let b = v as? NSButton { check(b.contentTintColor?.cgColor, "\(owner) tint") }
                v.subviews.forEach(walk)
            }
            walk(contentView)
            for d in allDecks where !d.view.isDescendant(of: contentView) { walk(d.view) }
            if let w = window { check(w.backgroundColor.cgColor, "window background") }
            return hits.isEmpty ? nil : "stale colors from the previous theme: " + Array(Set(hits)).sorted().prefix(6).joined(separator: ", ")
        }

        /// The issue's pixel checks: the strip, the sidebar row, the pane bar and the veil.
        func pixelsMatchTheme() -> String? {
            guard let deck = tab.flatMap({ self.deck(of: $0) }) else { return "test tab is gone" }
            var p: [String] = []
            // Strip: the active tab's fill, and the chrome behind the strip (past the "+").
            let strip = deck.view.strip
            if let b = strip.buttons.first(where: { $0.isActive }) {
                let got = PixelProbe.sample(b, at: CGPoint(x: 4, y: b.bounds.midY))
                if !near(got, Theme.surface) { p.append("active tab \(hex(got)) ≠ surface \(hex(Theme.surface))") }
            } else { p.append("no active tab button") }
            let past = strip.convert(CGPoint(x: strip.addButton.frame.maxX + 12, y: strip.bounds.midY), to: contentView)
            let chrome = PixelProbe.sample(contentView, at: past)
            if !near(chrome, Theme.chrome) { p.append("strip chrome \(hex(chrome)) ≠ \(hex(Theme.chrome))") }
            // Sidebar: the active workspace's row.
            if let row = (0..<workspaces.count).compactMap({ self.workspaceSidebar.row(at: $0) as? WorkspaceRow }).first(where: { $0.isActive }) {
                let got = PixelProbe.sample(row, at: CGPoint(x: 3, y: row.bounds.midY))
                if !near(got, Theme.surface) { p.append("sidebar row \(hex(got)) ≠ surface \(hex(Theme.surface))") }
            } else { p.append("no active sidebar row") }
            // Pane bar: its right end (no dots, no text, no × without hover).
            let bar = paneA().view.bar
            let barColor = PixelProbe.sample(bar, at: CGPoint(x: bar.bounds.maxX - 3, y: bar.bounds.midY))
            if !near(barColor, Theme.paneBar) { p.append("pane bar \(hex(barColor)) ≠ \(hex(Theme.paneBar))") }
            // Veil over the unfocused pane: its fill, and its strength.
            let veil = paneA().view.veilForTest
            let veilColor = PixelProbe.sample(veil, at: CGPoint(x: veil.bounds.midX, y: veil.bounds.midY))
            if !near(veilColor?.withAlphaComponent(1), Theme.unfocusedFill) { p.append("veil \(hex(veilColor)) ≠ \(hex(Theme.unfocusedFill))") }
            if abs(veil.alphaValue - Theme.unfocusedAlpha) > 0.01 { p.append("veil alpha \(veil.alphaValue) ≠ \(Theme.unfocusedAlpha)") }
            // Deck card: the 1pt gap between the two panes shows the divider color.
            let gapX = paneA().view.frame.maxX + 0.5
            let gap = PixelProbe.sample(deck.view.content, at: CGPoint(x: gapX, y: paneA().view.frame.midY))
            if !near(gap, Theme.divider) { p.append("pane gap \(hex(gap)) ≠ divider \(hex(Theme.divider))") }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func themeIs(_ l: Look) -> String? {
            hex(Theme.background).lowercased() == "#" + l.background && hex(Theme.foreground).lowercased() == "#" + l.foreground
                ? nil : "Theme should be \(l.name): background \(hex(Theme.background)), foreground \(hex(Theme.foreground))"
        }
        func fontApplied(bigger: Bool) -> String? {
            guard paneA().surface.surface != nil else { print("      (skipped font check: no live surface, screen locked?)"); return nil }
            let c = cell()
            return (bigger ? c > cellHeight : c < cellHeight) ? nil
                : "the terminal's cell height should have \(bigger ? "grown" : "shrunk") with font-size (\(cellHeight) → \(c))"
        }

        t.step("reload: ⌘⇧, is Reload Configuration, the only item on that shortcut", nil, {
            guard let item = menuItem else { return "no single menu item on ⌘⇧," }
            return all(item.title == "Reload Configuration" ? nil : "the item is \(item.title)",
                       item.action == #selector(AppDelegate.reloadConfiguration(_:)) ? nil : "wrong action")
        }) {
            menuItem = findItem()
        }
        t.step("reload: a temp ghostty config with the Frappé theme applies to the chrome", nil, {
            all(themeIs(frappe), pixelsMatchTheme(), GhosttyRuntime.shared.configProblems.isEmpty ? nil : "no problems expected: \(GhosttyRuntime.shared.configProblems)")
        }) {
            setenv("XDG_CONFIG_HOME", home.path, 1)
            use(frappe)
            pressReload()
            guard let deck = self.focusedDeck else { return }
            self.newTab(in: deck)
            t.named(self.focusedPane, "rlA")
            tab = deck.activeTab
            self.split(paneA(), side: .right)
            t.named(self.focusedPane, "rlB")
            self.sidebarPreference = true
            self.layoutNow()
            waitUntil(1) { false }  // let the new surfaces start
            recordSurfaces()
            cellHeight = cell()
            oldColors = themeColors()
        }
        t.step("reload: switching to Latte re-themes the strip, sidebar row, pane bar, veil and divider", nil, {
            all(themeIs(latte), pixelsMatchTheme(), noStaleColors())
        }) {
            use(latte)
            pressReload()
        }
        t.step("reload: the terminals took the new font and kept their processes", nil, {
            all(fontApplied(bigger: true), surfacesKept())
        }) {
            waitUntil { cell() > cellHeight }
        }
        t.step("reload: a waiting pane's ring and its tab's outline re-theme too (#34's layers)", nil, {
            let ring = paneA().view.layer?.sublayers?.first { $0.name == "dealer.attentionRing" }
            let button = tab.flatMap { self.deck(of: $0) }?.view.strip.buttons.first { $0.isActive }
            return all(themeIs(frappe),
                       ring.flatMap { $0.borderColor.flatMap(NSColor.init(cgColor:)) }.map { near($0, Theme.attentionWaiting) } == true
                           ? nil : "the ring should be \(hex(Theme.attentionWaiting))",
                       PixelProbe.isWaitingOutlined(button) ? nil : "the tab should be outlined in \(hex(Theme.attentionWaiting))",
                       noStaleColors())
        }) {
            self.setAttention(.waiting, on: paneA())
            oldColors = themeColors()
            use(frappe)
            pressReload()
        }
        t.step("reload: a broken config keeps the old colors and shows the banner", nil, {
            all(themeIs(latte), pixelsMatchTheme(),
                GhosttyRuntime.shared.configProblems.isEmpty ? "the config's problems should be recorded" : nil,
                self.settingsBanner.isHidden ? "the banner should show" : nil,
                self.settingsBanner.message.contains("ghostty") ? nil : "the banner should name the ghostty config: \(self.settingsBanner.message)",
                surfacesKept())
        }) {
            self.setAttention(.none, on: paneA())
            use(latte)
            pressReload()
            oldColors = themeColors()
            cellHeight = cell()
            writeConfig("theme = \(frappe.name)\nbackground = not-a-color\nfont-size = 13\nno-such-key = 1\n")
            pressReload()
        }
        t.step("reload: ghostty's reload_config keybind action reloads too; fixing the config clears the banner", nil, {
            all(themeIs(frappe), pixelsMatchTheme(), noStaleColors(),
                self.settingsBanner.isHidden ? nil : "the banner should go away: \(self.settingsBanner.message)",
                fontApplied(bigger: false), surfacesKept())
        }) {
            oldColors = themeColors()
            use(frappe)
            if let s = paneA().surface.surface {
                // Through ghostty: the keybind action reaches GhosttyRuntime.handle as RELOAD_CONFIG.
                _ = "reload_config".withCString { ghostty_surface_binding_action(s, $0, UInt("reload_config".utf8.count)) }
                waitUntil { themeIs(frappe) == nil }
            } else {
                print("      (skipped reload_config action: no live surface, screen locked?)")
                pressReload()
            }
            self.layoutNow()
        }
        t.step("reload: theme = light:…,dark:… follows the macOS appearance (dark → Frappé)", nil, {
            all(themeIs(frappe), pixelsMatchTheme())
        }) {
            writeConfig("theme = light:\(latte.name),dark:\(frappe.name)\nfont-size = 13\n")
            pressReload()
            GhosttyRuntime.shared.setColorScheme(dark: true)
            waitUntil { themeIs(frappe) == nil }
        }
        t.step("reload: …and back to light (→ Latte), chrome included", nil, {
            all(themeIs(latte), pixelsMatchTheme(), noStaleColors())
        }) {
            oldColors = themeColors()
            GhosttyRuntime.shared.setColorScheme(dark: false)
            waitUntil { themeIs(latte) == nil }
        }
        t.step("reload: clean up (back to the launch config)", nil, {
            tab.flatMap { self.deck(of: $0) } == nil ? nil : "test tab should be closed"
        }) {
            if let tab { self.close(tab: tab) }
            self.sidebarPreference = nil
            if let x = savedXDG { setenv("XDG_CONFIG_HOME", x, 1) } else { unsetenv("XDG_CONFIG_HOME") }
            try? fm.removeItem(at: home)
            pressReload()
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            GhosttyRuntime.shared.setColorScheme(dark: dark)
        }
    }
}

