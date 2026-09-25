import AppKit

public enum AgentIconStore {
    /// Official marks are bundled as PNGs. Monochrome marks are returned as template images so the UI can tint them.
    public static func image(for agent: AgentKind) -> NSImage? {
        guard let bundle = resourceBundle,
              let url = bundle.url(forResource: agent.iconResourceName, withExtension: "png", subdirectory: "AgentIcons")
                ?? bundle.url(forResource: agent.iconResourceName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = ![.claude, .antigravity].contains(agent)
        return image
    }

    /// SwiftPM's generated `Bundle.module` traps when the bundle is missing, which happens inside a hand-built .app.
    /// Look in the app's Resources first, then beside the executable, and only then defer to SwiftPM.
    static let resourceBundle: Bundle? = {
        let name = "LocalObserver_LocalObserverCore.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()
}
