import AppKit
import GhosttyKit

// MARK: - Self-test section: no custom shaders in self-test and demo runs (#77, DemoShader)

extension TerminalWindowController {
    /// A ghostty config that sets `custom-shader` and `custom-shader-animation = always`, reloaded
    /// through the real path, comes out with the animation back at its default `true`: proof that
    /// `DemoShader`'s override loads after the user's files. ghostty's C API can't read the
    /// `custom-shader` list itself (`ghostty_config_get` returns false for it, checked here so a
    /// future libghostty that can read it gets noticed); the override empties it with
    /// `custom-shader =` on the line before. Self-contained (`DEALER_SELFTEST_ONLY=shaders:`).
    func demoShaderSelfTestSteps(_ t: SelfTestKit) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dealer-selftest-shaders-\(getpid())", isDirectory: true)
        var reloaded = false

        func animation() -> String? {
            guard let cfg = GhosttyRuntime.shared.config else { return nil }
            var v: UnsafePointer<CChar>?
            let key = "custom-shader-animation"
            return ghostty_config_get(cfg, &v, key, UInt(key.utf8.count)) ? v.map { String(cString: $0) } : nil
        }

        t.step("shaders: a config's custom-shader and custom-shader-animation = always don't survive a self-test reload", nil, {
            guard let cfg = GhosttyRuntime.shared.config else { return "no config" }
            var paths = ghostty_config_path_s(path: nil, optional: false)
            let key = "custom-shader"
            let readable = ghostty_config_get(cfg, &paths, key, UInt(key.utf8.count))
            let anim = animation()
            let override = DemoShader.overrideText(shader: "/x/demo.glsl").split(separator: "\n").map(String.init)
            return [reloaded ? nil : "the test config didn't load (reload refused: \(GhosttyRuntime.shared.configProblems))",
                    DemoShader.ignoresUserShaders ? nil : "the self-test should ignore the user's shaders",
                    anim == "true" ? nil : "custom-shader-animation is \(anim.map { "\"\($0)\"" } ?? "unreadable"), want the default \"true\"",
                    readable ? "ghostty_config_get can read custom-shader now: check the list is empty here" : nil,
                    DemoShader.demoShader == nil ? nil : "the self-test must not use the demo shader",
                    override.firstIndex(of: "custom-shader =").flatMap { r in override.firstIndex(of: "custom-shader = /x/demo.glsl").map { r < $0 } } == true
                        ? nil : "a demo shader must come after the reset: \(override)"]
                .compactMap { $0 }.first
        }) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let shader = dir.appendingPathComponent("tint.glsl")
            try? """
            void mainImage(out vec4 fragColor, in vec2 fragCoord) {
                fragColor = texture(iChannel0, fragCoord / iResolution.xy) * vec4(1.0, 0.2, 0.2, 1.0);
            }
            """.write(to: shader, atomically: true, encoding: .utf8)
            let file = dir.appendingPathComponent("config")
            try? "custom-shader = \(shader.path)\ncustom-shader-animation = always\n".write(to: file, atomically: true, encoding: .utf8)
            GhosttyRuntime.configFileOverride = file.path
            reloaded = GhosttyRuntime.shared.reloadConfig()
        }

        t.step("shaders: cleanup restores the normal config", nil, {
            GhosttyRuntime.configFileOverride == nil ? nil : "override still set"
        }) {
            GhosttyRuntime.configFileOverride = nil
            GhosttyRuntime.shared.reloadConfig()
            try? fm.removeItem(at: dir)
            self.layoutNow()
        }
    }
}
