#if MESHSITES
import Foundation

/// Meshdown v1 — the line-oriented page format Meshsites servers speak.
/// See docs/MESHSITES.md §4. Lenient by design: unknown or malformed
/// bracket lines render as plain text.
struct MeshdownDocument {
    struct Field: Hashable {
        let name: String
        let label: String
    }

    struct Form: Hashable {
        let isPost: Bool
        let path: String
        var fields: [Field] = []
        var submitLabel = "Submit"
    }

    enum Block: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(String)
        case link(path: String, label: String)
        case rule
        case form(Form)
    }

    struct Item: Identifiable {
        let id: Int
        let block: Block
    }

    var items: [Item] = []

    /// `version` is the protocol/format version the page was served with
    /// (spec §7). v1 is the only syntax today; future syntaxes switch here so
    /// old pages keep rendering with old rules.
    static func parse(_ text: String, version: UInt8 = 1) -> MeshdownDocument {
        _ = version   // one grammar so far
        return parseV1(text)
    }

    private static func parseV1(_ text: String) -> MeshdownDocument {
        var doc = MeshdownDocument()
        var nextId = 0
        var paragraphBuffer: [String] = []
        var openForm: Form?

        func emit(_ block: Block) {
            doc.items.append(Item(id: nextId, block: block))
            nextId += 1
        }
        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            emit(.paragraph(paragraphBuffer.joined(separator: " ")))
            paragraphBuffer.removeAll()
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // .whitespacesAndNewlines so CRLF servers parse identically (spec §4).
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)

            if var form = openForm {
                if line == "[/form]" {
                    flushParagraph()
                    emit(.form(form))
                    openForm = nil
                } else if line.hasPrefix("[field "), line.hasSuffix("]") {
                    let inner = String(line.dropFirst("[field ".count).dropLast())
                    let parts = inner.split(separator: " ", maxSplits: 1)
                    if let name = parts.first.map(String.init), isValidFieldName(name) {
                        // Duplicate names in one form are dropped (spec §4).
                        if !form.fields.contains(where: { $0.name == name }) {
                            let label = parts.count > 1 ? String(parts[1]) : name
                            form.fields.append(Field(name: name, label: label))
                        }
                        openForm = form
                    } else {
                        paragraphBuffer.append(line)
                    }
                } else if line.hasPrefix("[submit "), line.hasSuffix("]") {
                    form.submitLabel = String(line.dropFirst("[submit ".count).dropLast())
                    openForm = form
                } else if !line.isEmpty {
                    paragraphBuffer.append(line)
                }
                continue
            }

            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("### ") {
                flushParagraph()
                emit(.heading(level: 3, text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                emit(.heading(level: 2, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                emit(.heading(level: 1, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("* ") {
                flushParagraph()
                emit(.listItem(String(line.dropFirst(2))))
            } else if line == "---" {
                flushParagraph()
                emit(.rule)
            } else if line.hasPrefix("=> ") {
                flushParagraph()
                let rest = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let parts = rest.split(separator: " ", maxSplits: 1)
                // Site paths, or absolute web URLs (rendered as external
                // links that open in the system browser). http(s) only.
                if let path = parts.first.map(String.init),
                   path.hasPrefix("/") || path.hasPrefix("https://") || path.hasPrefix("http://") {
                    let label = parts.count > 1 ? String(parts[1]) : path
                    emit(.link(path: path, label: label))
                } else {
                    paragraphBuffer.append(line)
                }
            } else if line.hasPrefix("[form "), line.hasSuffix("]") {
                let inner = String(line.dropFirst("[form ".count).dropLast())
                let parts = inner.split(separator: " ", maxSplits: 1)
                let method = parts.first.map(String.init)
                if let method, method == "get" || method == "post",
                   parts.count > 1, parts[1].hasPrefix("/") {
                    flushParagraph()
                    openForm = Form(isPost: method == "post", path: String(parts[1]))
                } else {
                    paragraphBuffer.append(line)
                }
            } else {
                paragraphBuffer.append(line)
            }
        }
        flushParagraph()
        if let form = openForm {
            emit(.form(form))
        }
        return doc
    }

    private static func isValidFieldName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "_" }
    }
}
#endif
