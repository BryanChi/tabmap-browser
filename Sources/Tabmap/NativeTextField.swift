import AppKit
import SwiftUI

/// A plain AppKit text field: no border, background or focus ring. Used for the address field and the map search,
/// where SwiftUI's TextField draws a focus ring that does not fit (and in the map was drawn offset).
struct NativeTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 13
    var textColor: NSColor = .labelColor
    var placeholderColor: NSColor = .placeholderTextColor
    /// Each change makes the field first responder, which selects all of its text.
    var focusToken: Int = 0
    var focusOnAppear = false
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Finishes what is being typed: given the typed text, the whole text to show, or nil. The added part is
    /// shown selected, so typing on replaces it, Delete removes it, and Return or → accepts it.
    var complete: ((String) -> String?)? = nil

    final class Field: NSTextField {
        var onBecomeFirstResponder: (() -> Void)?
        var focusWhenInWindow = false

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                (currentEditor() as? NSTextView)?.insertionPointColor = textColor ?? .labelColor
                onBecomeFirstResponder?()
            }
            return accepted
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard focusWhenInWindow, let window else { return }
            focusWhenInWindow = false
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self else { return }
                window?.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeTextField
        var lastFocusToken: Int
        /// Set by a delete key just before the text changes, so deleting does not bring a completion back.
        private var deleting = false

        init(_ parent: NativeTextField) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let text = field.stringValue
            let wasDeleting = deleting
            deleting = false
            // Only with the caret at the end after typing, and not while an input method is composing.
            if !wasDeleting, let complete = parent.complete, let editor = field.currentEditor() as? NSTextView,
               editor.selectedRange().location == (text as NSString).length,
               editor.selectedRange().length == 0, editor.markedRange().length == 0,
               let full = complete(text), full.count > text.count, full.lowercased().hasPrefix(text.lowercased()) {
                let typedLength = (text as NSString).length
                editor.string = full
                editor.setSelectedRange(NSRange(location: typedLength, length: (full as NSString).length - typedLength))
                parent.text = full
                return
            }
            parent.text = text
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                if NSStringFromSelector(selector).hasPrefix("delete") { deleting = true }
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        let coordinator = context.coordinator
        field.onBecomeFirstResponder = { [weak coordinator] in coordinator?.parent.onFocusChange(true) }
        field.focusWhenInWindow = focusOnAppear
        field.stringValue = text
        style(field)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        style(field)
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        // A field torn down mid-edit never sends its end-of-editing notification.
        if field.currentEditor() != nil { coordinator.parent.onFocusChange(false) }
    }

    private func style(_ field: Field) {
        let font = NSFont.systemFont(ofSize: fontSize)
        if field.font != font { field.font = font }
        if field.textColor != textColor { field.textColor = textColor }
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: placeholderColor, .font: font])
        }
    }
}
