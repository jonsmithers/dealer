import AppKit

/// Finds the Ghostty resources directory (shell integration, themes; terminfo sits next to it)
/// that libghostty reads from `GHOSTTY_RESOURCES_DIR` (#39, #41).
///
/// Order, first valid wins (valid = has a `shell-integration/` directory):
/// 1. `DEALER_GHOSTTY_RESOURCES_DIR`, the explicit override: used as given, and empty means none.
/// 2. This app's own `Contents/Resources/ghostty`, which `bundle.sh` copies from the pinned build.
/// 3. Self-test mode only: `vendor/ghostty-resources/ghostty` of this source tree, then of the main
///    checkout (worktrees), written by `build-ghosttykit.sh` from the pinned build.
/// 4. `GHOSTTY_RESOURCES_DIR` inherited from the environment, outside self-test mode. Every Ghostty
///    or Dealer pane exports one, possibly from another Ghostty version, so it ranks below the
///    bundle and is ignored by the self-test. Use the override to force a directory.
/// 5. The app Launch Services knows as `com.mitchellh.ghostty`, then `/Applications` and
///    `~/Applications` (for bundles made before #41 and plain `.build` runs).
enum GhosttyResources {
    static let variable = "GHOSTTY_RESOURCES_DIR"
    static let overrideVariable = "DEALER_GHOSTTY_RESOURCES_DIR"
    static let bundleIdentifier = "com.mitchellh.ghostty"

    enum Source: String {
        case override = "DEALER_GHOSTTY_RESOURCES_DIR"
        case appBundle = "this app's bundle"
        case vendored = "vendor/ghostty-resources (self-test)"
        case inherited = "the inherited GHOSTTY_RESOURCES_DIR"
        case registeredApp = "the Ghostty.app Launch Services knows"
        case applicationsFolder = "an Applications folder"
    }

    struct Resolution: Equatable {
        /// The directory to use, or nil for none.
        var path: String?
        var source: Source?
        /// Candidates looked at and rejected (no `shell-integration/`), in order.
        var rejected: [String] = []
    }

    /// `Contents/Resources/ghostty` of an app bundle.
    static func resourcesDirectory(inApp app: URL) -> String {
        app.appendingPathComponent("Contents/Resources/ghostty").path
    }

    static func isValid(_ dir: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir + "/shell-integration", isDirectory: &isDir) && isDir.boolValue
    }

    /// The lookup itself, free of process state so the self-test can drive it with temp dirs.
    /// Each argument is one rung of the order above; nil skips it.
    static func resolve(override: String? = nil, bundled: String? = nil, vendored: [String] = [],
                        inherited: String? = nil, registeredApp: URL?, applicationFolders: [URL]) -> Resolution {
        if let override {
            // The user decided; empty deliberately means no resources (libghostty ignores it).
            return Resolution(path: override.isEmpty ? nil : override, source: .override)
        }
        var candidates: [(Source, String)] = []
        if let bundled { candidates.append((.appBundle, bundled)) }
        candidates += vendored.map { (.vendored, $0) }
        if let inherited, !inherited.isEmpty { candidates.append((.inherited, inherited)) }
        if let registeredApp { candidates.append((.registeredApp, resourcesDirectory(inApp: registeredApp))) }
        for folder in applicationFolders {
            candidates.append((.applicationsFolder, resourcesDirectory(inApp: folder.appendingPathComponent("Ghostty.app"))))
        }
        var result = Resolution()
        var seen = Set<String>()
        for (source, dir) in candidates where seen.insert(dir).inserted {
            if isValid(dir) { result.path = dir; result.source = source; return result }
            result.rejected.append(dir)
        }
        return result
    }

    /// What `apply()` decided for this process.
    private(set) static var current: Resolution?

    /// Resolves for this process and sets `GHOSTTY_RESOURCES_DIR`. Called once, before `ghostty_init`.
    @discardableResult
    static func apply() -> Resolution {
        let env = ProcessInfo.processInfo.environment
        let vendored = SelfTest.enabled ? vendoredDirectories() : []
        if SelfTest.enabled, env[overrideVariable] == nil, !vendored.contains(where: isValid) {
            NSLog("Dealer: self-test: no vendor/ghostty-resources (scripts/build-ghosttykit.sh writes it); "
                  + "falling back to an installed Ghostty's resources")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let r = resolve(override: env[overrideVariable],
                        bundled: Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
                        vendored: vendored,
                        inherited: SelfTest.enabled ? nil : env[variable],
                        registeredApp: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
                        applicationFolders: [URL(fileURLWithPath: "/Applications"),
                                             home.appendingPathComponent("Applications")])
        // libghostty reads the variable, and treats an empty one as unset.
        setenv(variable, r.path ?? "", 1)
        switch (r.source, r.path) {
        case (.override, nil):
            NSLog("Dealer: DEALER_GHOSTTY_RESOURCES_DIR is empty: running without Ghostty's shell integration, terminfo and themes")
        case (.override, let path?):
            if !isValid(path) {
                NSLog("Dealer: DEALER_GHOSTTY_RESOURCES_DIR=%@ has no shell-integration/; using it anyway", path)
            }
        case (let source?, let path?):
            NSLog("Dealer: Ghostty resources: %@ (from %@)", path, source.rawValue)
        default:
            NSLog("Dealer: no Ghostty resources found (looked in %@). Shell integration, terminfo and "
                  + "bundled themes are unavailable: new panes won't follow the shell's directory and "
                  + "a `theme =` naming a Ghostty theme won't load. Rebuild with scripts/bundle.sh, "
                  + "install Ghostty.app, or set DEALER_GHOSTTY_RESOURCES_DIR.",
                  r.rejected.joined(separator: ", "))
        }
        current = r
        return r
    }

    /// `vendor/ghostty-resources/ghostty` of the source tree this binary was built from, then of
    /// the main checkout when that tree is a git worktree (whose vendor/ usually only links the
    /// framework). Only meaningful for builds run in place (self-test).
    static func vendoredDirectories() -> [String] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var roots = [repo]
        // In a worktree, .git is a file: "gitdir: <main>/.git/worktrees/<name>".
        if let text = try? String(contentsOf: repo.appendingPathComponent(".git"), encoding: .utf8),
           text.hasPrefix("gitdir: ") {
            let gitdir = URL(fileURLWithPath: text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines))
            roots.append(gitdir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        }
        return roots.map { $0.appendingPathComponent("vendor/ghostty-resources/ghostty").path }
    }
}
