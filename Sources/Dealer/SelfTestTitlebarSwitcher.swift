import AppKit

// MARK: - Self-test section: the titlebar workspace switcher (#96, TitlebarSwitcher.swift)
//
// Self-contained (`DEALER_SELFTEST_ONLY=titlebar switcher:`). With the sidebar hidden, a button right
// of the sidebar toggle names the current workspace; a click opens the dropdown, a row's click
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
        /// Strips in the titlebar start after the button (#16's clear line), and nothing overlaps it.
        func stripsClear(of v: NSView) -> String? {
            let strips = titlebarStripDecks.map(\.view.strip)
            if strips.isEmpty { return "a top deck's strip should be in the titlebar" }
            for s in strips where s.frame.minX < v.frame.maxX || s.frame.intersects(v.frame) {
                return "a titlebar strip \(s.frame) overlaps \(v === button ? "the switcher" : "the toggle") \(v.frame)"
            }
            return want("clear line", titlebarClearX, v.frame.maxX + 8)
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
        t.step("titlebar switcher: hiding the sidebar shows it right of the toggle, named after the workspace; strips start after it", nil, {
            all(shown() ? nil : "the titlebar switcher should show with the sidebar hidden",
                want("its title", button.title, "ts-alpha"),
                button.frame.minX >= self.sidebarToggle.frame.maxX ? nil : "it should sit right of the toggle",
                abs(button.frame.midY - self.sidebarToggle.frame.midY) < 0.5 ? nil : "it should share the toggle's row",
                button.frame.width <= TitlebarSwitcherButton.maxWidth ? nil : "it should be capped at maxWidth",
                // #27: the window server must hand titlebar presses on it to the app.
                button.mouseDownCanMoveWindow ? "mouseDownCanMoveWindow must be false (#27)" : nil,
                self.contentView.hitTest(self.contentView.superview!.convert(center(button), from: nil)) === button ? nil : "a click at its centre should hit it",
                stripsClear(of: button))
        }) {
            self.toggleWorkspaceSidebar(nil)
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
                       self.window?.firstResponder === menu ? nil : "the dropdown should take the keys")
        }) {
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
            // Opens on ts-alpha's row (the current one), so the next one down is ts-beta, then ts-gamma.
            self.clickForTest(button)
            key(125, "\u{F701}")
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
        t.step("titlebar switcher: opening the sidebar hides it and closes its dropdown; strips start after the toggle", nil, {
            all(shown() ? "it should hide with the sidebar open" : nil, menu.isOpen ? "the dropdown should close" : nil,
                button.isOpen ? "the button should no longer draw open" : nil,
                self.isSidebarVisible ? nil : "the sidebar should show",
                want("clear line", self.titlebarClearX, self.sidebarToggle.frame.maxX + 8))
        }) {
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
            self.layoutNow()
        }
    }
}
