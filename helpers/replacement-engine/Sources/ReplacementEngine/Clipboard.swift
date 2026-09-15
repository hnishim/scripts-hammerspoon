import AppKit
import Foundation

struct ClipboardItemSnapshot {
    let values: [(NSPasteboard.PasteboardType, Data)]
}

struct ClipboardSnapshot {
    let items: [ClipboardItemSnapshot]
    let changeCount: Int

    static func capture(_ pasteboard: NSPasteboard = .general) throws -> ClipboardSnapshot {
        let before = pasteboard.changeCount
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            ClipboardItemSnapshot(values: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
        guard before == pasteboard.changeCount else { throw EngineError.clipboardUnavailable }
        return ClipboardSnapshot(items: items, changeCount: before)
    }

    func restoreIfUnchanged(since expectedChangeCount: Int, pasteboard: NSPasteboard = .general) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let objects: [NSPasteboardItem] = items.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values {
                item.setData(data, forType: type)
            }
            return item
        }
        return pasteboard.writeObjects(objects)
    }
}

final class ClipboardTransaction {
    private let pasteboard: NSPasteboard
    private let original: ClipboardSnapshot
    private var helperWriteChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) throws {
        self.pasteboard = pasteboard
        self.original = try ClipboardSnapshot.capture(pasteboard)
    }

    func writeReplacement(_ text: String) throws {
        pasteboard.clearContents()
        let afterClear = pasteboard.changeCount
        helperWriteChangeCount = afterClear
        guard pasteboard.setString(text, forType: .string) else {
            if pasteboard.changeCount != afterClear { helperWriteChangeCount = nil }
            throw EngineError.clipboardUnavailable
        }
        helperWriteChangeCount = pasteboard.changeCount
    }

    @discardableResult
    func restoreIfUntouched() -> Bool {
        guard let helperWriteChangeCount else { return true }
        return original.restoreIfUnchanged(since: helperWriteChangeCount, pasteboard: pasteboard)
    }
}
