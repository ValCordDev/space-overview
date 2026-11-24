import AppKit

struct Problem: Error { let text: String }

/// Device and inode, so a confirmed delete hits the same item that was previewed.
struct Stamp: Equatable {
    let dev: Int32, inode: UInt64
    init?(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        (dev, inode) = (st.st_dev, st.st_ino)
    }
}

struct Trashed {
    let original: String, trash: String
    let entry: Entry?
}

func measure(_ path: String) -> SoMeasure {
    var m = SoMeasure()
    so_measure(path, &m)
    return m
}

private let lockedHome: Set<String> = ["library", "documents", "desktop", "downloads", "movies", "music", "pictures", "public", "applications", ".trash"]
private let lockedLibrary: Set<String> = [
    "application scripts", "application support", "caches", "containers", "group containers", "preferences", "logs", "developer", "fonts",
    "httpstorages", "webkit", "saved application state", "launchagents", "keychains", "mail", "messages", "calendars", "safari", "cookies",
    "mobile documents", "cloudstorage", "accounts", "photos", "services", "metadata", "sharing", "identityservices", "daemon containers"]
private let sealedLibrary: Set<String> = ["keychains", "mobile documents", "cloudstorage", "accounts", "daemon containers"]
private let packages = [".app", ".photoslibrary", ".musiclibrary", ".tvlibrary", ".framework"]

private func real(_ path: String) -> String? {
    guard let p = realpath(path, nil) else { return nil }
    defer { free(p) }
    return String(cString: p)
}

/// Why a path must not be changed, or nil when it may be. Only your home folder and
/// the contents of /Applications are ever allowed.
func lockReason(_ path: String, home: String = NSHomeDirectory(), own: String = Bundle.main.bundlePath) -> String? {
    let url = path as NSString
    guard path.hasPrefix("/"), !path.contains("\0"), !["", ".", "..", "/"].contains(url.lastPathComponent),
          let parent = real(url.deletingLastPathComponent) else { return "This item can't be found." }
    // The parent is resolved, so a link can't lead outside the allowed folders.
    let full = (parent == "/" ? "" : parent) + "/" + url.lastPathComponent
    let low = full.lowercased(), homeLow = (real(home) ?? home).lowercased()
    let parts: [String]
    if low.hasPrefix(homeLow + "/") {
        parts = low.dropFirst(homeLow.count + 1).split(separator: "/").map(String.init)
        if parts.count == 1, lockedHome.contains(parts[0]) { return "This is one of your main folders." }
        if parts[0] == ".trash" { return "This is already in the Trash." }
        if parts[0] == "library", parts.count >= 2 {
            if sealedLibrary.contains(parts[1]) { return "macOS or a cloud service manages this." }
            if parts.count == 2, lockedLibrary.contains(parts[1]) { return "macOS needs this folder." }
            if parts.count == 3, parts[2].hasPrefix("com.apple.tcc") { return "macOS manages this." }
        }
    } else if low.hasPrefix("/applications/") {
        parts = low.dropFirst("/applications/".count).split(separator: "/").map(String.init)
    } else {
        return "System locations are locked."
    }
    if parts.dropLast().contains(where: { p in packages.contains { p.hasSuffix($0) } }) {
        return "Changing files inside an app or library can break it."
    }
    let ownLow = (real(own) ?? own).lowercased()
    if ownLow == low || ownLow.hasPrefix(low + "/") { return "Space Overview is stored here." }
    return nil
}

/// A running app at this path or inside it.
func runningApp(in path: String) -> String? {
    let target = (real(path) ?? path).lowercased()
    for a in NSWorkspace.shared.runningApplications {
        guard let u = a.bundleURL else { continue }
        let p = (real(u.path) ?? u.path).lowercased()
        if p == target || p.hasPrefix(target + "/") { return a.localizedName ?? u.lastPathComponent }
    }
    return nil
}

func checkChange(_ path: String) throws {
    if let r = lockReason(path) { throw Problem(text: r) }
    if let a = runningApp(in: path) { throw Problem(text: "Quit \(a) first.") }
}

/// Moves to the Trash. Never deletes permanently.
func moveToTrash(_ path: String, expecting: Stamp) throws -> String {
    try checkChange(path)
    guard let now = Stamp(path) else { throw Problem(text: "It no longer exists.") }
    guard now == expecting else { throw Problem(text: "It changed since you previewed it. Try again.") }
    var out: NSURL?
    do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out) } catch {
        let e = error as NSError
        if e.code == NSFileWriteNoPermissionError || e.code == NSFileReadNoPermissionError {
            throw Problem(text: "macOS needs an administrator. Use Show in Finder and move it to the Trash there.")
        }
        throw Problem(text: e.localizedDescription)
    }
    guard let t = out?.path else { throw Problem(text: "It was moved to the Trash, but macOS didn't say where.") }
    return t
}

/// Moves without ever replacing something that is already there.
private func moveSafely(_ from: String, _ to: String) throws {
    if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return }
    let code = errno
    if code == EEXIST, from.lowercased() == to.lowercased(), Stamp(from) == Stamp(to), rename(from, to) == 0 { return }
    throw Problem(text: code == EEXIST ? "Something with that name already exists." : String(cString: strerror(code)))
}

func restore(_ t: Trashed) throws { try moveSafely(t.trash, t.original) }

func validName(_ raw: String) throws -> String {
    let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if n.isEmpty || n == "." || n == ".." { throw Problem(text: "Enter a name.") }
    if n.contains("/") || n.contains(":") || n.contains("\0") { throw Problem(text: "Names can't contain / or :") }
    if n.utf8.count > 255 { throw Problem(text: "That name is too long.") }
    return n
}

func renameItem(_ path: String, to raw: String) throws -> String {
    let name = try validName(raw)
    try checkChange(path)
    let dest = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
    try moveSafely(path, dest)
    return name
}

func makeFolder(in parent: String, named raw: String) throws -> String {
    let name = try validName(raw)
    let path = (parent as NSString).appendingPathComponent(name)
    // The new item is checked, so a main folder such as Documents may receive new folders.
    if let r = lockReason(path) { throw Problem(text: r) }
    if mkdir(path, 0o755) != 0 {
        throw Problem(text: errno == EEXIST ? "Something with that name already exists." : String(cString: strerror(errno)))
    }
    return name
}

/// Runs the real actions on throwaway files in a private folder.
func selfTest() -> Bool {
    var ok = true
    func expect(_ c: Bool, _ what: String) { print(c ? "ok  " : "FAIL", what); ok = ok && c }
    func fails(_ what: String, _ f: () throws -> Void) { do { try f(); expect(false, what) } catch { expect(true, what) } }
    let home = NSHomeDirectory(), fm = FileManager.default
    for p in ["/", "/System", "/Library/Fonts", "/usr/bin/true", "/Users", home, home + "/Library", home + "/library", home + "/Documents",
              home + "/Library/Caches", home + "/Library/Keychains/x", home + "/Library/Mobile Documents/x", home + "/.Trash",
              "/Applications", "/Applications/Xcode.app/Contents", "/opt/homebrew", "relative", home + "/..", "/private/var/vm/sleepimage"] {
        expect(lockReason(p) != nil, "locked: " + p.replacingOccurrences(of: home, with: "~"))
    }
    for p in [home + "/Documents/x", home + "/Library/Caches/x", home + "/.npm", "/Applications/Example.app"] {
        expect(lockReason(p) == nil, "allowed: " + p.replacingOccurrences(of: home, with: "~"))
    }
    expect(lockReason((Bundle.main.bundlePath as NSString).deletingLastPathComponent) != nil, "locked: folder holding this app")
    let frame = CGRect(x: 10, y: 20, width: 800, height: 500), weights: [Double] = [60, 40, 25, 12, 9, 3, 1, 1]
    let cells = treemap(weights, in: frame)
    expect(cells.count == 8 && zip(cells, weights).allSatisfy { abs(Double($0.width * $0.height) - $1 / 151 * 400_000) < 1 }, "map: areas match sizes")
    expect(cells.allSatisfy { frame.insetBy(dx: -0.01, dy: -0.01).contains($0) }, "map: blocks stay inside")
    expect(cells.indices.allSatisfy { i in cells.indices.allSatisfy { j in
        let o = cells[i].intersection(cells[j]); return i == j || o.isNull || o.width * o.height < 0.01 } }, "map: blocks don't overlap")
    expect(treemap([], in: frame).isEmpty && treemap([0, 0], in: frame).count == 2, "map: empty folders")
    let dir = home + "/Library/Caches/space-overview-selftest-" + UUID().uuidString
    do {
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: false)
        defer { try? fm.removeItem(atPath: dir) }
        expect(try makeFolder(in: dir, named: " New ") == "New", "new folder")
        fails("new folder won't replace") { _ = try makeFolder(in: dir, named: "New") }
        let f = dir + "/file.txt"
        try "hello".write(toFile: f, atomically: false, encoding: .utf8)
        expect(try renameItem(f, to: "FILE.txt") == "FILE.txt", "case-only rename")
        try "other".write(toFile: dir + "/other", atomically: false, encoding: .utf8)
        fails("rename won't replace") { _ = try renameItem(dir + "/other", to: "FILE.txt") }
        fails("rename can't leave the folder") { _ = try renameItem(dir + "/other", to: "../other") }
        try fm.createSymbolicLink(atPath: dir + "/out", withDestinationPath: "/usr")
        expect(lockReason(dir + "/out/bin") != nil, "locked: through a link to a system folder")
        let stamp = Stamp(dir + "/other")!
        try fm.moveItem(atPath: dir + "/other", toPath: dir + "/kept")
        try "swap".write(toFile: dir + "/other", atomically: false, encoding: .utf8)
        fails("won't trash a swapped file") { _ = try moveToTrash(dir + "/other", expecting: stamp) }
        expect(fm.fileExists(atPath: dir + "/other"), "swapped file is untouched")
        let t = try moveToTrash(dir + "/FILE.txt", expecting: Stamp(dir + "/FILE.txt")!)
        expect(!fm.fileExists(atPath: dir + "/FILE.txt") && Stamp(t) != nil, "move to Trash")
        let item = Trashed(original: dir + "/FILE.txt", trash: t, entry: nil)
        try "new".write(toFile: dir + "/FILE.txt", atomically: false, encoding: .utf8)
        fails("undo won't replace") { try restore(item) }
        try fm.removeItem(atPath: dir + "/FILE.txt")
        try restore(item)
        expect((try? String(contentsOfFile: dir + "/FILE.txt", encoding: .utf8)) == "hello" && Stamp(t) == nil, "undo puts it back")
    } catch { expect(false, "unexpected: \(error)") }
    expect(!fm.fileExists(atPath: dir), "cleaned up")
    return ok
}
