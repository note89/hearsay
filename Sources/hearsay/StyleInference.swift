import Insertion
import Polish

/// Wispr's "context awareness" without screenshots: the frontmost app decides the writing style.
enum StyleInference {
    static func style(for target: ArmResult) -> WritingStyle {
        guard case .armed(let armed) = target, let bundleID = armed.app.bundleID else { return .plain }
        if chat.contains(where: bundleID.hasPrefix) { return .chat }
        if email.contains(where: bundleID.hasPrefix) { return .email }
        if code.contains(where: bundleID.hasPrefix) { return .code }
        if markdown.contains(where: bundleID.hasPrefix) { return .markdown }
        return .plain
    }

    private static let chat = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
        "com.hnc.Discord", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop",
    ]
    private static let email = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
    ]
    private static let markdown = [
        "md.obsidian", "notion.id", "net.shinyfrog.bear", "com.lukilabs.lukiapp",
    ]
    private static let code = [
        "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.apple.dt.Xcode",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.zed.Zed", "dev.warp.Warp-Stable", "com.jetbrains.",
    ]
}
