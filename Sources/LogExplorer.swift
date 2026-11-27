import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

enum LogLevel: String, CaseIterable, Identifiable {
    case info = "INFO", warn = "WARN", error = "ERROR"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
    var tint: Color {
        switch self {
        case .info: .secondary
        case .warn: .orange
        case .error: .red
        }
    }
}

struct LogEntry: Identifiable, Hashable {
    let id: Int
    let date: Date
    let level: LogLevel
    let message: String          // first line
    let details: String          // following lines (wg-quick output etc.)
    let tunnels: [String]
    var fullText: String { details.isEmpty ? message : "\(message)\n\(details)" }
}

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []   // newest first
    @Published var live = true
    private var signature = ""
    private var timer: Timer?

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let lineStart = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}T[0-9:.]+Z) (INFO|WARN|ERROR)\s+(.*)$"#)

    var files: [URL] { [Log.file.appendingPathExtension("1"), Log.file] }  // oldest → newest

    init() {
        reload(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.live == true { self?.reload() } }
        }
    }

    deinit { timer?.invalidate() }

    /// Re-parse only when size/mtime of either file changed.
    func reload(force: Bool = false) {
        let fm = FileManager.default
        let sig = files.map { url -> String in
            let a = try? fm.attributesOfItem(atPath: url.path)
            return "\(a?[.size] ?? 0)-\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        guard force || sig != signature else { return }
        signature = sig

        let text = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        let names = listTunnels().map(\.name)
        var out: [LogEntry] = []
        var cur: (Date, LogLevel, String, [String])?

        func flush() {
            guard let c = cur else { return }
            let details = c.3.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let all = c.2 + " " + details
            let tunnels = names.filter { n in
                all.range(of: "(^|[^A-Za-z0-9_=+.-])\(NSRegularExpression.escapedPattern(for: n))([^A-Za-z0-9_=+-]|$)",
                          options: .regularExpression) != nil
            }
            out.append(LogEntry(id: out.count, date: c.0, level: c.1, message: c.2, details: details, tunnels: tunnels))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let ns = s as NSString
            if let m = Self.lineStart.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                flush()
                let ts = ns.substring(with: m.range(at: 1))
                let date = Self.isoFrac.date(from: ts) ?? Self.iso.date(from: ts) ?? .distantPast
                cur = (date, LogLevel(rawValue: ns.substring(with: m.range(at: 2))) ?? .info,
                       ns.substring(with: m.range(at: 3)), [])
            } else if cur != nil {
                cur!.3.append(s)
            }
        }
        flush()
        entries = out.reversed()
    }

    func clear() {
        Log.queue.sync {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        Log.info("log cleared")
        Log.queue.sync {}
        reload(force: true)
    }
}

// MARK: - View

struct LogExplorerView: View {
    @StateObject private var store = LogStore()
    @State private var query = ""
    @State private var levels: Set<LogLevel> = Set(LogLevel.allCases)
    @State private var tunnel = "All Tunnels"
    @State private var selection: LogEntry.ID?
    @State private var confirmClear = false

    private var tunnelOptions: [String] {
        ["All Tunnels"] + Array(Set(store.entries.flatMap(\.tunnels) + listTunnels().map(\.name))).sorted()
    }

    private var filtered: [LogEntry] {
        store.entries.filter { e in
            levels.contains(e.level)
                && (tunnel == "All Tunnels" || e.tunnels.contains(tunnel))
                && (query.isEmpty || e.fullText.localizedCaseInsensitiveContains(query))
        }
    }

    private var selected: LogEntry? { selection.flatMap { id in store.entries.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            VSplitView {
                list.frame(minHeight: 180)
                detail.frame(minHeight: 110, idealHeight: 170)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 760, minHeight: 460)
        .searchable(text: $query, placement: .toolbar, prompt: "Search logs")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $store.live) { Label("Live", systemImage: store.live ? "dot.radiowaves.left.and.right" : "pause.circle") }
                    .help(store.live ? "Live updates on" : "Live updates paused")
                Button { copy(filtered) } label: { Label("Copy Visible", systemImage: "doc.on.doc") }
                    .help("Copy all visible entries")
                Button(action: export) { Label("Export…", systemImage: "square.and.arrow.up") }
                    .help("Export visible entries to a file")
                Button { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }.help("Show log file in Finder")
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear", systemImage: "trash") }
                    .help("Delete all log entries")
            }
        }
        .confirmationDialog("Clear all logs?", isPresented: $confirmClear) {
            Button("Clear Logs", role: .destructive) { store.clear(); selection = nil }
        } message: { Text("This deletes wgtoggle.log and its backup.") }
    }

    private var filterBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(LogLevel.allCases) { lvl in
                    let n = store.entries.filter { $0.level == lvl }.count
                    Toggle(isOn: Binding(
                        get: { levels.contains(lvl) },
                        set: { on in if on { levels.insert(lvl) } else { levels.remove(lvl) } })) {
                        Label("\(lvl.label)  \(n)", systemImage: lvl.symbol)
                            .foregroundStyle(levels.contains(lvl) ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    }
                    .toggleStyle(.button)
                    .tint(lvl == .info ? .gray : lvl.tint)   // on-state fill = level color, not the accent
                    .help("Show \(lvl.label.lowercased()) entries")
                }
            }
            Divider().frame(height: 18)
            Picker("Tunnel", selection: $tunnel) {
                ForEach(tunnelOptions, id: \.self) { Text($0) }
            }
            .frame(maxWidth: 220)
            Spacer()
            if levels.count < LogLevel.allCases.count || tunnel != "All Tunnels" || !query.isEmpty {
                Button("Reset Filters") { levels = Set(LogLevel.allCases); tunnel = "All Tunnels"; query = "" }
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var list: some View {
        if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: store.entries.isEmpty ? "doc.text" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                Text(store.entries.isEmpty ? "No log entries yet" : "No entries match the filters")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filtered, selection: $selection) { e in
                LogRow(entry: e).tag(e.id)
                    .contextMenu {
                        Button("Copy Entry") { copy([e]) }
                        Button("Copy Message") { setPasteboard(e.message) }
                        if let t = e.tunnels.first { Button("Show Only \(t)") { tunnel = t } }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e = selected {
                HStack(spacing: 8) {
                    LevelBadge(level: e.level)
                    Text(e.date.formatted(date: .abbreviated, time: .standard))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    ForEach(e.tunnels, id: \.self) { TunnelChip(name: $0) }
                    Spacer()
                    Button { copy([e]) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                ScrollView {
                    Text(e.fullText)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                Text("Select an entry to see its details")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var statusBar: some View {
        HStack {
            Text("\(filtered.count) of \(store.entries.count) entries")
            Spacer()
            if store.live { Circle().fill(.green).frame(width: 6, height: 6); Text("Live") } else { Text("Paused") }
            Text("·")
            Text(demoMode ? "~/Library/Logs/WGToggle/wgtoggle.log" : Log.file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    // MARK: Actions

    private func render(_ entries: [LogEntry]) -> String {
        entries.reversed().map { e in
            "\(Log.stamp.string(from: e.date)) \(e.level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(e.fullText)"
        }.joined(separator: "\n")
    }

    private func copy(_ entries: [LogEntry]) { setPasteboard(render(entries)) }

    private func setPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .log]
        panel.nameFieldStringValue = "wgtoggle-\(Date().formatted(.iso8601.year().month().day())).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try render(filtered).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - Row pieces

struct LogRow: View {
    let entry: LogEntry
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timeString(entry.date))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            LevelBadge(level: entry.level).frame(width: 64, alignment: .leading)
            Text(entry.message)
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(entry.level == .error ? Color.red : .primary)
            Spacer(minLength: 4)
            ForEach(entry.tunnels.prefix(2), id: \.self) { TunnelChip(name: $0) }
            if !entry.details.isEmpty {
                let n = entry.details.split(separator: "\n").count
                Text("+\(n)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("\(n) more line\(n == 1 ? "" : "s")")
            }
        }
        .padding(.vertical, 2)
    }

    private func timeString(_ d: Date) -> String {
        Calendar.current.isDateInToday(d)
            ? "Today " + d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
            : d.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute().second())
    }
}

struct LevelBadge: View {
    let level: LogLevel
    var body: some View {
        Label(level.rawValue, systemImage: level.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(level.tint)
    }
}

struct TunnelChip: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.caption.monospaced())
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}

// MARK: - Window

@MainActor
enum LogExplorer {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "WGToggle Logs"
            w.toolbarStyle = .unified
            w.toolbar = NSToolbar(identifier: "logs")
            w.contentViewController = NSHostingController(rootView: LogExplorerView())
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("LogExplorer")
            if !w.setFrameUsingName("LogExplorer") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
