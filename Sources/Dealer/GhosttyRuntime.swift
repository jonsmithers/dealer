import AppKit
import GhosttyKit

/// Owns the single `ghostty_app_t` and routes libghostty callbacks back into AppKit.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    /// The config in effect as loaded from disk: the launch config, replaced by every successful
    /// reload (#33). Conditional parts (`theme = light:…,dark:…`) are unresolved here; ghostty
    /// resolves them and reports the result through CONFIG_CHANGE, which is what `Theme` reads.
    private(set) var config: ghostty_config_t?
    /// Problems (ghostty's diagnostics) from the last load or refused reload, shown in the settings
    /// banner. Empty when the config in effect loaded cleanly.
    private(set) var configProblems: [String] = []
    /// Posted on main when `configProblems` changes.
    static let problemsDidChange = Notification.Name("DealerGhosttyConfigProblemsDidChange")
    /// The macOS appearance as last told to ghostty (#23, #33). New surfaces start with it.
    private(set) var colorScheme = GHOSTTY_COLOR_SCHEME_LIGHT
    private var appearanceObservation: NSKeyValueObservation?

    private init() {}

    func start() {
        // Borrow shell integration, terminfo and themes from an installed Ghostty.app (#39).
        GhosttyResources.apply()

        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            fatalError("ghostty_init failed")
        }
        GhosttyVersion.check()  // #35: is the linked libghostty the pinned commit?

        // At launch there is no previous config to keep, so a config with errors is used anyway
        // (ghostty skips the bad lines); its problems still go to the banner.
        let (cfg, problems) = Self.loadConfig()
        config = cfg
        setProblems(problems)
        if let cfg { Theme.load(cfg) }

        var rt = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { app, target, action in
                GhosttyRuntime.shared.handle(target: target, action: action)
            },
            read_clipboard_cb: { ud, loc, state, mimes, mimesLen, list in
                GhosttyClipboard.read(ud, location: loc, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { ud, confirm, state, request in
                GhosttyClipboard.confirmRead(ud, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { ud, loc, content, len, confirm in
                GhosttyClipboard.write(ud, location: loc, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { ud, _ in
                guard let view = SurfaceView.from(ud) else { return }
                DispatchQueue.main.async { view.onClose?() }
            }
        )

        guard let app = ghostty_app_new(&rt, cfg) else { fatalError("ghostty_app_new failed") }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            ghostty_app_set_focus(app, true)
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            ghostty_app_set_focus(app, false)
        }
        followSystemAppearance()
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            ghostty_app_keyboard_changed(app)
        }
    }

    // MARK: Config reload (#33)

    /// Self-test only: load this one file instead of ghostty's default files. libghostty snapshots
    /// the process environment at `ghostty_init` (zig 0.16), so a later `setenv("XDG_CONFIG_HOME")`
    /// no longer redirects it; and Dealer must not `setenv` after `ghostty_init` at all, because
    /// libghostty keeps pointing at the environ array that setenv may reallocate.
    static var configFileOverride: String?

    /// A fresh config from ghostty's default files (XDG and Application Support), finalized, with
    /// its diagnostics. Mirrors `Ghostty.Config.loadConfig` in Ghostty's macOS app.
    private static func loadConfig() -> (ghostty_config_t?, [String]) {
        guard let cfg = ghostty_config_new() else { return (nil, ["ghostty_config_new failed"]) }
        if let file = configFileOverride {
            ghostty_config_load_file(cfg, file)
        } else {
            ghostty_config_load_default_files(cfg)
        }
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        let problems = (0..<ghostty_config_diagnostics_count(cfg)).map { i -> String in
            ghostty_config_get_diagnostic(cfg, i).message.map { String(cString: $0) } ?? "unknown problem"
        }
        problems.forEach { NSLog("Dealer: ghostty config: \($0)") }
        return (cfg, problems)
    }

    /// Opens the ghostty config file in the default editor (the banner's button for its problems).
    static func openConfigFile() {
        let s = ghostty_config_open_path()
        defer { ghostty_string_free(s) }
        guard let ptr = s.ptr else { return }
        let path = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(s.len)), as: UTF8.self)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func setProblems(_ problems: [String]) {
        guard problems != configProblems else { return }
        configProblems = problems
        NotificationCenter.default.post(name: Self.problemsDidChange, object: nil)
    }

    /// Reloads the ghostty config from disk (⌘⇧, and ghostty's `reload_config` action). Returns
    /// false, keeping the config in effect, when the new one has errors; the banner shows them.
    /// `soft` re-applies the current config without reading the files (ghostty asks for that).
    @discardableResult
    func reloadConfig(soft: Bool = false) -> Bool {
        guard let app, let current = config else { return false }
        if soft {
            ghostty_app_update_config(app, current)
            return true
        }
        let (loaded, problems) = Self.loadConfig()
        guard let cfg = loaded, problems.isEmpty else {
            if let loaded { ghostty_config_free(loaded) }
            setProblems(problems)
            return false
        }
        // Updates the app and every surface: the terminals repaint in place, processes untouched.
        // ghostty answers synchronously with CONFIG_CHANGE (the resolved config), which re-themes
        // the chrome (`configChanged`). It copies what it keeps, so the old config can go.
        ghostty_app_update_config(app, cfg)
        config = cfg
        ghostty_config_free(current)
        setProblems([])
        return true
    }

    // MARK: Following the macOS appearance (#23)

    /// Tells ghostty the system's light/dark appearance, now and whenever it changes, so a
    /// conditional `theme = light:X,dark:Y` follows it. Ghostty answers a change with a soft
    /// `reload_config`, which re-themes the terminals and the chrome.
    private func followSystemAppearance() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { app, _ in
            let dark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            DispatchQueue.main.async { GhosttyRuntime.shared.setColorScheme(dark: dark) }
        }
    }

    /// The app's scheme drives the app config (and so the chrome); each surface resolves its own
    /// config with its own scheme, so they're all told too.
    func setColorScheme(dark: Bool) {
        guard let app else { return }
        let scheme = dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        colorScheme = scheme
        for (_, p) in Pane.all { if let s = p.surface.surface { ghostty_surface_set_color_scheme(s, scheme) } }
        ghostty_app_set_color_scheme(app, scheme)
    }

    func tick() {
        if let app { ghostty_app_tick(app) }
    }

    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }

    // MARK: Actions

    private func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if target.tag == GHOSTTY_TARGET_APP {
            switch action.tag {
            case GHOSTTY_ACTION_QUIT:
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return true
            case GHOSTTY_ACTION_NEW_WINDOW:
                DispatchQueue.main.async { AppDelegate.shared.newWindow(nil) }
                return true
            case GHOSTTY_ACTION_RELOAD_CONFIG:
                return reloadAction(soft: action.action.reload_config.soft)
            case GHOSTTY_ACTION_CONFIG_CHANGE:
                return configChanged(action.action.config_change.config)
            default:
                return false
            }
        }

        guard let surface = target.target.surface,
              let view = SurfaceView.from(ghostty_surface_userdata(surface)) else { return false }

        // Layout actions coming from the user's ghostty keybinds map onto our own commands.
        let run: (@escaping (TerminalWindowController) -> Void) -> Bool = { body in
            DispatchQueue.main.async {
                guard let wc = view.window?.windowController as? TerminalWindowController else { return }
                body(wc)
            }
            return true
        }

        // Attention sources: like `run`, but a dropped event is logged (#56): the pane is gone, or its view has no
        // window controller (a restored workspace that hasn't been shown yet).
        let mark: (String, @escaping (TerminalWindowController, Pane) -> Void) -> Bool = { event, body in
            DispatchQueue.main.async {
                guard let pane = view.pane else {
                    return NotificationLog.decision(pane: nil, event: event, outcome: "attention:skipped",
                                                    reason: "the terminal has no pane any more")
                }
                guard let wc = view.window?.windowController as? TerminalWindowController else {
                    return NotificationLog.decision(pane: pane, event: event, outcome: "attention:skipped",
                                                    reason: "the pane's view isn't in a window yet (a workspace not shown since launch?); no mark, no notification")
                }
                body(wc, pane)
            }
            return true
        }

        switch action.tag {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // The `reload_config` keybind. Dealer has one config for every surface, so a surface's
            // reload is the app-wide one (the same command as ⌘⇧,).
            return reloadAction(soft: action.action.reload_config.soft)

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Per-surface echo of an app config change; the app-level one re-themes the chrome.
            return true

        // Find in pane (#49, SearchBar.swift). Ghostty searches; we show the bar and the counts.
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) }
            DispatchQueue.main.async { view.pane?.view.startSearch(needle: needle) }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            DispatchQueue.main.async { view.pane?.view.endSearch() }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            DispatchQueue.main.async { view.pane?.view.searchBar?.total = total >= 0 ? Int(total) : nil }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            DispatchQueue.main.async { view.pane?.view.searchBar?.selected = selected >= 0 ? Int(selected) : nil }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let p = action.action.set_title.title else { return false }
            let title = String(cString: p)
            DispatchQueue.main.async { view.onTitle?(title) }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let p = action.action.pwd.pwd else { return false }
            let pwd = String(cString: p)
            guard pwd != view.pwd else { return true }
            view.pwd = pwd
            // The pane status line shows the cwd and git branch.
            return run { $0.refreshChrome() }

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            // OSC 9;4. Agents such as Claude Code report progress while they work: "running".
            let active = action.action.progress_report.state != GHOSTTY_PROGRESS_STATE_REMOVE
                && action.action.progress_report.state != GHOSTTY_PROGRESS_STATE_ERROR
            return run { wc in
                guard let pane = view.pane, pane.isReportingProgress != active else { return }
                pane.isReportingProgress = active
                wc.refreshChrome()
            }

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view.setCursorShape(action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            NSCursor.setHiddenUntilMouseMoves(!visible)
            return true

        // Attention sources (see Attention.swift). Each marks the pane unless the user is looking at it.
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return mark("bell") { wc, pane in wc.setAttention(.unread, on: pane, raiseOnly: true, event: "bell") }

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // OSC 9 / OSC 99 / OSC 777.
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) }
            let body = n.body.map { String(cString: $0) }
            return mark("osc-notification") { wc, pane in
                wc.setAttention(.unread, on: pane, raiseOnly: true, title: title, body: body, event: "osc-notification")
            }

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            // Needs shell integration. See TerminalWindowController.commandFinished (Attention.swift).
            let f = action.action.command_finished
            let exit = Int(f.exit_code), duration = f.duration
            let event = "command-finished(exit=\(exit),\(TerminalWindowController.seconds(duration)))"
            guard TerminalWindowController.commandFinishedAttention(exitCode: exit, durationNs: duration) != nil else {
                if NotificationLog.isEnabled {
                    let why = exit > 0 ? "a failure, but [attention] failed_commands is off"
                                       : "a success under 10 s marks nothing"
                    DispatchQueue.main.async {
                        NotificationLog.decision(pane: view.pane, event: event, outcome: "ignored", reason: why)
                    }
                }
                return false
            }
            return mark(event) { wc, pane in wc.commandFinished(pane, exitCode: exit, durationNs: duration) }

        case GHOSTTY_ACTION_NEW_TAB:
            return run { $0.newTab(nil) }

        case GHOSTTY_ACTION_NEW_SPLIT:
            let dir = action.action.new_split
            return run { wc in
                guard let pane = view.pane else { return }
                switch dir {
                case GHOSTTY_SPLIT_DIRECTION_LEFT: wc.split(pane, side: .left)
                case GHOSTTY_SPLIT_DIRECTION_UP: wc.split(pane, side: .top)
                case GHOSTTY_SPLIT_DIRECTION_DOWN: wc.split(pane, side: .bottom)
                default: wc.split(pane, side: .right)
                }
            }

        case GHOSTTY_ACTION_GOTO_TAB:
            let n = action.action.goto_tab
            return run { wc in
                switch n {
                case GHOSTTY_GOTO_TAB_PREVIOUS: wc.previousTab(nil)
                case GHOSTTY_GOTO_TAB_NEXT: wc.nextTab(nil)
                case GHOSTTY_GOTO_TAB_LAST: wc.gotoTab(index: Int.max)
                default: wc.gotoTab(index: Int(n.rawValue) - 1)
                }
            }

        case GHOSTTY_ACTION_GOTO_SPLIT:
            let dir = action.action.goto_split
            return run { wc in
                switch dir {
                case GHOSTTY_GOTO_SPLIT_LEFT: wc.moveFocus(.left)
                case GHOSTTY_GOTO_SPLIT_RIGHT: wc.moveFocus(.right)
                case GHOSTTY_GOTO_SPLIT_UP: wc.moveFocus(.top)
                case GHOSTTY_GOTO_SPLIT_DOWN: wc.moveFocus(.bottom)
                default: break
                }
            }

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            return run { $0.toggleZoom(nil) }

        case GHOSTTY_ACTION_CLOSE_TAB:
            return run { $0.closeTab(nil) }

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            return run { $0.window?.performClose(nil) }

        default:
            return false
        }
    }

    private func reloadAction(soft: Bool) -> Bool {
        // On the main run loop in default mode (like `ControlServer.onMain`), not the main queue:
        // the action can arrive inside a main-queue block that spins the run loop (the self-test).
        Self.onMainRunLoop {
            if soft { GhosttyRuntime.shared.reloadConfig(soft: true) } else { AppDelegate.shared.reloadConfiguration(nil) }
        }
        return true
    }

    /// The app config changed (any reload, or a color-scheme switch): re-theme the chrome from the
    /// resolved config. The pointer is only valid during the callback, so off main it's copied.
    private func configChanged(_ cfg: ghostty_config_t?) -> Bool {
        guard let cfg else { return true }
        if Thread.isMainThread {
            Theme.reload(cfg)
        } else if let copy = ghostty_config_clone(cfg) {
            Self.onMainRunLoop { Theme.reload(copy); ghostty_config_free(copy) }
        }
        return true
    }

    private static func onMainRunLoop(_ body: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue, body)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
