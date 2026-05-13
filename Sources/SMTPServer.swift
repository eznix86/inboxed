import Foundation
import Network
import UserNotifications

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let direction: Direction
    let message: String

    enum Direction { case inbound, outbound, system }
}

// MARK: - Notifications

private final class InboxedNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = InboxedNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

enum InboxedNotifications {
    private static var canUseNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static func configure() {
        guard canUseNotifications else { return }

        let center = UNUserNotificationCenter.current()
        center.delegate = InboxedNotificationDelegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func emailReceived(_ email: Email) {
        guard canUseNotifications else { return }

        let sender = email.from.isEmpty ? "unknown sender" : email.from
        let content = UNMutableNotificationContent()
        content.title = "New email received"
        content.subtitle = email.subject
        content.body = "From: \(sender)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "email-\(email.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - SMTP Server

@MainActor
class SMTPServer: ObservableObject {
    @Published var isRunning = false
    @Published var port: UInt16
    @Published var logs: [LogEntry] = []
    @Published var connectionCount = 0

    private static let portDefaultsKey = "smtpPort"
    private var listener: NWListener?
    private var sessions: [SMTPSession] = []
    weak var mailStore: MailStore?

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
        port = savedPort > 0 ? UInt16(savedPort) : 1025
    }

    // MARK: Start / Stop

    func start() {
        guard !isRunning else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            log(.system, "Failed to start listener: \(error.localizedDescription)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isRunning = true
                    self?.log(.system, "Listening on localhost:\(self?.port ?? 0)")
                case .failed(let err):
                    self?.isRunning = false
                    self?.log(.system, "Server error: \(err.localizedDescription)")
                    self?.listener?.cancel()
                case .cancelled:
                    self?.isRunning = false
                    self?.log(.system, "Server stopped")
                default: break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        sessions.forEach { $0.close() }
        sessions.removeAll()
        isRunning = false
    }

    func updatePort(_ newPort: UInt16) {
        guard newPort != port else { return }

        let shouldRestart = isRunning
        if shouldRestart { stop() }

        port = newPort
        UserDefaults.standard.set(Int(newPort), forKey: Self.portDefaultsKey)
        log(.system, "SMTP port changed to \(newPort)")

        if shouldRestart { start() }
    }

    func clearLogs() { logs.removeAll() }

    // MARK: Connection Handling

    private func accept(_ connection: NWConnection) {
        connectionCount += 1
        log(.system, "Connection #\(connectionCount) opened")

        let session = SMTPSession(
            connection: connection,
            onLog: { [weak self] dir, msg in
                Task { @MainActor [weak self] in self?.log(dir, msg) }
            },
            onEmail: { [weak self] email in
                Task { @MainActor [weak self] in self?.mailStore?.add(email) }
            }
        )
        sessions.append(session)
        session.start()

        // Clean up finished sessions
        sessions.removeAll { $0.isDone }
    }

    // MARK: Logging

    private func log(_ direction: LogEntry.Direction, _ message: String) {
        let entry = LogEntry(date: Date(), direction: direction, message: message)
        logs.append(entry)
        if logs.count > 500 { logs.removeFirst(100) }
    }
}

// MARK: - SMTP Session

class SMTPSession {
    private let connection: NWConnection
    private let onLog: (LogEntry.Direction, String) -> Void
    private let onEmail: (Email) -> Void
    private(set) var isDone = false

    private var from = ""
    private var to: [String] = []
    private var dataBuffer = Data()
    private var inData = false
    private var receiveBuffer = ""

    init(
        connection: NWConnection,
        onLog: @escaping (LogEntry.Direction, String) -> Void,
        onEmail: @escaping (Email) -> Void
    ) {
        self.connection = connection
        self.onLog = onLog
        self.onEmail = onEmail
    }

    // MARK: Lifecycle

    func start() {
        connection.start(queue: .global(qos: .userInitiated))
        send("220 localhost Inboxed SMTP Server ready\r\n")
        receive()
    }

    func close() {
        connection.cancel()
        isDone = true
    }

    // MARK: Network I/O

    private func send(_ string: String) {
        for line in string.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLine.isEmpty { onLog(.outbound, trimmedLine) }
        }
        let data = string.data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if self.inData {
                    self.dataBuffer.append(data)
                    self.checkDataEnd()
                } else if let text = String(data: data, encoding: .utf8) {
                    self.receiveBuffer += text
                    self.processBuffer()
                }
            }
            if !isComplete && error == nil {
                self.receive()
            } else {
                self.isDone = true
            }
        }
    }

    // MARK: Buffer Processing

    private func processBuffer() {
        while let lineEnd = receiveBuffer.range(of: "\r\n") ?? receiveBuffer.range(of: "\n") {
            let line = String(receiveBuffer[..<lineEnd.lowerBound])
            receiveBuffer.removeSubrange(..<lineEnd.upperBound)
            if !line.isEmpty { handleCommand(line) }
        }
    }

    private func checkDataEnd() {
        // Look for CRLF.CRLF
        let marker = Data("\r\n.\r\n".utf8)
        if let range = dataBuffer.range(of: marker) {
            let emailData = dataBuffer[..<range.lowerBound]
            inData = false
            dataBuffer = Data()
            finalizeEmail(data: emailData)
            send("250 OK: Message queued\r\n")
        }
    }

    // MARK: Command Dispatch

    private func handleCommand(_ line: String) {
        onLog(.inbound, line)
        let upper = line.uppercased()

        if upper.hasPrefix("EHLO") || upper.hasPrefix("HELO") {
            send("250-localhost\r\n250-SIZE 52428800\r\n250-8BITMIME\r\n250 OK\r\n")
        } else if upper.hasPrefix("MAIL FROM") {
            from = extractAddress(line)
            to = []
            send("250 OK\r\n")
        } else if upper.hasPrefix("RCPT TO") {
            to.append(extractAddress(line))
            send("250 OK\r\n")
        } else if upper.trimmingCharacters(in: .whitespaces) == "DATA" {
            inData = true
            dataBuffer = Data()
            // SMTP DATA starts after the 354 response;
            // add a leading CRLF so the end-marker check works for the first line
            send("354 End data with <CR><LF>.<CR><LF>\r\n")
        } else if upper.trimmingCharacters(in: .whitespaces) == "QUIT" {
            send("221 Bye\r\n")
            connection.cancel()
            isDone = true
        } else if upper.trimmingCharacters(in: .whitespaces) == "RSET" {
            from = ""; to = []; dataBuffer = Data()
            send("250 OK\r\n")
        } else if upper.trimmingCharacters(in: .whitespaces) == "NOOP" {
            send("250 OK\r\n")
        } else {
            send("500 Command unrecognised\r\n")
        }
    }

    // MARK: Helpers

    private func extractAddress(_ line: String) -> String {
        if let s = line.firstIndex(of: "<"), let e = line.lastIndex(of: ">") {
            return String(line[line.index(after: s)..<e])
        }
        if let colon = line.firstIndex(of: ":") {
            return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private func finalizeEmail(data: Data) {
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let email = EmailParser.parse(raw: raw, from: from, to: to, date: Date())
        onLog(.system, "Email captured: \(email.subject) from \(from)")
        onEmail(email)
        InboxedNotifications.emailReceived(email)
    }
}
