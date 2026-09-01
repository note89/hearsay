import Insertion
import Polish

/// Wispr's "context awareness" without screenshots: the frontmost app decides the writing style.
/// One table drives both the inference and the Style pane's display.
enum StyleInference {
    struct KnownApp {
        let bundlePrefix: String
        let name: String
        let style: WritingStyle
    }

    static func style(for target: ArmResult) -> WritingStyle {
        guard case .armed(let armed) = target, let bundleID = armed.app.bundleID else { return .plain }
        return apps.first { bundleID.hasPrefix($0.bundlePrefix) }?.style ?? .plain
    }

    static func appNames(for style: WritingStyle) -> [String] {
        apps.filter { $0.style == style }.map(\.name)
    }

    static func effect(of style: WritingStyle) -> String {
        switch style {
        case .chat: return "casual, no trailing period"
        case .email: return "complete sentences, paragraphs"
        case .code: return "identifiers verbatim, straight quotes"
        case .markdown: return "- lists, # headings, `code`"
        case .plain: return "neutral written prose"
        }
    }

    static let apps: [KnownApp] = [
        KnownApp(bundlePrefix: "com.tinyspeck.slackmacgap", name: "Slack", style: .chat),
        KnownApp(bundlePrefix: "com.apple.MobileSMS", name: "Messages", style: .chat),
        KnownApp(bundlePrefix: "net.whatsapp.WhatsApp", name: "WhatsApp", style: .chat),
        KnownApp(bundlePrefix: "com.hnc.Discord", name: "Discord", style: .chat),
        KnownApp(bundlePrefix: "ru.keepcoder.Telegram", name: "Telegram", style: .chat),
        KnownApp(bundlePrefix: "org.whispersystems.signal-desktop", name: "Signal", style: .chat),
        KnownApp(bundlePrefix: "com.apple.mail", name: "Mail", style: .email),
        KnownApp(bundlePrefix: "com.microsoft.Outlook", name: "Outlook", style: .email),
        KnownApp(bundlePrefix: "com.readdle.smartemail-Mac", name: "Spark", style: .email),
        KnownApp(bundlePrefix: "com.superhuman.electron", name: "Superhuman", style: .email),
        KnownApp(bundlePrefix: "md.obsidian", name: "Obsidian", style: .markdown),
        KnownApp(bundlePrefix: "notion.id", name: "Notion", style: .markdown),
        KnownApp(bundlePrefix: "net.shinyfrog.bear", name: "Bear", style: .markdown),
        KnownApp(bundlePrefix: "com.lukilabs.lukiapp", name: "Craft", style: .markdown),
        KnownApp(bundlePrefix: "com.todesktop.230313mzl4w4u92", name: "Cursor", style: .code),
        KnownApp(bundlePrefix: "com.microsoft.VSCode", name: "VS Code", style: .code),
        KnownApp(bundlePrefix: "com.apple.dt.Xcode", name: "Xcode", style: .code),
        KnownApp(bundlePrefix: "com.apple.Terminal", name: "Terminal", style: .code),
        KnownApp(bundlePrefix: "com.googlecode.iterm2", name: "iTerm", style: .code),
        KnownApp(bundlePrefix: "com.mitchellh.ghostty", name: "Ghostty", style: .code),
        KnownApp(bundlePrefix: "dev.zed.Zed", name: "Zed", style: .code),
        KnownApp(bundlePrefix: "dev.warp.Warp-Stable", name: "Warp", style: .code),
        KnownApp(bundlePrefix: "com.jetbrains.", name: "JetBrains IDEs", style: .code),
    ]
}
