import ApplicationServices
import Foundation

// The text just before the insertion point in the focused field, read through
// Accessibility. Soniox hears the dictation as its continuation, so names and
// spelling already on the page carry over. Password fields are never read.
enum Cursor {
    @concurrent
    static func precedingText(limit: Int = 2000) async -> String {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1) // a hung app must not hold up the dictation
        guard let field: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else { return "" }
        let subrole: String? = attribute(field, kAXSubroleAttribute)
        guard subrole != kAXSecureTextFieldSubrole,
              let selection: AXValue = attribute(field, kAXSelectedTextRangeAttribute) else { return "" }
        var cursor = CFRange()
        guard AXValueGetValue(selection, .cfRange, &cursor), cursor.location > 0 else { return "" }
        let start = max(0, cursor.location - limit)
        var span = CFRange(location: start, length: cursor.location - start)
        var text: CFTypeRef?
        if let range = AXValueCreate(.cfRange, &span),
           AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString,
                                                     range, &text) == .success,
           let text = text as? String {
            return text
        }
        // Some fields only expose their whole value.
        guard let value: String = attribute(field, kAXValueAttribute) else { return "" }
        let whole = value as NSString
        guard cursor.location <= whole.length else { return "" }
        return whole.substring(with: NSRange(location: span.location, length: span.length))
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
