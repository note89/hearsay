import AppKit
import ApplicationServices

public struct TargetApp: Equatable, Sendable {
    public let pid: pid_t
    public let bundleID: String?
    public let name: String
}

public enum FocusedElement {
    /// A text field or area: an accessibility write is plausible and verifiable.
    case textElement(AXUIElement)
    /// Something else has focus (web area, group, …): only paste reaches it.
    case other(AXUIElement, role: String)
    /// Accessibility could not tell us: only paste reaches it.
    case unknown
}

public struct InsertionTarget {
    public let app: TargetApp
    public let focused: FocusedElement
}

public enum ArmResult {
    case armed(InsertionTarget)
    case secureField(TargetApp)
    case noFrontmostApp
}

public enum Arming {
    /// Captures where text should land. Call at press time — focus can move during a long utterance.
    public static func arm() -> ArmResult {
        guard let front = NSWorkspace.shared.frontmostApplication else { return .noFrontmostApp }
        let app = TargetApp(pid: front.processIdentifier, bundleID: front.bundleIdentifier, name: front.localizedName ?? "unknown app")
        guard let element = focusedElement(pid: front.processIdentifier) else {
            return .armed(InsertionTarget(app: app, focused: .unknown))
        }
        if element.string(kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return .secureField(app) }
        let role = element.string(kAXRoleAttribute) ?? "?"
        let focused: FocusedElement = textRoles.contains(role) ? .textElement(element) : .other(element, role: role)
        return .armed(InsertionTarget(app: app, focused: focused))
    }

    private static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]

    private static let messagingTimeout: Float = 0.25

    /// True when a secure (password) field currently has focus — re-checked at insert time
    /// because focus can move to one during the utterance.
    public static func focusIsSecure() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let element = focusedElement(pid: front.processIdentifier) else { return false }
        return element.string(kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }
}

extension AXUIElement {
    func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

extension InsertionTarget {
    /// What the focused field contains right now; nil when accessibility cannot read it.
    public func currentText() -> String? {
        guard case .textElement(let element) = focused else { return nil }
        return element.string(kAXValueAttribute)
    }
}
