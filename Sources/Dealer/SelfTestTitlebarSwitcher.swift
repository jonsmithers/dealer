import AppKit

// MARK: - Self-test section: the titlebar workspace switcher (#96, TitlebarSwitcher.swift)
//
// Self-contained (`DEALER_SELFTEST_ONLY=titlebar switcher:`). With the sidebar hidden, a button at the
// right end of the titlebar row (#104; right of the sidebar toggle with `[workspaces]
// titlebar_switcher = "left"`) names the current workspace; a click opens the dropdown, a row's click
// switches. Clicks go through `window.sendEvent`, the way the sidebar's rows are clicked; the
// window server's titlebar routing can't be reproduced in-process, so `mouseDownCanMoveWindow` is
// asserted (#27).

extension TerminalWindowController {
    func titlebarSwitcherSelfTestSteps(_ t: SelfTestKit) {
        let button = titlebarSwitcher
        let menu = titlebarSwitcherMenu
        var savedPreference: Bool??
        var alpha: Workspace?, beta: Workspace?, gamma: Workspace?
        var before: NSColor?
        /// The settings file as this section found it, restored at cleanup (nil: there was none).
        var savedSettings: String??

        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func want<T: Equatable>(_ what: String, _ got: T, _ expected: T) -> String? {
            got == expected ? nil : "\(what) is \(got), want \(expected)"
        }
        func shown() -> Bool { button.superview === contentView && !button.isHiddenOrHasHiddenAncestor }
        /// Raw events at the button's place; refused while it's hidden, since a press on whatever is
        /// underneath (a pane bar, a strip) can start a drag loop that waits forever for a release.
        func send(_ type: NSEvent.EventType, at p: CGPoint) {
            guard shown() else { return }
            if let e = mouseEventForTest(type, at: p) { window?.sendEvent(e) }
        }
        func center(_ v: NSView) -> CGPoint { v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
        func active(_ ws: Workspace?, _ name: String) -> String? { activeWorkspace === ws ? nil : "\(name) should be the active workspace, is \(activeWorkspace.displayName)" }
        /// `[workspaces] titlebar_switcher` (#104), written into the settings file and reloaded, as
        /// an edit of the file would be; nil removes the key (the default, "right"). Written as
        /// text rather than through `Settings.write`, so the section also runs where the key is unknown.
        func setSide(_ side: String?) {
            let url = Settings.fileURL
            if savedSettings == nil { savedSettings = .some(try? String(contentsOf: url, encoding: .utf8)) }
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("titlebar_switcher") }.joined(separator: "\n")
            if let side { text = SettingsFile.rewrite(text, key: "workspaces.titlebar_switcher", literal: "\"\(side)\"") }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            Settings.reload(force: true)
        }
        /// Where the button ends on the right: at the cup's reserve (#69), else the deck area's edge.
        func rightEnd() -> CGFloat {
            min(contentView.bounds.width - titlebarTrailingReserve, contentView.bounds.width - Self.deckGap)
        }
        /// The button at the right end of the titlebar row (#104): it ends at `rightEnd`, strips start
        /// right after the toggle and end 8pt before it.
        func onRight() -> String? {
            all(shown() ? nil : "the titlebar switcher should show",
                abs(button.frame.maxX - rightEnd()) < 0.5 ? nil : "it should end at the titlebar row's right end \(rightEnd()), ends at \(button.frame.maxX)",
                want("its width", button.frame.width, TitlebarSwitcherButton.width),
                abs(button.frame.midY - self.sidebarToggle.frame.midY) < 0.5 ? nil : "it should share the toggle's row",
                stripsClear(of: button))
        }
        /// The button right of the toggle (`titlebar_switcher = "left"`, #96's place).
        func onLeft() -> String? {
            all(shown() ? nil : "the titlebar switcher should show",
                want("its x", button.frame.minX, self.sidebarToggle.frame.maxX + 4),
                want("its width", button.frame.width, TitlebarSwitcherButton.width),
                abs(button.frame.midY - self.sidebarToggle.frame.midY) < 0.5 ? nil : "it should share the toggle's row",
                stripsClear(of: button))
        }
        /// Titlebar strips clear of the button and nothing overlapping it: on the left they start
        /// after it (#16's clear line), on the right they start after the toggle and end before it
        /// (#104). Judged from where the button is, so a wrong side shows as a wrong clear line.
        func stripsClear(of v: NSView) -> String? {
            let strips = titlebarStripDecks.map(\.view.strip)
            if strips.isEmpty { return "a top deck's strip should be in the titlebar" }
            let toggle = self.sidebarToggle.frame
            let right = v.frame.minX > toggle.maxX + 4.5
            for s in strips where s.frame.intersects(v.frame) || (right ? s.frame.maxX > v.frame.minX - 8 + 0.5 : s.frame.minX < v.frame.maxX) {
                return "a titlebar strip \(s.frame) overlaps \(v === button ? "the switcher" : "the toggle") \(v.frame)"
            }
            guard right else { return want("clear line", titlebarClearX, v.frame.maxX + 8) }
            let ends = strips.map(\.frame.maxX).max() ?? 0
            return all(want("clear line", titlebarClearX, toggle.maxX + 8),
                       want("the titlebar strips' end", ends, v.frame.minX - 8))
        }
        func dotColor() -> NSColor? {
            let r = button.attentionDotRect
            return PixelProbe.sample(button, at: CGPoint(x: r.minX + r.width * 0.2, y: r.midY))
        }

        t.step("titlebar switcher: hidden while the sidebar shows", nil, {
            all(self.isSidebarVisible ? nil : "the sidebar should show",
                shown() ? "the titlebar switcher should be hidden while the sidebar shows" : nil)
        }) {
            savedPreference = .some(self.sidebarPreference)
            alpha = self.newWorkspace(name: "ts-alpha"); t.named(self.focusedPane, "tsa")
            beta = self.newWorkspace(name: "ts-beta"); t.named(self.focusedPane, "tsb")
            gamma = self.newWorkspace(name: "ts-gamma"); t.named(self.focusedPane, "tsc")
            alpha.map(self.activate)
            self.sidebarPreference = true
            self.layoutNow()
        }
        t.step("titlebar switcher: hiding the sidebar shows it at the titlebar row's right end (#104), named after the workspace; strips start after the toggle and end before it", nil, {
            // The empty titlebar between the strip and the button still drags the window.
            let gapX = ((self.titlebarStripDecks.map(\.view.strip.frame.maxX).max() ?? 0) + button.frame.minX) / 2
            let gapView = self.contentView.hitTest(self.contentView.superview!.convert(CGPoint(x: gapX, y: button.frame.midY), from: self.contentView))
            return all(want("its title", button.title, "ts-alpha"),
                       onRight(),
                       // #27: the window server must hand titlebar presses on it to the app.
                       button.mouseDownCanMoveWindow ? "mouseDownCanMoveWindow must be false (#27)" : nil,
                       self.contentView.hitTest(self.contentView.superview!.convert(center(button), from: nil)) === button ? nil : "a click at its centre should hit it",
                       gapView?.mouseDownCanMoveWindow == true ? nil : "the titlebar between the strip and the switcher should drag the window, hits \(gapView.map { "\(type(of: $0))" } ?? "nothing")")
        }) {
            self.toggleWorkspaceSidebar(nil)
        }
        // #102: one fixed width (the user's 200pt), whatever the name, so strips after it never move.
        // #104: on both sides, so a switch moves neither end of a strip.
        var widths: [String: CGFloat] = [:], stripXs: [String: [String: CGRect]] = [:], chevrons: [String: CGFloat] = [:]
        var placement: [String: String] = [:]
        t.step("titlebar switcher: it's 200pt for a short or a long name and with a dot; a switch doesn't move the strips, with it on the right or the left (#102, #104)", nil, {
            let long = "ts-alpha, a workspace with a name far too long for the titlebar"
            let moved = stripXs.filter { Set($0.value.values.map { "\($0)" }).count != 1 }
            return all(widths.isEmpty ? "nothing measured" : nil,
                       widths.filter { $0.value != 200 }.isEmpty ? nil : "its width should be 200 every time, got \(widths)",
                       stripXs.count == 2 ? nil : "both sides should be measured, got \(stripXs.keys.sorted())",
                       moved.isEmpty ? nil : "the titlebar strip moved: \(moved)",
                       Set(chevrons.values).count == 2 ? nil : "the chevron should stay at the right edge on each side: \(chevrons)",
                       placement.isEmpty ? nil : "\(placement)",
                       // A long name truncates inside the button rather than widening it.
                       button.title == long ? nil : "the long name should be the title")
        }) {
            let strip = { self.titlebarStripDecks.first.map { $0.view.strip.frame } ?? .null }
            for side in ["right", "left"] {
                setSide(side == "right" ? nil : side)
                alpha.map { self.rename(workspace: $0, to: "ts-alpha") }
                alpha.map(self.activate)
                func measure(_ k: String) {
                    self.layoutNow()
                    widths["\(side) \(k)"] = button.frame.width
                    stripXs[side, default: [:]][k] = strip()
                    chevrons["\(side) \(k)"] = button.convert(CGPoint(x: button.chevronRect.maxX, y: 0), to: self.contentView).x
                    if let p = side == "right" ? onRight() : onLeft() { placement["\(side) \(k)"] = p }
                }
                measure("short")
                beta.map(self.activate); measure("switched")
                if let p = gamma?.panes.first { self.setAttention(.waiting, on: p) }
                self.refreshChrome(); measure("dot")
                if let p = gamma?.panes.first { self.setAttention(.none, on: p) }
                alpha.map(self.activate)
                alpha.map { self.rename(workspace: $0, to: "ts-alpha, a workspace with a name far too long for the titlebar") }
                self.refreshChrome(); measure("long")
            }
            setSide(nil)
        }
        t.step("titlebar switcher: a click on the button opens the dropdown with every workspace, the current one checked", nil, {
            let missing = self.workspaces.filter { menu.row(for: $0) == nil }.map(\.displayName)
            return all(menu.isOpen ? nil : "the dropdown should be open",
                       button.isOpen ? nil : "the button should draw open",
                       missing.isEmpty ? nil : "rows missing for \(missing)",
                       menu.row(for: alpha!)?.isCurrent == true ? nil : "ts-alpha's row should be checked",
                       self.workspaces.filter { menu.row(for: $0)?.isCurrent == true }.count == 1 ? nil : "exactly one row should be checked",
                       menu.newWorkspaceRow != nil ? nil : "a New Workspace row is expected",
                       self.contentView.subviews.last === menu ? nil : "the dropdown should be above everything in the window",
                       menu.frame.minY >= button.frame.maxY ? nil : "the dropdown should open below the button",
                       // #104: right-aligned to the button on the right, so it stays in the window.
                       abs(menu.frame.maxX - button.frame.maxX) < 1 ? nil : "the dropdown \(menu.frame) should be right-aligned to the button \(button.frame)",
                       self.contentView.bounds.contains(menu.frame) ? nil : "the dropdown \(menu.frame) should stay inside the window \(self.contentView.bounds)",
                       menu.fieldHasFocus ? nil : "the dropdown's search field should take the keys (#105)")
        }) {
            alpha.map { self.rename(workspace: $0, to: "ts-alpha") }
            self.layoutNow()
            self.clickForTest(button)
        }
        t.step("titlebar switcher: clicking a row switches to its workspace and closes the dropdown", nil, {
            all(active(beta, "ts-beta"), menu.isOpen ? "the dropdown should close" : nil,
                button.isOpen ? "the button should no longer draw open" : nil,
                want("the button's title", button.title, "ts-beta"),
                self.focusedPane === t.pane("tsb") ? nil : "focus should be on tsb",
                stripsClear(of: button))
        }) {
            guard let row = menu.row(for: beta!) else { return }
            self.clickForTest(row)
        }
        t.step("titlebar switcher: a press dragged onto a row picks it on release", nil, {
            all(active(alpha, "ts-alpha"), menu.isOpen ? "the dropdown should close" : nil)
        }) {
            send(.leftMouseDown, at: center(button))
            guard let row = menu.row(for: alpha!) else { return }
            send(.leftMouseDragged, at: center(row))
            send(.leftMouseUp, at: center(row))
        }
        t.step("titlebar switcher: ↓ and return pick the next row; esc closes and gives the keys back", nil, {
            all(active(gamma, "ts-gamma"), menu.isOpen ? "esc should close the dropdown" : nil,
                self.window?.firstResponder === t.pane("tsc").surface ? nil : "focus should go back to tsc's terminal")
        }) {
            func key(_ code: UInt16, _ chars: String) {
                guard let w = self.window else { return }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { w.sendEvent(e) }
                }
            }
            // Opens on ts-beta's row, the previously active workspace (#105), so the next one down is ts-gamma.
            self.clickForTest(button)
            key(125, "\u{F701}")
            key(36, "\r")
            self.clickForTest(button)
            key(53, "\u{1B}")
        }
        t.step("titlebar switcher: a second click on the button closes the dropdown", nil, {
            all(menu.isOpen ? "the dropdown should close" : nil, active(gamma, "ts-gamma"))
        }) {
            self.clickForTest(button)
            self.clickForTest(button)
        }
        var rowBefore: TitlebarSwitcherRow?
        var rowKept = false, highlightKept = false, newRowAdded = false
        t.step("titlebar switcher: a chrome refresh, or a new workspace, between a row's press and release keeps the row and its highlight; the click still picks", nil, {
            all(rowBefore == nil ? "no row for ts-beta" : nil, rowKept ? nil : "the refresh replaced the pressed row",
                highlightKept ? nil : "the refresh dropped the highlight",
                newRowAdded ? nil : "the new workspace should get a row while the dropdown is open",
                active(beta, "ts-beta"), menu.isOpen ? "the dropdown should close after the pick" : nil)
        }) {
            self.clickForTest(button)
            guard let row = menu.row(for: beta!) else { return }
            rowBefore = row
            let p = center(row)
            send(.leftMouseDown, at: p)
            // A pane reporting progress or attention refreshes the chrome ~1-2 times a second.
            self.refreshChrome()
            self.layoutNow()
            rowKept = menu.row(for: beta!) === row
            menu.highlight(row)
            // A workspace added meanwhile (the CLI) changes the list: rows that stay are kept too.
            let delta = self.newWorkspace(name: "ts-delta", activate: false)
            self.refreshChrome()
            rowKept = rowKept && menu.row(for: beta!) === row
            highlightKept = menu.highlighted === row
            newRowAdded = menu.row(for: delta) != nil
            send(.leftMouseUp, at: center(row))
        }
        t.step("titlebar switcher: a workspace switch from elsewhere (⌃1–9, the CLI) closes an open dropdown", nil, {
            all(active(alpha, "ts-alpha"), menu.isOpen ? "the dropdown should close" : nil,
                menu.rows.isEmpty ? nil : "a closed dropdown holds no rows",
                want("the button's title", button.title, "ts-alpha"))
        }) {
            self.clickForTest(button)
            if let i = self.workspaces.firstIndex(where: { $0 === alpha }) { _ = self.activateWorkspace(index: i) }
        }
        t.step("titlebar switcher: the current workspace's color shows on it (chip and tint), and on its row", nil, {
            guard let c = beta?.color else { return "no color set" }
            let chip = button.chipRect
            let rowChip = menu.row(for: beta!).map { r in PixelProbe.sample(r, at: CGPoint(x: r.chipRect.midX, y: r.chipRect.midY)) }
            return all(PixelProbe.matches(PixelProbe.sample(button, at: CGPoint(x: chip.midX, y: chip.midY)), c) ? nil : "the chip should be the workspace color",
                       PixelProbe.distance(PixelProbe.sample(button, at: button.tintSamplePoint), before) > 0.02 ? nil : "the tint should show",
                       PixelProbe.matches(rowChip ?? nil, c) ? nil : "the dropdown row's chip should be the workspace color")
        }) {
            beta.map(self.activate)
            before = PixelProbe.sample(button, at: button.tintSamplePoint)
            beta.map { self.setColor(NSColor(hex: "#d03040"), workspace: $0) }
            self.clickForTest(button)
        }
        t.step("titlebar switcher: another workspace's attention shows one dot, no outline; the current one's doesn't", nil, {
            all(menu.isOpen ? "the dropdown should be closed" : nil,
                want("other workspaces' attention", button.otherAttention, .waiting),
                PixelProbe.matches(dotColor(), Theme.attentionWaiting) ? nil : "the waiting dot should show",
                PixelProbe.isWaitingOutlined(button) ? "no outline: it would read as the current workspace" : nil)
        }) {
            self.clickForTest(button)  // close
            if let p = gamma?.panes.first { self.setAttention(.waiting, on: p) }
            self.refreshChrome(); self.layoutNow()
        }
        t.step("titlebar switcher: once that workspace is current, the dot goes", nil, {
            all(want("other workspaces' attention", button.otherAttention, .none),
                PixelProbe.matches(dotColor(), Theme.attentionWaiting) ? "the dot should be gone" : nil)
        }) {
            // Its attention stays (the pane isn't focused), but it's the current workspace now.
            if let p = gamma?.panes.first, let g = gamma {
                self.activate(g)
                self.newTab(nil); t.named(self.focusedPane, "tsc2")
                self.setAttention(.waiting, on: p)
            }
            self.refreshChrome(); self.layoutNow()
        }
        t.step("titlebar switcher: groups are sections; a collapsed group's members are still listed", nil, {
            guard let b = beta, let g = gamma, let rb = menu.row(for: b), let rg = menu.row(for: g),
                  let i = menu.rows.firstIndex(where: { $0 === rb }) else { return "rows for ts-beta and ts-gamma expected" }
            let header = menu.rows.indices.contains(i - 1) ? menu.rows[i - 1] : nil
            guard case .header(let name)? = header?.kind else { return "a group header row should lead ts-beta" }
            return all(want("header", name, "ts-group"),
                       header?.isPickable == true ? "a header isn't pickable" : nil,
                       rb.chipRect.minX > (menu.row(for: alpha!)?.chipRect.minX ?? 0) ? nil : "members should be indented",
                       rg.frame.minY > rb.frame.minY ? nil : "ts-gamma should follow ts-beta")
        }) {
            if let p = gamma?.panes.first { self.setAttention(.none, on: p) }
            guard let b = beta, let g = gamma else { return }
            let group = self.moveToNewGroup(b, name: "ts-group")
            self.move(g, toGroup: group)
            group.isCollapsed = true
            self.refreshChrome(); self.layoutNow()
            self.clickForTest(button)
        }
        t.step("titlebar switcher: titlebar_switcher = \"left\", read live, puts it right of the toggle with the strips after it; an open dropdown follows, left-aligned", nil, {
            all(onLeft(),
                menu.isOpen ? nil : "the open dropdown should stay open",
                want("the dropdown's x", menu.frame.minX, button.frame.minX),
                menu.frame.minY >= button.frame.maxY ? nil : "the dropdown should stay below the button",
                self.contentView.bounds.contains(menu.frame) ? nil : "the dropdown \(menu.frame) should stay inside the window")
        }) {
            self.layoutNow()
            if !menu.isOpen { self.clickForTest(button) }
            setSide("left")
        }
        t.step("titlebar switcher: back to \"right\" live, it returns to the right end; the dropdown follows, right-aligned, and a click still opens it", nil, {
            all(onRight(),
                menu.isOpen ? nil : "a click on the button should open the dropdown",
                abs(menu.frame.maxX - button.frame.maxX) < 1 ? nil : "the dropdown \(menu.frame) should be right-aligned to the button \(button.frame)",
                self.contentView.bounds.contains(menu.frame) ? nil : "the dropdown \(menu.frame) should stay inside the window")
        }) {
            setSide("right")
            if menu.isOpen { self.clickForTest(button) }  // close, then open through the real path
            self.clickForTest(button)
        }
        var savedFrame: CGRect?
        t.step("titlebar switcher: in a narrow window it stays 200pt at the right end; a strip either fits before it or stays in its deck; the dropdown stays inside", nil, {
            let strips = self.titlebarStripDecks.map(\.view.strip)
            return all(want("its width", button.frame.width, TitlebarSwitcherButton.width),
                       abs(button.frame.maxX - rightEnd()) < 0.5 ? nil : "it should end at \(rightEnd()), ends at \(button.frame.maxX)",
                       button.frame.minX >= self.sidebarToggle.frame.maxX ? nil : "it should never sit over the toggle",
                       strips.allSatisfy { $0.frame.width >= Self.titlebarStripMinWidth && $0.frame.maxX <= button.frame.minX - 8 + 0.5 }
                           ? nil : "a titlebar strip is too narrow or overlaps it: \(strips.map(\.frame))",
                       menu.isOpen ? nil : "the dropdown should stay open",
                       self.contentView.bounds.contains(menu.frame) ? nil : "the dropdown \(menu.frame) should stay inside the window \(self.contentView.bounds)")
        }) {
            guard let w = self.window else { return }
            savedFrame = w.frame
            var f = w.frame
            f.size.width = w.minSize.width
            w.setFrame(f, display: true)
            self.layoutNow()
        }
        t.step("titlebar switcher: opening the sidebar hides it and closes its dropdown; strips start after the toggle", nil, {
            all(shown() ? "it should hide with the sidebar open" : nil, menu.isOpen ? "the dropdown should close" : nil,
                button.isOpen ? "the button should no longer draw open" : nil,
                self.isSidebarVisible ? nil : "the sidebar should show",
                want("clear line", self.titlebarClearX, self.sidebarToggle.frame.maxX + 8))
        }) {
            if let f = savedFrame { self.window?.setFrame(f, display: true) }
            if !menu.isOpen { self.clickForTest(button) }
            self.toggleWorkspaceSidebar(nil)
        }
        t.step("titlebar switcher: never in top-bar mode, even with the sidebar hidden", nil, {
            all(shown() ? "the pills are the switcher in top-bar mode" : nil, self.workspaceBar.isHidden ? "the pills should show" : nil)
        }) {
            self.sidebarPreference = false
            Settings.workspaceSwitcher = .top
            self.layoutNow()
        }
        t.step("titlebar switcher: cleanup", nil, {
            all(self.workspaces.contains { $0.name?.hasPrefix("ts-") == true } ? "test workspaces should be gone" : nil,
                menu.isOpen ? "the dropdown should be closed" : nil, menu.rows.isEmpty ? nil : "a closed dropdown holds no rows")
        }) {
            Settings.workspaceSwitcher = .sidebar
            for ws in [alpha, beta, gamma].compactMap({ $0 }) + self.workspaces.filter({ $0.name == "ts-delta" }) { self.close(workspace: ws) }
            alpha = nil; beta = nil; gamma = nil
            if let saved = savedPreference { self.sidebarPreference = saved }
            if let saved = savedSettings {
                if let text = saved { try? text.write(to: Settings.fileURL, atomically: true, encoding: .utf8) }
                else { try? FileManager.default.removeItem(at: Settings.fileURL) }
                Settings.reload(force: true)
            }
            self.layoutNow()
        }
    }
}
