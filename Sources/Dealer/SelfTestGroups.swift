import AppKit

// MARK: - Self-test section: workspace groups (#80)
//
// Self-contained: starts from the one home workspace, adds three, groups them, and goes back.

extension TerminalWindowController {
    /// The switcher order as text: `a [G: b c] d`, `+` after a collapsed group's name, `*` on the
    /// active workspace. A group split in two would show twice.
    func describeGroups() -> String {
        var out: [String] = [], i = 0
        let ws = workspaces
        func n(_ w: Workspace) -> String { (w === activeWorkspace ? "*" : "") + (w.name ?? "?") }
        while i < ws.count {
            if let g = ws[i].group {
                let run = ws[i...].prefix { $0.group === g }
                out.append("[\(g.name)\(g.isCollapsed ? "+" : ""): \(run.map(n).joined(separator: " "))]")
                i += run.count
            } else {
                out.append(n(ws[i]))
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    func groupsSelfTestSteps(_ t: SelfTestKit) {
        let sb = workspaceSidebar
        let bar = workspaceBar
        var home: Workspace?
        var homeName: String?
        func ws(_ name: String) -> Workspace { workspaces.first { $0.name == name }! }
        func group() -> WorkspaceGroup? { groups.first }
        func expect(_ e: String) -> String? {
            let got = describeGroups()
            return got == e ? nil : "expected \(e)\n         got      \(got)"
        }
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func rowView(_ name: String) -> NSView? { index(of: ws(name)).flatMap { sb.row(at: $0) } }
        func pill(_ name: String) -> NSView? { index(of: ws(name)).flatMap { bar.button(at: $0) } }
        func center(_ v: NSView?) -> CGPoint {
            guard let v else { return .zero }
            return v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        }
        /// A window point in the gap just above `v` (sidebar rows).
        func gapAbove(_ v: NSView?) -> CGPoint {
            guard let v, let s = v.superview else { return .zero }
            return s.convert(CGPoint(x: v.frame.midX, y: v.frame.minY - 1), to: nil)
        }
        func shown(_ v: NSView?) -> Bool { v.map { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.frame.height > 0 } ?? false }

        t.step("groups: Move to New Group puts a workspace in a group where it was, indented under a header", nil, {
            guard let g = group(), let h = sb.header(for: g) else { return "no group header" }
            return all(expect("a [Group: b] *c d"),
                       shown(h) ? nil : "the header should show",
                       h.frame.maxY <= (rowView("b")?.frame.minY ?? 0) ? nil : "the header should sit above its member",
                       abs((rowView("b")?.frame.minX ?? 0) - Theme.Metrics.groupIndent) < 0.5 ? nil : "the member's row should be indented",
                       rowView("a")?.frame.minX == 0 ? nil : "a root row should not be indented")
        }) {
            home = self.workspaces.first
            homeName = home?.name
            if let home { self.rename(workspace: home, to: "a") }
            for n in ["b", "c", "d"] { self.rename(workspace: self.newWorkspace(), to: n) }
            self.activate(ws("c"))
            self.sidebarPreference = true
            self.moveToNewGroup(ws("b"))
            self.layoutNow()
        }
        t.step("groups: a row dragged onto a group's header joins the group (sidebar drag)", nil, {
            expect("a [Group: b *c] d")
        }) {
            guard let g = group() else { return }
            self.dragForTest(rowView("c")!, to: center(sb.header(for: g)))
            self.layoutNow()
        }
        t.step("groups: the drop marker is indented between members and not between root rows", nil, {
            guard let c = rowView("c"), let d = rowView("d") else { return "rows missing" }
            sb.showDropMarker(sb.drop(for: .workspace(ws("a")), at: gapAbove(c)))
            let inside = sb.markerFrameForTest
            sb.showDropMarker(sb.drop(for: .workspace(ws("a")), at: gapAbove(d)))
            let outside = sb.markerFrameForTest
            sb.showDropMarker(nil)
            return all((inside?.minX ?? 0) > Theme.Metrics.groupIndent ? nil : "between members: marker at \(String(describing: inside))",
                       (outside?.minX ?? 99) < Theme.Metrics.groupIndent ? nil : "after the group: marker at \(String(describing: outside))",
                       sb.drop(for: .workspace(ws("a")), at: gapAbove(c))?.group === group() ? nil : "a gap between members should mean the group",
                       sb.drop(for: .workspace(ws("a")), at: gapAbove(d))?.group == nil ? nil : "the gap after the last member should mean the root")
        }) {}
        t.step("groups: a member dropped between root rows leaves the group", nil, {
            expect("a [Group: c] *b d")
        }) {
            self.dragForTest(rowView("b")!, to: gapAbove(rowView("d")))
            self.layoutNow()
        }
        t.step("groups: a root row dropped between a header and its first member joins at the top", nil, {
            expect("a [Group: *d c] b")
        }) {
            self.dragForTest(rowView("d")!, to: gapAbove(rowView("c")))
            self.layoutNow()
        }
        t.step("groups: rename shows on the header; an empty name goes back to the default", nil, {
            guard let g = group() else { return "no group" }
            return all(expect("a [Proj: *d c] b"), sb.header(for: g)?.title == "Proj" ? nil : "the header should read Proj")
        }) {
            guard let g = group() else { return }
            self.rename(group: g, to: "  ")
            if g.name != "Group" { self.rename(workspace: ws("a"), to: "empty rename gave \(g.name)") }
            self.rename(group: g, to: " Proj ")
            self.layoutNow()
        }
        t.step("groups: a click on the header collapses it; members' rows hide, the header counts them", nil, {
            guard let g = group(), let h = sb.header(for: g) else { return "no header" }
            return all(expect("a [Proj+: *d c] b"),
                       !shown(rowView("c")) && !shown(rowView("d")) ? nil : "members should be hidden",
                       h.count == 2 ? nil : "count \(h.count)",
                       h.isActive ? nil : "the header should carry the selected outline while the active workspace is inside",
                       shown(rowView("b")) && (rowView("b")?.frame.minY ?? 0) > h.frame.maxY ? nil : "b should follow the header",
                       sb.dropTarget(at: CGPoint(x: h.frame.midX, y: h.frame.midY)) == nil ? nil : "a header is no drop target")
        }) {
            guard let g = group(), let h = sb.header(for: g) else { return }
            self.clickForTest(h)
            self.layoutNow()
        }
        t.step("groups: ⌃N counts every workspace, collapsed or not, and switching into a collapsed group doesn't expand it", nil, {
            all(expect("a [Proj+: d *c] b"),
                (0..<self.workspaces.count).allSatisfy { (sb.row(at: $0) as? WorkspaceRow)?.number == "\($0 + 1)" } ? nil : "row numbers should follow the flat order",
                (rowView("b") as? WorkspaceRow)?.number == "4" ? nil : "b should be ⌃4")
        }) {
            self.activateWorkspace(index: 2)
            self.layoutNow()
        }
        t.step("groups: a collapsed header rolls its members' attention up, strongest first (failed > waiting > done)", nil, {
            guard let g = group(), let h = sb.header(for: g) else { return "no header" }
            var p: [String?] = []
            let pd = ws("d").panes[0], pc = ws("c").panes[0]
            self.setAttention(.done, on: pd); self.refreshChrome()
            p.append(h.attention == .done ? nil : "done → header \(h.attention)")
            self.setAttention(.waiting, on: pc); self.refreshChrome()
            p.append(h.attention == .waiting && PixelProbe.isWaitingOutlined(h) ? nil : "waiting → header \(h.attention), outlined \(PixelProbe.isWaitingOutlined(h))")
            self.setAttention(.failed, on: pd); self.refreshChrome()
            p.append(h.attention == .failed && PixelProbe.isFailedOutlined(h) ? nil : "failed → header \(h.attention)")
            self.toggleCollapsed(g)
            p.append(h.attention == .none ? nil : "expanded, the header should carry no attention (\(h.attention))")
            p.append((rowView("d") as? WorkspaceRow)?.attention == .failed ? nil : "the member row should show its own")
            self.toggleCollapsed(g)
            self.clearAttention(pd, cause: "selftest"); self.clearAttention(pc, cause: "selftest")
            self.refreshChrome()
            p.append(h.attention == .none ? nil : "cleared → header \(h.attention)")
            return all(p.compactMap { $0 }.isEmpty ? nil : p.compactMap { $0 }.joined(separator: "; "))
        }) {
            self.activate(ws("a"))
        }
        t.step("groups: clicking the collapsed header expands it again", nil, {
            all(expect("*a [Proj: d c] b"), shown(rowView("c")) && shown(rowView("d")) ? nil : "members should show")
        }) {
            guard let g = group(), let h = sb.header(for: g) else { return }
            self.clickForTest(h)
            self.layoutNow()
        }
        t.step("groups: a dragged header moves the whole group, only between root entries", nil, {
            expect("*a b [Proj: d c]")
        }) {
            guard let g = group(), let h = sb.header(for: g) else { return }
            // Below b, the last row.
            let below = rowView("b")!.superview!.convert(CGPoint(x: 40, y: rowView("b")!.frame.maxY - 2), to: nil)
            self.dragForTest(h, to: below)
            self.layoutNow()
        }
        t.step("groups: Move Workspace Left/Right steps over a whole group, and a member steps out past its group's end", nil, {
            expect("[Proj: d c] *b a")
        }) {
            self.activate(ws("b"))
            self.step(ws("b"), by: -1)      // a b [d c] → b a [d c]
            self.step(ws("a"), by: 1)       // a over the group → b [d c] a
            self.step(ws("b"), by: 1)       // b over the group → [d c] b a
            self.step(ws("c"), by: 1)       // c is the group's last member: out, right after it
            self.step(ws("c"), by: -1)      // a root c steps over the whole group…
            self.move(ws("c"), toGroup: group())  // …and Move to Group puts it back at the end
        }
        t.step("groups: a new workspace made from inside an expanded group joins it; from a collapsed one it doesn't", nil, {
            expect("[Proj+: d c e] *f b a")
        }) {
            self.activate(ws("c"))
            self.rename(workspace: self.newWorkspace(), to: "e")
            if let g = group() { self.setCollapsed(g, true) }
            self.activate(ws("c"))          // mid-group: the new one still lands after the group
            self.rename(workspace: self.newWorkspace(), to: "f")
        }
        t.step("groups: top-bar mode shows a collapsed group as one label pill; a click expands it into a labelled run", nil, {
            guard let g = group(), let l = bar.label(for: g) else { return "no label pill" }
            return all(expect("[Proj: d c e] *f b a"),
                       shown(l) && !l.isCollapsed ? nil : "the label should show, expanded",
                       [pill("d"), pill("c"), pill("e")].allSatisfy { shown($0) && $0!.frame.minX > l.frame.maxX } ? nil : "members should follow the label",
                       bar.contentWidth >= (pill("a")?.frame.maxX ?? .infinity) ? nil : "contentWidth should cover every pill",
                       bar.dropTarget(at: CGPoint(x: l.frame.midX, y: l.frame.midY)) == nil ? nil : "a label is no drop target")
        }) {
            Settings.workspaceSwitcher = .top
            self.layoutNow()
            if let g = group(), let l = bar.label(for: g), shown(l), shown(pill("d")) {
                self.rename(workspace: ws("a"), to: "collapsed group's members are showing")
            }
            if let g = group(), let l = bar.label(for: g) { self.clickForTest(l) }
            self.layoutNow()
        }
        t.step("groups: a pill dragged onto a group's label joins it (top bar)", nil, {
            expect("[Proj: d c e *b] f a")
        }) {
            guard let g = group(), let l = bar.label(for: g), let b = pill("b") else { return }
            self.dragForTest(b, to: center(l))
            self.layoutNow()
        }
        t.step("groups: dealer list shows the group", nil, {
            let r = ControlHandler.handle(["cmd": "list"])
            let wins = (r["result"] as? [String: Any])?["windows"] as? [[String: Any]] ?? []
            let wss = wins.flatMap { $0["workspaces"] as? [[String: Any]] ?? [] }
            let names = wss.compactMap { ($0["group"] as? [String: Any])?["name"] as? String }
            return names == ["Proj", "Proj", "Proj", "Proj"] ? nil : "list groups: \(names) of \(wss.count) workspaces"
        }) {
            Settings.workspaceSwitcher = .sidebar
            self.layoutNow()
        }
        t.step("groups: groups, membership and collapsed state round-trip through the session; old files load; an older build reads the new file", nil, {
            guard let g = group() else { return "no group" }
            self.setCollapsed(g, true)
            defer { self.setCollapsed(g, false) }
            guard let snap = self.snapshot(), let data = try? JSONEncoder().encode(snap),
                  let back = try? JSONDecoder().decode(WindowSnapshot.self, from: data) else { return "encode failed" }
            var p: [String?] = []
            p.append(back.groups?.count == 1 && back.groups?[0].name == "Proj" && back.groups?[0].collapsed == true ? nil : "groups: \(String(describing: back.groups))")
            p.append(back.allWorkspaces.map { $0.group.map(String.init) ?? "-" } == ["0", "0", "0", "0", "-", "-"] ? nil
                     : "membership: \(back.allWorkspaces.map { $0.group.map(String.init) ?? "-" })")
            // An older build: the same file through master's shape of the snapshot.
            struct OldWindow: Decodable { var workspaces: [OldWorkspace]?; var activeWorkspace: Int? }
            struct OldWorkspace: Decodable { var name: String? }
            let old = try? JSONDecoder().decode(OldWindow.self, from: data)
            p.append(old?.workspaces?.compactMap(\.name) == self.workspaces.compactMap(\.name) ? nil : "an older build should read every workspace")
            // A file from an older build: no group fields.
            if var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], var wss = obj["workspaces"] as? [[String: Any]] {
                obj["groups"] = nil
                for i in wss.indices { wss[i]["group"] = nil }
                obj["workspaces"] = wss
                let legacy = (try? JSONSerialization.data(withJSONObject: obj)).flatMap { try? JSONDecoder().decode(WindowSnapshot.self, from: $0) }
                p.append(legacy?.allWorkspaces.count == 6 && legacy?.groups == nil ? nil : "a file without groups should load all workspaces, ungrouped")
                // A crafted file with a split group and a bad index.
                wss = obj["workspaces"] as! [[String: Any]]
                wss[0]["group"] = 0; wss[5]["group"] = 0; wss[4]["group"] = 7
                obj["workspaces"] = wss
                obj["groups"] = [["name": "Split", "collapsed": false]]
                if let crafted = (try? JSONSerialization.data(withJSONObject: obj)).flatMap({ try? JSONDecoder().decode(WindowSnapshot.self, from: $0) }) {
                    let restored = Workspace.contiguousGroups(self.restoreWorkspaces(crafted))
                    let shape = restored.map { ($0.group?.name ?? "-") + ":" + ($0.name ?? "?") }
                    p.append(shape == ["Split:d", "Split:a", "-:c", "-:e", "-:b", "-:f"] ? nil : "crafted file restored as \(shape)")
                    restored.flatMap(\.panes).forEach { $0.view.removeFromSuperview() }
                } else { p.append("crafted file didn't decode") }
            }
            let restored = self.restoreWorkspaces(back)
            let rg = restored.compactMap(\.group)
            p.append(rg.count == 4 && rg.allSatisfy({ $0 === rg[0] }) && rg.first?.isCollapsed == true && rg.first?.name == "Proj" ? nil
                     : "restore should rebuild one collapsed group of four")
            restored.flatMap(\.panes).forEach { $0.view.removeFromSuperview() }
            let q = p.compactMap { $0 }
            return q.isEmpty ? nil : q.joined(separator: "; ")
        }) {}
        t.step("groups: a group disappears when it loses its last workspace", nil, {
            all(expect("d *f a"), self.groups.isEmpty ? nil : "no group should be left",
                sb.subviews.contains { $0 is GroupHeaderView } ? "a header is left in the sidebar" : nil)
        }) {
            self.remove(workspace: ws("c"))
            self.move(ws("e"), toGroup: nil)
            self.remove(workspace: ws("e"))
            self.activate(ws("f"))
            self.remove(workspace: ws("b"))
            self.ungroup(group()!)          // the last member, d, by Ungroup
            self.layoutNow()
        }
        t.step("groups: clean up", nil, {
            self.workspaces.count == 1 && self.groups.isEmpty ? nil : "expected one workspace, no groups"
        }) {
            self.sidebarPreference = nil
            if let home {
                self.activate(home)
                self.workspaces.filter { $0 !== home }.forEach { self.remove(workspace: $0) }
                self.rename(workspace: home, to: homeName)
            }
            self.layoutNow()
        }
    }
}
