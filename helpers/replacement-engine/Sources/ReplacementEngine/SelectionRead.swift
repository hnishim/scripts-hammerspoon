import AppKit
import ApplicationServices
import Darwin
import Foundation

enum SelectionReadStatus: String, Equatable {
    case selected
    case none
    case unavailable
    case error
}

struct SelectionReadResult: Equatable {
    let status: SelectionReadStatus
    let text: String?
    let source: SelectionSourceKind?
}

enum SelectionReadContract {
    static func resolve(
        contextAvailable: Bool,
        secure: Bool,
        selectedText: String?,
        selectedRange: CFRange?,
        value: String?,
        isEditable: Bool,
        copyFallback: () throws -> String?
    ) -> SelectionReadResult {
        guard contextAvailable, !secure else {
            return SelectionReadResult(status: .unavailable, text: nil, source: nil)
        }

        if let selectedText, !selectedText.isEmpty {
            return SelectionReadResult(status: .selected, text: selectedText, source: .axSelectedText)
        }

        if let selectedRange,
           let value,
           let recovered = UTF16RangeCodec.substring(selectedRange, in: value),
           !recovered.isEmpty {
            return SelectionReadResult(status: .selected, text: recovered, source: .axRangeValue)
        }

        if let selectedRange, selectedRange.length == 0, isEditable {
            return SelectionReadResult(status: .none, text: nil, source: nil)
        }

        guard SelectionAcquisitionPolicy.shouldUseCopyFallback(
            isEditable: isEditable,
            selectedRange: selectedRange,
            selectionRecovered: false
        ) else {
            return SelectionReadResult(status: .none, text: nil, source: nil)
        }

        do {
            guard let copied = try copyFallback(), !copied.isEmpty else {
                return SelectionReadResult(status: .none, text: nil, source: nil)
            }
            return SelectionReadResult(status: .selected, text: copied, source: .clipboardCopy)
        } catch {
            return SelectionReadResult(status: .error, text: nil, source: nil)
        }
    }
}

struct SelectionReadEvent: Codable, Equatable {
    let event: String
    let status: String
    let text: String?
    let source: String?

    init(_ result: SelectionReadResult) {
        self.event = "read"
        self.status = result.status.rawValue
        self.text = result.text
        self.source = result.source?.rawValue
    }
}

enum ProductionSelectionReadCaptureEngine {
    static func capture() -> SelectionReadResult {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return SelectionReadResult(status: .unavailable, text: nil, source: nil)
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let appFocused = AX.elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString)
        let systemFocused = AX.elementAttribute(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString
        )
        let focused: AXUIElement?
        if let appFocused, AX.pid(appFocused) == pid {
            focused = appFocused
        } else if let systemFocused, AX.pid(systemFocused) == pid {
            focused = systemFocused
        } else {
            focused = nil
        }
        guard let focused else {
            return SelectionReadResult(status: .unavailable, text: nil, source: nil)
        }

        let role = AX.stringAttribute(focused, kAXRoleAttribute as CFString)
        let subrole = AX.stringAttribute(focused, kAXSubroleAttribute as CFString)
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        if secure {
            return SelectionReadResult(status: .unavailable, text: nil, source: nil)
        }

        do {
            let capture = try ProductionTargetCaptureEngine.capture()
            return SelectionReadResult(
                status: .selected,
                text: capture.selection,
                source: capture.selectionSource
            )
        } catch EngineError.selectionUnavailable {
            return SelectionReadResult(status: .none, text: nil, source: nil)
        } catch {
            return SelectionReadResult(status: .error, text: nil, source: nil)
        }
    }
}

struct ProductionSelectionReadRunner {
    private let capture: () -> SelectionReadResult
    private let emit: (SelectionReadEvent) throws -> Void

    init(
        capture: @escaping () -> SelectionReadResult = { ProductionSelectionReadCaptureEngine.capture() },
        emit: @escaping (SelectionReadEvent) throws -> Void = { try writeJSONLine($0) }
    ) {
        self.capture = capture
        self.emit = emit
    }

    func run() throws {
        try emit(SelectionReadEvent(capture()))
    }
}
