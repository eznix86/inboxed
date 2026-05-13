import AppKit
import SwiftUI
import WebKit

// MARK: - App Entry Point

@main
struct InboxedApp: App {
    @StateObject private var mailStore = MailStore()
    @StateObject private var server = SMTPServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mailStore)
                .environmentObject(server)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear {
                    InboxedNotifications.configure()
                    server.mailStore = mailStore
                    server.start()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Server") {
                Button(server.isRunning ? "Stop Server" : "Start Server") {
                    server.isRunning ? server.stop() : server.start()
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Clear Emails") { mailStore.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(server)
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var mailStore: MailStore
    @EnvironmentObject var server: SMTPServer
    @State private var selectedTab: SidebarTab = .inbox
    @State private var showLogs = false

    enum SidebarTab { case inbox, logs }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } content: {
            emailList
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            detailPanel
        }
        .toolbar { toolbarItems }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedTab) {
                Section("Mailbox") {
                    Label {
                        HStack {
                            Text("Inbox")
                            Spacer()
                            if mailStore.unreadCount > 0 {
                                Text("\(mailStore.unreadCount)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue, in: Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: "tray")
                    }
                    .tag(SidebarTab.inbox)
                }

                Section("Developer") {
                    Label("Server Logs", systemImage: "terminal")
                        .tag(SidebarTab.logs)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Inboxed")

            Divider()
            serverStatusFooter
        }
    }

    private var serverStatusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(server.isRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: server.isRunning ? .green : .red, radius: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.isRunning ? "Running" : "Stopped")
                    .font(.caption.bold())
                    .foregroundStyle(server.isRunning ? .green : .red)
                Text(verbatim: "localhost:\(server.port)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            Spacer()

            Button {
                server.isRunning ? server.stop() : server.start()
            } label: {
                Image(systemName: server.isRunning ? "stop.fill" : "play.fill")
                    .foregroundStyle(server.isRunning ? .red : .green)
            }
            .buttonStyle(.borderless)
            .help(server.isRunning ? "Stop SMTP server" : "Start SMTP server")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Email List

    @ViewBuilder
    private var emailList: some View {
        if selectedTab == .inbox {
            EmailListView()
        } else {
            LogsView()
        }
    }

    // MARK: Detail Panel

    @ViewBuilder
    private var detailPanel: some View {
        if let email = mailStore.selectedEmail {
            EmailDetailView(email: email)
        } else if selectedTab == .logs {
            Color.clear
        } else if mailStore.emails.isEmpty {
            inboxSetupState
        } else {
            noSelectionState
        }
    }

    private var inboxSetupState: some View {
        VStack(spacing: 22) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("Waiting for emails")
                    .font(.title2.bold())
                Text("Inboxed is listening for local SMTP messages. Configure your app with these settings to start capturing emails.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            smtpConfigCard

            HStack(spacing: 10) {
                Button {
                    copySMTPConfig()
                } label: {
                    Label("Copy SMTP Config", systemImage: "doc.on.doc")
                }

                Button {
                    sendSampleEmail()
                } label: {
                    Label("Send Test Email", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    openSettingsWindow()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var smtpConfigCard: some View {
        VStack(spacing: 0) {
            smtpConfigRow("Host", value: "localhost")
            Divider()
            smtpConfigRow("Port", value: String(server.port))
            Divider()
            smtpConfigRow("TLS", value: "Off")
            Divider()
            smtpConfigRow("Auth", value: "None")
        }
        .frame(width: 360)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        )
    }

    private func smtpConfigRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var noSelectionState: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.open")
                .font(.system(size: 52))
                .foregroundStyle(.quaternary)
            Text("No email selected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Select an email from the inbox to preview it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copySMTPConfig() {
        let config = """
        Host: localhost
        Port: \(server.port)
        TLS: Off
        Auth: None
        """

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(config, forType: .string)
    }

    private func sendSampleEmail() {
        let html = """
        <!doctype html>
        <html>
        <body style="margin:0;background:#f4f7fb;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
          <div style="max-width:560px;margin:36px auto;background:white;border-radius:18px;padding:32px;box-shadow:0 18px 48px rgba(15,23,42,.12);">
            <p style="margin:0 0 10px;color:#2563eb;font-size:13px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;">Inboxed Test</p>
            <h1 style="margin:0 0 12px;color:#111827;font-size:32px;line-height:1.08;">Your local SMTP catcher is working.</h1>
            <p style="margin:0 0 24px;color:#4b5563;font-size:16px;line-height:1.6;">This sample email was generated inside Inboxed to verify rendering, plain text fallback, and raw message inspection.</p>
            <a href="https://example.com" style="display:inline-block;background:#2563eb;color:white;padding:12px 18px;border-radius:10px;text-decoration:none;font-weight:700;">External link test</a>
          </div>
        </body>
        </html>
        """
        let plain = "Inboxed test email. Your local SMTP catcher is working."
        let raw = """
        From: Inboxed <test@inboxed.local>
        To: developer@local.test
        Subject: Inboxed test email
        MIME-Version: 1.0
        Content-Type: multipart/alternative

        \(plain)
        """
        let email = Email(
            from: "test@inboxed.local",
            to: ["developer@local.test"],
            subject: "Inboxed test email",
            body: plain,
            htmlBody: html,
            rawContent: raw,
            date: Date()
        )

        mailStore.add(email)
        mailStore.selectedEmailID = email.id
    }

    private func openSettingsWindow() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            EmptyView()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                server.isRunning ? server.stop() : server.start()
            } label: {
                Label(
                    server.isRunning ? "Stop Server" : "Start Server",
                    systemImage: server.isRunning ? "stop.circle" : "play.circle"
                )
                .foregroundStyle(server.isRunning ? .red : .green)
            }
            .help(server.isRunning ? "Stop SMTP server" : "Start SMTP server")

            Button(role: .destructive) {
                mailStore.clear()
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .help("Delete all captured emails")
            .disabled(mailStore.emails.isEmpty)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var server: SMTPServer
    @State private var portText = ""

    private var parsedPort: UInt16? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(trimmed), port > 0 else { return nil }
        return port
    }

    private var canApplyPort: Bool {
        guard let parsedPort else { return false }
        return parsedPort != server.port
    }

    private var portMessage: String {
        if parsedPort == nil {
            return "Enter a port between 1 and 65535."
        }

        if canApplyPort && server.isRunning {
            return "Saving will restart the SMTP listener."
        }

        return "Use this port in apps that send local test email."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            serverCard
            footerActions
        }
        .padding(28)
        .frame(width: 520)
        .onAppear {
            portText = String(server.port)
        }
        .onChange(of: server.port) { _, newPort in
            portText = String(newPort)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            appIcon

            VStack(alignment: .leading, spacing: 3) {
                Text("SMTP Server")
                    .font(.title2.bold())
                Text("Configure where Inboxed listens for local development email.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }

    private var serverCard: some View {
        VStack(spacing: 0) {
            settingsRow(label: "Status") {
                statusPill
            }

            Divider()

            settingsRow(label: "Host") {
                Text(verbatim: "localhost")
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            Divider()

            HStack(alignment: .top, spacing: 18) {
                Text("Port")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TextField("1025", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 108)
                            .onSubmit(applyPort)

                        Text(verbatim: "localhost:\(portText.isEmpty ? String(server.port) : portText)")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text(portMessage)
                        .font(.caption)
                        .foregroundStyle(parsedPort == nil ? .red : .secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        )
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(server.isRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: server.isRunning ? .green : .red, radius: 3)
            Text(server.isRunning ? "Running" : "Stopped")
        }
        .font(.callout.bold())
        .foregroundStyle(server.isRunning ? .green : .red)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background((server.isRunning ? Color.green : Color.red).opacity(0.12), in: Capsule())
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button(server.isRunning ? "Stop Server" : "Start Server") {
                server.isRunning ? server.stop() : server.start()
            }

            Text("Icon by akid3v via macOSicons")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Reset") {
                portText = String(server.port)
            }
            .disabled(!canApplyPort)

            Button(server.isRunning ? "Save & Restart" : "Save Port") {
                applyPort()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canApplyPort)
        }
    }

    private func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 18) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            content()
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func applyPort() {
        guard let parsedPort else { return }
        server.updatePort(parsedPort)
    }
}

// MARK: - Email List View

struct EmailListView: View {
    @EnvironmentObject var mailStore: MailStore
    @EnvironmentObject var server: SMTPServer

    var body: some View {
        List(mailStore.emails, selection: $mailStore.selectedEmailID) { email in
            EmailRowView(email: email)
                .tag(email.id)
                .onAppear {
                    if mailStore.selectedEmailID == email.id {
                        mailStore.markRead(email.id)
                    }
                }
        }
        .listStyle(.inset)
        .navigationTitle("Inbox (\(mailStore.emails.count))")
        .overlay {
            if mailStore.emails.isEmpty {
                ContentUnavailableView(
                    "No Emails Yet",
                    systemImage: "envelope.badge",
                    description: Text("Send an email to localhost:\(String(server.port)) to see it here")
                )
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button(role: .destructive) {
                let indices = IndexSet(
                    ids.compactMap { id in mailStore.emails.firstIndex(where: { $0.id == id }) }
                )
                mailStore.delete(at: indices)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onChange(of: mailStore.selectedEmailID) { _, newID in
            if let id = newID { mailStore.markRead(id) }
        }
    }
}

struct EmailRowView: View {
    let email: Email

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(email.from.isEmpty ? "(unknown sender)" : email.from)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .foregroundStyle(email.isRead ? .secondary : .primary)
                Spacer()
                Text(email.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(email.subject)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(email.isRead ? .tertiary : .primary)
            Text(email.body.isEmpty ? " " : email.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            if !email.isRead {
                Circle()
                    .fill(.blue)
                    .frame(width: 6, height: 6)
                    .offset(x: -10)
            }
        }
    }
}

// MARK: - Email Detail View

struct EmailDetailView: View {
    let email: Email
    @State private var viewMode: ViewMode = .rendered

    enum ViewMode: String, CaseIterable {
        case rendered = "Preview"
        case plain    = "Plain Text"
        case raw      = "Raw"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text(email.subject)
                    .font(.title2.bold())
                    .textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("From").foregroundStyle(.secondary).font(.caption)
                        Text(email.from).font(.caption).textSelection(.enabled)
                    }
                    GridRow {
                        Text("To").foregroundStyle(.secondary).font(.caption)
                        Text(email.recipientList).font(.caption).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Date").foregroundStyle(.secondary).font(.caption)
                        Text(email.date.formatted(date: .abbreviated, time: .complete))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    if email.isHTML {
                        Label("HTML", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.1), in: Capsule())
                    }
                    Spacer()
                    Picker("View", selection: $viewMode) {
                        ForEach(email.isHTML ? ViewMode.allCases : [.plain, .raw], id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
            }
            .padding()
            .background(.background)

            Divider()

            // Body
            Group {
                switch viewMode {
                case .rendered:
                    if let html = email.htmlBody {
                        WebView(html: html)
                    } else {
                        scrollableText(email.body)
                    }
                case .plain:
                    scrollableText(email.body)
                case .raw:
                    scrollableText(email.rawContent, monospaced: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(email.subject)
        .navigationSubtitle("from \(email.from)")
    }

    private func scrollableText(_ text: String, monospaced: Bool = false) -> some View {
        ScrollView {
            Text(text)
                .font(monospaced ? .system(.caption, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

// MARK: - Web View (for HTML emails)

struct WebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

// MARK: - Logs View

struct LogsView: View {
    @EnvironmentObject var server: SMTPServer
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SMTP Logs")
                        .font(.headline)
                    Text("\(server.logs.count) events · localhost:\(server.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    autoScroll.toggle()
                } label: {
                    Label("Auto-scroll", systemImage: autoScroll ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Clear") { server.clearLogs() }
                    .controlSize(.small)
                    .disabled(server.logs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.background)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(server.logs) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                            Divider()
                                .opacity(0.35)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay {
                    if server.logs.isEmpty {
                        ContentUnavailableView(
                            "No Log Events",
                            systemImage: "list.bullet.rectangle",
                            description: Text("SMTP activity will appear here when clients connect.")
                        )
                    }
                }
                .onChange(of: server.logs.count) { _, _ in
                    if autoScroll, let last = server.logs.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle("Server Logs")
    }
}

private extension LogEntry.Direction {
    var label: String {
        switch self {
        case .inbound:  return "CLIENT"
        case .outbound: return "SERVER"
        case .system:   return "SYSTEM"
        }
    }

    var color: Color {
        switch self {
        case .inbound:  return .blue
        case .outbound: return .green
        case .system:   return .secondary
        }
    }
}

struct LogEntryRow: View {
    let entry: LogEntry
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.timestampFormatter.string(from: entry.date))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
            Text(entry.direction.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(entry.direction.color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .frame(width: 58)
                .background(entry.direction.color.opacity(0.12), in: Capsule())
            Text(entry.message)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}
