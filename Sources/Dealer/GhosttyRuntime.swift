import AppKit
import GhosttyKit

/// Owns the single `ghostty_app_t` and routes libghostty callbacks back into AppKit.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    /// Terminal background from the user's ghostty config, used to paint chrome behind surfaces.
    private(set) var backgroundColor = NSColor(srgbRed: 0.05, green: 0.055, blue: 0.07, alpha: 1)

    private init() {}

    func start() {
        // Borrow shell integration and terminfo from an installed Ghostty.app when we have one.
        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            let dir = "/Applications/Ghostty.app/Contents/Resources/ghostty"
            if FileManager.default.fileExists(atPath: dir) {
                setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
            }
        }

        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            fatalError("ghostty_init failed")
        }

        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        config = cfg

        var bg = ghostty_config_color_s()
        let key = "background"
        if ghostty_config_get(cfg, &bg, key, UInt(key.utf8.count)) {
            backgroundColor = NSColor(srgbRed: CGFloat(bg.r) / 255, green: CGFloat(bg.g) / 255, blue: CGFloat(bg.b) / 255, alpha: 1)
        }

        var rt = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { app, target, action in
                GhosttyRuntime.shared.handle(target: target, action: action)
            },
            read_clipboard_cb: { ud, loc, state in
                guard let view = SurfaceView.from(ud), let surface = view.surface else { return false }
                let str = NSPasteboard.general.string(forType: .string) ?? ""
                str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
                return true
            },
            confirm_read_clipboard_cb: { ud, str, state, _ in
                // No confirmation UI: accept the paste as-is.
                guard let view = SurfaceView.from(ud), let surface = view.surface else { return }
                ghostty_surface_complete_clipboard_request(surface, str, state, true)
            },
            write_clipboard_cb: { _, loc, content, len, _ in
                guard loc == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
                for i in 0..<len {
                    let item = content[i]
                    guard let mime = item.mime, let data = item.data else { continue }
                    if String(cString: mime) == "text/plain" {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(cString: data), forType: .string)
                        return
                    }
                }
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
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            ghostty_app_keyboard_changed(app)
        }
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

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let p = action.action.set_title.title else { return false }
            let title = String(cString: p)
            DispatchQueue.main.async { view.onTitle?(title) }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let p = action.action.pwd.pwd else { return false }
            view.pwd = String(cString: p)
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view.setCursorShape(action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            NSCursor.setHiddenUntilMouseMoves(!visible)
            return true

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

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
}
