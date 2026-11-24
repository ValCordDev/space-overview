import Foundation

/// Scanned volume. "/System/Volumes/Data" holds everything except the sealed macOS system.
let dataRoot = "/System/Volumes/Data"

struct Entry: Identifiable, Hashable {
    let path: String, name: String
    let size: UInt64, items: UInt64
    let modified: Date
    let node: UInt32
    var parent: UInt32 = UInt32.max
    let denied: Bool
    var grouped = false
    var id: String { path }
    var isFolder: Bool { node != UInt32.max }
}

private final class Collector {
    var rows: [(name: String, size: UInt64, items: UInt64, mtime: Int64, id: UInt32, parent: UInt32, denied: Bool)] = []
    static let callback: SoCallback = { ctx, e in
        let e = e!.pointee
        let name = String(decoding: UnsafeBufferPointer(start: e.name, count: Int(e.name_len)), as: UTF8.self)
        Unmanaged<Collector>.fromOpaque(ctx!).takeUnretainedValue()
            .rows.append((name, e.size, e.items, e.mtime, e.id, e.parent, e.denied))
    }
    var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

/// Owns one Rust scan. Read-only once finished, so it is safe to share between threads.
final class Engine: @unchecked Sendable {
    private let raw: OpaquePointer
    init() { raw = so_scan_start(dataRoot, UInt32(min(8, ProcessInfo.processInfo.activeProcessorCount))) }
    deinit { so_scan_free(raw) }

    var progress: SoProgress {
        var p = SoProgress()
        so_scan_progress(raw, &p)
        return p
    }
    func find(_ path: String) -> UInt32 { so_find(raw, path) }

    func entry(_ path: String) -> Entry? {
        let node = find(path)
        guard node != UInt32.max else { return nil }
        let c = Collector()
        guard so_entry(raw, node, c.pointer, Collector.callback), let r = c.rows.first else { return nil }
        return Entry(path: path, name: path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent, size: r.size,
                     items: r.items, modified: Date(timeIntervalSince1970: Double(r.mtime)), node: node, parent: r.parent, denied: r.denied)
    }
    func folders(in e: Entry) -> [Entry] {
        let c = Collector()
        so_child_dirs(raw, e.node, c.pointer, Collector.callback)
        return rows(c, e.path)
    }
    /// Folders and files, largest first. Beyond 500 files the rest become one row.
    func children(of e: Entry) -> [Entry] {
        let c = Collector()
        so_child_files(raw, e.node, c.pointer, Collector.callback)
        var files = rows(c, e.path).sorted { $0.size > $1.size }
        if files.count > 500 {
            let rest = files[500...]
            files = Array(files[..<500])
            files.append(Entry(path: e.path + "/\u{0}rest", name: "\(rest.count.formatted()) smaller files", size: rest.reduce(0) { $0 + $1.size },
                               items: UInt64(rest.count), modified: e.modified, node: UInt32.max, denied: false, grouped: true))
        }
        return (folders(in: e) + files).sorted { $0.size > $1.size }
    }
    func largeFiles() -> [Entry] {
        let c = Collector()
        so_large_files(raw, c.pointer, Collector.callback)
        return c.rows.map { r in
            // Parent is resolved lazily through folderPath to keep this quick.
            Entry(path: folderPath(r.parent) + "/" + r.name, name: r.name, size: r.size, items: 1,
                  modified: Date(timeIntervalSince1970: Double(r.mtime)), node: UInt32.max, parent: r.parent, denied: false)
        }
    }
    func mark(_ e: Entry, gone: Bool) {
        if e.isFolder { so_set_dir_gone(raw, e.node, gone) } else { so_set_file_gone(raw, e.parent, e.name, e.size, gone) }
    }
    func renamed(_ e: Entry, to name: String) {
        if e.isFolder { so_rename_dir(raw, e.node, name) } else { so_rename_file(raw, e.parent, e.name, name) }
    }
    func addFolder(_ name: String, in e: Entry) { so_add_dir(raw, e.node, name, Int64(Date().timeIntervalSince1970)) }
    private func folderPath(_ id: UInt32) -> String {
        var parts: [String] = [], id = id
        while id != 0 {
            let c = Collector()
            guard so_entry(raw, id, c.pointer, Collector.callback), let r = c.rows.first else { break }
            parts.append(r.name)
            id = r.parent
        }
        return parts.isEmpty ? "" : "/" + parts.reversed().joined(separator: "/")
    }
    private func rows(_ c: Collector, _ parent: String) -> [Entry] {
        let base = parent == "/" ? "" : parent
        return c.rows.map { Entry(path: base + "/" + $0.name, name: $0.name, size: $0.size, items: $0.items,
                                  modified: Date(timeIntervalSince1970: Double($0.mtime)), node: $0.id, parent: $0.parent, denied: $0.denied) }
    }
}

struct AppPart: Identifiable {
    enum Kind: String { case app = "App", data = "Data", cache = "Caches", possible = "Possible match" }
    let kind: Kind, path: String, size: UInt64
    var id: String { path }
}

struct AppUsage: Identifiable {
    let path: String, name: String, bundleID: String
    var parts: [AppPart]
    var id: String { path }
    func size(_ k: AppPart.Kind) -> UInt64 { parts.filter { $0.kind == k }.reduce(0) { $0 + $1.size } }
    var upTo: UInt64 { total + size(.possible) }
    /// Confirmed space only; name-based guesses are not included.
    var total: UInt64 { parts.filter { $0.kind != .possible }.reduce(0) { $0 + $1.size } }
}

/// Bundle-ID matches are confirmed. Name matches and shared group containers are only "possible".
func findApps(_ engine: Engine, home: String = NSHomeDirectory()) -> [AppUsage] {
    var apps: [AppUsage] = []
    func add(_ e: Entry, _ owned: Entry) {
        let info = NSDictionary(contentsOfFile: e.path + "/Contents/Info.plist")
        let id = info?["CFBundleIdentifier"] as? String ?? ""
        apps.append(AppUsage(path: e.path, name: String(e.name.dropLast(4)), bundleID: id,
                             parts: [AppPart(kind: .app, path: owned.path, size: owned.size)]))
    }
    for base in ["/Applications", home + "/Applications"] {
        guard let root = engine.entry(base) else { continue }
        for e in engine.folders(in: root) {
            if e.name.hasSuffix(".app") { add(e, e); continue }
            // A folder named after its app (Adobe does this) belongs to that app as a whole.
            let inside = engine.folders(in: e).filter { $0.name.hasSuffix(".app") }
            let main = inside.first { $0.name == e.name + ".app" }
            if let main { add(main, e) } else { inside.forEach { add($0, $0) } }
        }
    }
    apps.sort { $0.path.count < $1.path.count }
    var sameID: [String: Int] = [:]
    for a in apps { sameID[a.bundleID.lowercased(), default: 0] += 1 }
    var byID: [String: Int] = [:], byName: [String: [Int]] = [:]
    for (i, a) in apps.enumerated() {
        if !a.bundleID.isEmpty, byID[a.bundleID.lowercased()] == nil { byID[a.bundleID.lowercased()] = i }
        byName[a.name.lowercased(), default: []].append(i)
    }
    /// Exact ID, or the longest installed ID that is a dotted prefix (extensions and helpers).
    func owner(_ name: String) -> Int? {
        var n = name.lowercased()
        if n.hasSuffix(".savedstate") { n = String(n.dropLast(11)) }
        if let i = byID[n] { return i }
        while n.split(separator: ".").count >= 3 {
            if let i = byID[n] { return i }
            guard let dot = n.lastIndex(of: ".") else { return nil }
            n = String(n[..<dot])
        }
        return nil
    }
    let places: [(String, AppPart.Kind)] = [
        ("Containers", .data), ("Application Support", .data), ("Caches", .cache), ("Logs", .data), ("HTTPStorages", .data),
        ("WebKit", .data), ("Saved Application State", .data), ("Application Scripts", .data)]
    for (place, kind) in places {
        guard let root = engine.entry(home + "/Library/" + place) else { continue }
        for e in engine.folders(in: root) where e.size > 0 {
            if let i = owner(e.name) {
                // Two installed copies share one ID, so the data isn't only this copy's.
                let shared = sameID[apps[i].bundleID.lowercased(), default: 0] > 1
                apps[i].parts.append(AppPart(kind: shared ? .possible : kind, path: e.path, size: e.size))
            } else if let hits = byName[e.name.lowercased()], hits.count == 1 {
                apps[hits[0]].parts.append(AppPart(kind: .possible, path: e.path, size: e.size))
            }
        }
    }
    for i in apps.indices where !apps[i].bundleID.isEmpty && !apps[i].bundleID.contains("/") && sameID[apps[i].bundleID.lowercased()] == 1 {
        let p = home + "/Library/Preferences/" + apps[i].bundleID + ".plist"
        var st = stat()
        if lstat(p, &st) == 0 { apps[i].parts.append(AppPart(kind: .data, path: p, size: UInt64(st.st_blocks) * 512)) }
    }
    if let root = engine.entry(home + "/Library/Group Containers") {
        for e in engine.folders(in: root) where e.size > 0 {
            var parts = e.name.split(separator: ".").map(String.init)
            while parts.count >= 2 {
                if let i = owner(parts.joined(separator: ".")) {
                    apps[i].parts.append(AppPart(kind: .possible, path: e.path, size: e.size))
                    break
                }
                parts.removeFirst()
            }
        }
    }
    return apps.sorted { $0.upTo > $1.upTo }
}

func hasFullDiskAccess() -> Bool {
    let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
    if fd >= 0 { close(fd) }
    return fd >= 0
}
