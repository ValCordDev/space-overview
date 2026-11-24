import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
    }
    static let amber = Color(hex: 0xF5A524), onAmber = Color(hex: 0x1A1204), page = Color(hex: 0x120D0A), card = Color(hex: 0x1B1511)
    static let line = Color(hex: 0x33291F), ink = Color(hex: 0xF3ECE2), dim = Color(hex: 0xA99D8F), edge = Color(hex: 0x73665A)
    static let picked = Color(hex: 0x3A280F), dataPart = Color(hex: 0xA9660F), cachePart = Color(hex: 0xF3ECE2), danger = Color(hex: 0xFF9B93)
}

func bytes(_ n: UInt64) -> String { Int64(clamping: n).formatted(.byteCount(style: .file)) }

struct Row: Identifiable { let entry: Entry, depth: Int, share: Double; var id: String { entry.id } }

enum Page: String, CaseIterable { case home = "Home", disk = "Macintosh HD", apps = "Apps", map = "Map", largest = "Largest files", oldest = "Oldest files" }

@MainActor final class Model: ObservableObject {
    @Published var page = Page.home
    @Published var filter = ""
    @Published var mapPath = NSHomeDirectory()
    @Published var selected: Entry?
    @Published var selectedApp: String?
    @Published var expanded: Set<String> = []
    @Published var items: UInt64 = 0
    @Published var found: UInt64 = 0
    @Published var denied: UInt64 = 0
    @Published var scanning = false
    @Published var ready = false
    @Published var needsAccess = !hasFullDiskAccess()
    @Published var apps: [AppUsage] = []
    @Published var big: [Entry] = []
    @Published var trashPlan: TrashPlan?
    @Published var namePrompt: NamePrompt?
    @Published var notice: String?
    @Published var lastTrash: [Trashed] = []
    private(set) var engine: Engine?
    private var cache: [String: [Entry]] = [:]

    func scan() {
        guard !scanning else { return }
        needsAccess = false
        scanning = true; ready = false
        cache = [:]; selected = nil; lastTrash = []; notice = nil
        let e = Engine()
        engine = e
        Task {
            while true {
                let p = e.progress
                (items, found, denied) = (p.items, p.bytes, p.denied)
                if p.done { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            let (a, b) = await Task.detached { (findApps(e), e.largeFiles()) }.value
            (apps, big) = (a, b)
            scanning = false; ready = true
        }
    }
    /// Shows changes made on disk by this app without scanning again.
    func refresh() {
        cache = [:]
        guard let e = engine else { return }
        Task {
            let (a, b) = await Task.detached { (findApps(e), e.largeFiles()) }.value
            if engine === e { (apps, big) = (a, b) }
        }
    }
    var root: Entry? { engine?.entry(page == .disk ? "/" : NSHomeDirectory()) }
    func children(_ e: Entry) -> [Entry] {
        if let c = cache[e.path] { return c }
        let c = engine?.children(of: e) ?? []
        cache[e.path] = c
        return c
    }
    func toggle(_ e: Entry) {
        guard e.isFolder else { return }
        if expanded.remove(e.path) == nil { expanded.insert(e.path) }
    }
    func tree(_ root: Entry) -> [Row] {
        var out: [Row] = []
        func walk(_ e: Entry, _ depth: Int) {
            for c in children(e) {
                let open = c.isFolder && expanded.contains(c.path)
                if open || filter.isEmpty || c.name.localizedCaseInsensitiveContains(filter) {
                    out.append(Row(entry: c, depth: depth, share: e.size == 0 ? 0 : min(1, Double(c.size) / Double(e.size))))
                }
                if open { walk(c, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }
    func flat() -> [Row] {
        let hits = big.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        let sorted = page == .largest ? hits.sorted { $0.size > $1.size } : hits.filter { $0.size >= 10_000_000 }.sorted { $0.modified < $1.modified }
        let top = Double(sorted.prefix(300).map(\.size).max() ?? 1)
        return sorted.prefix(300).map { Row(entry: $0, depth: 0, share: Double($0.size) / top) }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}

struct Outline: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 13).frame(height: 34)
            .background(configuration.isPressed ? Color.line : Color.card, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.edge))
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Color.line.frame(width: 1)
            VStack(spacing: 0) { Notice(); Group {
                if m.needsAccess { AccessView() }
                else if !m.ready { ScanningView() }
                else if m.page == .apps { AppsView() }
                else if m.page == .map { MapView() }
                else { FilesView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .sheet(item: $m.trashPlan) { TrashSheet(plan: $0) }
        .sheet(item: $m.namePrompt) { NameSheet(prompt: $0) }
        .background(Color.page).foregroundStyle(Color.ink).tint(.amber).preferredColorScheme(.dark)
        .frame(minWidth: 1080, minHeight: 560)
        .onAppear { 
            // `--scan Apps` skips the access screen and opens a page, for checking the UI.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--scan") {
                m.page = i + 1 < args.count ? Page(rawValue: args[i + 1]) ?? .home : .home
                m.expanded = [NSHomeDirectory() + "/Library"]
                m.scan()
                // `--preview` opens the first app's uninstall sheet; nothing is moved.
                if args.contains("--preview") {
                    Task { while !m.ready { try? await Task.sleep(for: .seconds(1)) }; if let a = m.apps.first(where: { runningApp(in: $0.path) == nil }) { m.selectedApp = a.id; m.askUninstall(a) } }
                }
            } else if !m.needsAccess && !m.ready { m.scan() }
         }
    }
}

struct Sidebar: View {
    @EnvironmentObject var m: Model
    private var disk: (free: UInt64, total: UInt64) {
        let a = try? FileManager.default.attributesOfFileSystem(forPath: dataRoot)
        return ((a?[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0, (a?[.systemSize] as? NSNumber)?.uint64Value ?? 1)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            heading("Locations"); item(.home, "house"); item(.disk, "internaldrive")
            heading("Explore").padding(.top, 14); item(.apps, "square.grid.2x2"); item(.map, "rectangle.split.2x2"); item(.largest, "arrow.down.doc"); item(.oldest, "clock")
            Spacer()
            let d = disk
            VStack(alignment: .leading, spacing: 8) {
                Bar(share: 1 - Double(d.free) / Double(max(1, d.total)), height: 8)
                Text(bytes(d.free) + " free").bold() + Text(" of " + bytes(d.total)).foregroundColor(.dim)
            }.padding(10)
        }
        .padding(12).frame(width: 215).frame(maxHeight: .infinity).background(Color.card)
    }
    func heading(_ t: String) -> some View { Text(t).font(.callout.weight(.semibold)).foregroundStyle(Color.dim).padding(10) }
    func item(_ p: Page, _ icon: String) -> some View {
        let on = m.page == p
        return Button { m.page = p; m.selected = nil } label: {
            Label(p.rawValue, systemImage: icon).fontWeight(on ? .bold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(.rect)
                .background(on ? Color.amber : .clear, in: .rect(cornerRadius: 8)).foregroundStyle(on ? Color.onAmber : .ink)
        }.buttonStyle(.plain)
    }
}

struct Bar: View {
    let share: Double
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Color.line
                Color.amber.frame(width: g.size.width * max(0, min(1, share)))
            }
        }.frame(height: height).clipShape(.rect(cornerRadius: 3)).accessibilityHidden(true)
    }
}

struct AccessView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow Full Disk Access").font(.title.bold())
            Text("Without it, macOS hides some folders and may ask about each one. Turn on Space Overview in System Settings, then reopen the app.")
                .foregroundStyle(Color.dim).frame(maxWidth: 430, alignment: .leading)
            HStack {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }.buttonStyle(Outline())
                Button("Scan anyway") { m.scan() }.buttonStyle(Outline())
            }
        }
    }
}

struct ScanningView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(bytes(m.found)).font(.largeTitle.bold()).monospacedDigit()
            Text("\(m.items.formatted()) items scanned").foregroundStyle(Color.dim).monospacedDigit()
        }
    }
}

struct Header: View {
    @EnvironmentObject var m: Model
    let title: String, detail: String
    var reveal: String?
    var edits = false
    var searches = true
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.title2.bold())
            Text(detail).font(.title2).lineLimit(1).foregroundStyle(Color.dim)
            Spacer()
            if searches { TextField("Filter by name", text: $m.filter).textFieldStyle(.plain).padding(.horizontal, 11).frame(minWidth: 90, maxWidth: 180).frame(height: 34)
                .background(Color.card, in: .rect(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.edge)) }
            if edits {
                let locked = m.selectedLock() != nil
                if m.page == .home || m.page == .disk {
                    let target = m.newFolderTarget()
                    let off = target.map { lockReason($0.path + "/untitled") != nil } ?? true
                    Button("New folder") { if let target { m.namePrompt = NamePrompt(entry: target, isNew: true) } }.buttonStyle(Outline())
                        .disabled(off).opacity(off ? 0.5 : 1)
                }
                Button("Rename") { if let s = m.selected { m.namePrompt = NamePrompt(entry: s, isNew: false) } }.buttonStyle(Outline())
                    .disabled(locked).opacity(locked ? 0.5 : 1)
                Button("Move to Trash") { m.askTrash() }.buttonStyle(Danger()).keyboardShortcut(.delete)
                    .disabled(locked).opacity(locked ? 0.5 : 1)
            }
            Button("Show in Finder") { if let reveal { m.reveal(reveal) } }.buttonStyle(Outline()).disabled(reveal == nil).opacity(reveal == nil ? 0.5 : 1)
            Button("Rescan") { m.scan() }.buttonStyle(Outline())
        }.padding(18).overlay(alignment: .bottom) { Color.line.frame(height: 1) }
    }
}

struct FilesView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        let isTree = m.page == .home || m.page == .disk
        let root = isTree ? m.root : nil
        let rows = root.map(m.tree) ?? m.flat()
        VStack(spacing: 0) {
            Header(title: m.page.rawValue, detail: isTree ? bytes(root?.size ?? 0) : "top 300",
                   reveal: m.selected.flatMap { $0.grouped ? nil : $0.path }, edits: true)
            columns("Name", "Size", isTree ? "Share of parent" : "Compared with largest", "Items", "Modified").foregroundStyle(Color.dim).fontWeight(.semibold)
                .padding(.vertical, 10)
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(rows) { RowView(row: $0, showsPath: !isTree) } }
                if rows.isEmpty { Text("Nothing to show").foregroundStyle(Color.dim).padding(40) }
            }
            footer
        }
    }
    func columns(_ a: String, _ b: String, _ c: String, _ d: String, _ e: String) -> some View {
        HStack(spacing: 14) {
            Text(a).frame(maxWidth: .infinity, alignment: .leading); Text(b).frame(width: 84, alignment: .trailing)
            Text(c).frame(width: 210, alignment: .leading); Text(d).frame(width: 78, alignment: .trailing); Text(e).frame(width: 92, alignment: .leading)
        }.padding(.horizontal, 20)
    }
    var footer: some View {
        HStack {
            if let s = m.selected {
                Text(s.name).bold()
                Text("\(bytes(s.size)) on disk, \(s.items.formatted()) items").foregroundStyle(Color.dim)
            } else { Text("Select something to see its details").foregroundStyle(Color.dim) }
            Spacer()
            if m.selected != nil, let why = m.selectedLock() { Image(systemName: "lock"); Text(why).foregroundStyle(Color.dim) }
            if m.denied > 0 { Text("\(m.denied.formatted()) folders couldn't be read").foregroundStyle(Color.dim) }
        }.lineLimit(1).padding(16).background(Color.card).overlay(alignment: .top) { Color.line.frame(height: 1) }
    }
}

struct RowView: View {
    @EnvironmentObject var m: Model
    let row: Row, showsPath: Bool
    var body: some View {
        let e = row.entry
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Button { m.toggle(e) } label: {
                    Image(systemName: "chevron.right").font(.caption.bold()).rotationEffect(.degrees(m.expanded.contains(e.path) ? 90 : 0))
                        .frame(width: 18, height: 30).contentShape(.rect)
                }.buttonStyle(.plain).foregroundStyle(Color.dim).opacity(e.isFolder ? 1 : 0).disabled(!e.isFolder)
                    .accessibilityLabel(m.expanded.contains(e.path) ? "Collapse" : "Expand")
                Image(systemName: e.denied ? "lock" : e.isFolder ? "folder.fill" : "doc").foregroundStyle(Color.dim).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.name).fontWeight(row.depth == 0 ? .semibold : .regular)
                    if showsPath { Text((e.path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(Color.dim).truncationMode(.middle) }
                }.lineLimit(1)
            }.padding(.leading, CGFloat(row.depth) * 20).frame(maxWidth: .infinity, alignment: .leading)
            Text(bytes(e.size)).bold().frame(width: 84, alignment: .trailing)
            HStack(spacing: 8) {
                Bar(share: row.share)
                Text(row.share.formatted(.percent.precision(.fractionLength(0)))).frame(width: 40, alignment: .trailing)
            }.frame(width: 210)
            Text(e.items.formatted()).frame(width: 78, alignment: .trailing).foregroundStyle(Color.dim)
            Text(e.grouped ? "" : e.modified.formatted(.dateTime.day().month(.abbreviated).year())).frame(width: 92, alignment: .leading).foregroundStyle(Color.dim)
        }
        .monospacedDigit().padding(.horizontal, 20).frame(height: 44).contentShape(.rect)
        .background(m.selected?.id == e.id ? Color.picked : .clear)
        .overlay(alignment: .bottom) { Color.line.opacity(0.6).frame(height: 1) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { m.toggle(e) })
        .simultaneousGesture(TapGesture().onEnded { m.selected = e })
        .accessibilityAddTraits(m.selected?.id == e.id ? .isSelected : [])
        .help(e.grouped ? e.name : e.path)
    }
}

struct AppsView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        let apps = m.apps.filter { m.filter.isEmpty || $0.name.localizedCaseInsensitiveContains(m.filter) }
        let top = Double(max(1, m.apps.first?.upTo ?? 1))
        let chosen = apps.first { $0.id == m.selectedApp } ?? apps.first
        VStack(spacing: 0) {
            Header(title: "Apps", detail: "\(m.apps.count)", reveal: chosen?.path)
            HStack(spacing: 18) { key("App", .amber); key("Data", .dataPart); key("Caches", .cachePart); key("Possible match, not in total", .edge); Spacer() }.padding(.horizontal, 20).padding(.vertical, 10)
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(apps) { a in
                            Button { m.selectedApp = a.id } label: { line(a, top, a.id == chosen?.id) }.buttonStyle(.plain)
                        }
                    }
                }
                if let chosen { Color.line.frame(width: 1); detail(chosen).frame(width: 320) }
            }
        }
    }
    func key(_ t: String, _ c: Color) -> some View { HStack(spacing: 6) { c.frame(width: 11, height: 11); Text(t).foregroundStyle(Color.dim) } }
    func line(_ a: AppUsage, _ top: Double, _ on: Bool) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 30, height: 30)
            Text(a.name).fontWeight(.semibold).lineLimit(1).frame(width: 205, alignment: .leading)
            GeometryReader { g in
                HStack(spacing: 0) {
                    Color.amber.frame(width: g.size.width * Double(a.size(.app)) / top)
                    Color.dataPart.frame(width: g.size.width * Double(a.size(.data)) / top)
                    Color.cachePart.frame(width: g.size.width * Double(a.size(.cache)) / top)
                    Color.edge.frame(width: g.size.width * Double(a.size(.possible)) / top)
                }
            }.frame(height: 14).accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 1) {
                Text(bytes(a.total)).bold()
                if a.size(.possible) > 0 { Text("+ " + bytes(a.size(.possible))).font(.caption).foregroundStyle(Color.dim) }
            }.monospacedDigit().frame(width: 84, alignment: .trailing)
        }.padding(.horizontal, 20).frame(height: 52).contentShape(.rect).background(on ? Color.picked : .clear)
            .overlay(alignment: .bottom) { Color.line.opacity(0.6).frame(height: 1) }
    }
    func detail(_ a: AppUsage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(a.name).font(.title2.bold())
                Text(bytes(a.total)).font(.system(size: 38, weight: .semibold)).monospacedDigit()
                ForEach(a.parts.sorted { $0.size > $1.size }) { p in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.kind.rawValue).fontWeight(.semibold)
                            Text((p.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(Color.dim).textSelection(.enabled)
                        }
                        Spacer()
                        Text(bytes(p.size)).monospacedDigit()
                        Button { m.reveal(p.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).accessibilityLabel("Show in Finder")
                    }.padding(.vertical, 5)
                    Color.line.frame(height: 1)
                }
                HStack {
                    if a.size(.cache) > 0 { Button("Clear caches") { m.askUninstall(a, cachesOnly: true) }.buttonStyle(Outline()) }
                    Button("Uninstall") { m.askUninstall(a) }.buttonStyle(Danger())
                }
                if a.size(.possible) > 0 {
                    Text("Possible matches may be shared with other apps and aren't counted in the total.").font(.callout).foregroundStyle(Color.dim)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color.card)
    }
}
