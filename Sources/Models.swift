import Foundation

// MARK: - Email Model

struct Email: Identifiable {
    let id = UUID()
    let from: String
    let to: [String]
    let subject: String
    let body: String
    let htmlBody: String?
    let rawContent: String
    let date: Date
    var isRead: Bool = false

    var recipientList: String { to.joined(separator: ", ") }
    var isHTML: Bool { htmlBody != nil }
}

// MARK: - Mail Store

@MainActor
class MailStore: ObservableObject {
    @Published var emails: [Email] = []
    @Published var selectedEmailID: UUID?

    var selectedEmail: Email? {
        guard let id = selectedEmailID else { return nil }
        return emails.first { $0.id == id }
    }

    func add(_ email: Email) {
        emails.insert(email, at: 0)
    }

    func delete(at offsets: IndexSet) {
        if let selected = selectedEmailID,
           let idx = emails.firstIndex(where: { $0.id == selected }),
           offsets.contains(idx) {
            selectedEmailID = nil
        }
        emails.remove(atOffsets: offsets)
    }

    func markRead(_ id: UUID) {
        if let idx = emails.firstIndex(where: { $0.id == id }) {
            emails[idx].isRead = true
        }
    }

    func clear() {
        selectedEmailID = nil
        emails.removeAll()
    }

    var unreadCount: Int { emails.filter { !$0.isRead }.count }
}

// MARK: - Email Parser

enum EmailParser {
    static func parse(raw: String, from: String, to: [String], date: Date) -> Email {
        var headers: [String: String] = [:]
        var bodyLines: [String] = []
        var inHeader = true
        var contentType = ""
        var boundary = ""

        let lines = raw.components(separatedBy: "\n")
        var i = 0
        var currentHeaderKey = ""

        // --- Parse headers ---
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .init(charactersIn: "\r"))
            if line.isEmpty {
                inHeader = false
                i += 1
                break
            }
            if inHeader {
                if let colon = line.firstIndex(of: ":") {
                    let key = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                    currentHeaderKey = key
                } else if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    // Continuation of previous header
                    if let existing = headers[currentHeaderKey] {
                        headers[currentHeaderKey] = existing + " " + line.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            i += 1
        }

        // --- Determine content type ---
        contentType = headers["content-type"] ?? ""
        if contentType.contains("boundary=") {
            boundary = contentType.components(separatedBy: "boundary=").last?
                .trimmingCharacters(in: .init(charactersIn: "\"' ")) ?? ""
        }

        // --- Collect body lines ---
        while i < lines.count {
            bodyLines.append(lines[i].trimmingCharacters(in: .init(charactersIn: "\r")))
            i += 1
        }
        let rawBody = bodyLines.joined(separator: "\n")

        let subject = decodeMIME(headers["subject"] ?? "(no subject)")
        var plainText = rawBody
        var htmlText: String? = nil

        // --- Handle MIME multipart ---
        if !boundary.isEmpty {
            (plainText, htmlText) = parseMIME(body: rawBody, boundary: boundary)
        } else if contentType.lowercased().contains("text/html") {
            htmlText = rawBody
            plainText = rawBody.strippingHTML()
        }

        return Email(
            from: from,
            to: to,
            subject: subject,
            body: plainText,
            htmlBody: htmlText,
            rawContent: raw,
            date: date
        )
    }

    private static func parseMIME(body: String, boundary: String) -> (plain: String, html: String?) {
        let delimiter = "--" + boundary
        let parts = body.components(separatedBy: delimiter)
        var plain = ""
        var html: String? = nil

        for part in parts {
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !part.hasPrefix("--") else { continue }

            var partHeaders: [String: String] = [:]
            var partBody: [String] = []
            var inPartHeader = true

            var partLines = part.components(separatedBy: "\n")
            // Remove leading empty line caused by the newline after the boundary delimiter
            if partLines.first?.trimmingCharacters(in: .init(charactersIn: "\r")).isEmpty == true {
                partLines.removeFirst()
            }
            for pLine in partLines {
                let trimmedLine = pLine.trimmingCharacters(in: .init(charactersIn: "\r"))
                if inPartHeader {
                    if trimmedLine.isEmpty { inPartHeader = false; continue }
                    if let colon = trimmedLine.firstIndex(of: ":") {
                        let k = String(trimmedLine[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
                        let v = String(trimmedLine[trimmedLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        partHeaders[k] = v
                    }
                } else {
                    partBody.append(trimmedLine)
                }
            }

            let ct = (partHeaders["content-type"] ?? "").lowercased()
            let transferEncoding = (partHeaders["content-transfer-encoding"] ?? "").lowercased()
            var partContent = partBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Decode transfer encodings before assigning the MIME part content.
            if transferEncoding.contains("base64") {
                let cleanBase64 = partContent.components(separatedBy: .whitespacesAndNewlines).joined()
                if let data = Data(base64Encoded: cleanBase64),
                   let decoded = String(data: data, encoding: .utf8) {
                    partContent = decoded
                }
            } else if transferEncoding.contains("quoted-printable") {
                partContent = decodeQuotedPrintable(partContent)
            }

            if ct.contains("text/plain") && plain.isEmpty {
                plain = partContent
            } else if ct.contains("text/html") && html == nil {
                html = partContent
            }
        }

        return (plain, html)
    }

    private static func decodeMIME(_ value: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }

        let nsValue = value as NSString
        let range = NSRange(location: 0, length: nsValue.length)
        let matches = regex.matches(in: value, range: range)
        guard !matches.isEmpty else { return value }

        var result = ""
        var lastLocation = 0
        var previousWasEncoded = false

        for match in matches {
            let betweenRange = NSRange(location: lastLocation, length: match.range.location - lastLocation)
            let between = nsValue.substring(with: betweenRange)
            if !(previousWasEncoded && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                result += between
            }

            let encoding = nsValue.substring(with: match.range(at: 2)).lowercased()
            let encoded = nsValue.substring(with: match.range(at: 3))
            result += decodeEncodedWord(encoded, encoding: encoding)

            lastLocation = match.range.location + match.range.length
            previousWasEncoded = true
        }

        result += nsValue.substring(from: lastLocation)
        return result
    }

    private static func decodeEncodedWord(_ value: String, encoding: String) -> String {
        if encoding == "b" {
            let cleanBase64 = value.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: cleanBase64),
               let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
        }

        if encoding == "q" {
            return decodeQuotedPrintable(value.replacingOccurrences(of: "_", with: " "))
        }

        return value
    }

    private static func decodeQuotedPrintable(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var decoded: [UInt8] = []
        var index = 0

        while index < bytes.count {
            if bytes[index] == 61 { // "="
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]),
                   let low = hexValue(bytes[index + 2]) {
                    decoded.append((high << 4) | low)
                    index += 3
                    continue
                }
            }

            decoded.append(bytes[index])
            index += 1
        }

        return String(data: Data(decoded), encoding: .utf8) ?? value
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}

// MARK: - String Extensions

extension String {
    func strippingHTML() -> String {
        var result = self
        while let start = result.range(of: "<"),
              let end = result.range(of: ">", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound...end.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
