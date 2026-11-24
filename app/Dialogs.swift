import SwiftUI

struct TrashItem: Identifiable {
    let path: String, title: String
    let entry: Entry?
    var on: Bool
    let blocked: String?
    let stamp: Stamp?
    var measured: SoMeasure?
    var id: String { path }
}

struct TrashPlan: Identifiable {
    let id = UUID()
    let title: String
    var items: [TrashItem]
    /// Set for an uninstall: if the app itself can't be moved, its data is left alone.
    var appPath: String?
}

struct NamePrompt: Identifiable {
    let id = UUID()
    let entry: Entry
    let isNew: Bool
}

struct TrashSheet: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) var dismiss
    @State var plan: TrashPlan
    private var chosen: [TrashItem] { plan.items.filter(\.on) }
    private var counted: Bool { chosen.allSatisfy { $0.measured != nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.title).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach($plan.items) { $i in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle(i.title, isOn: $i.on).labelsHidden().toggleStyle(.checkbox).disabled(i.blocked != nil)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i.title).fontWeight(.semibold)
                                Text((i.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(Color.dim).textSelection(.enabled)
                                if let b = i.blocked { Text(b).font(.caption).foregroundStyle(Color.danger) }
                            }
                            Spacer()
                            Text(i.measured.map { bytes($0.size) } ?? "…").monospacedDigit()
                        }.padding(.vertical, 9)
                        Color.line.frame(height: 1)
                    }
                }
            }.frame(maxHeight: 330).fixedSize(horizontal: false, vertical: true)
            if counted {
                Text("Frees at least \(bytes(chosen.reduce(0) { $0 + $1.measured!.frees })) after you empty the Trash.").fontWeight(.semibold)
                Text("\(chosen.reduce(0) { $0 + $1.measured!.items }.formatted()) items. Data shared with copies or snapshots may stay on disk.").foregroundStyle(Color.dim)
                if chosen.contains(where: { $0.measured!.denied > 0 }) {
                    Text("Some folders inside couldn't be read, so this may be too low.").foregroundStyle(Color.danger)
                }
            } else { HStack { ProgressView().controlSize(.small); Text("Measuring").foregroundStyle(Color.dim) } }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Outline()).keyboardShortcut(.cancelAction)
                Button("Move to Trash") { m.run(plan); dismiss() }.buttonStyle(Danger()).disabled(chosen.isEmpty || !counted)
                    .opacity(chosen.isEmpty || !counted ? 0.5 : 1)
            }
        }
        .padding(24).frame(width: 540).background(Color.page).foregroundStyle(Color.ink)
        .task {
            for i in plan.items.indices {
                let p = plan.items[i].path
                let r = await Task.detached { measure(p) }.value
                if Task.isCancelled { return }
                plan.items[i].measured = r
            }
        }
    }
}

struct NameSheet: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) var dismiss
    let prompt: NamePrompt
    @State private var name = ""
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.isNew ? "New folder in \(prompt.entry.name)" : "Rename \(prompt.entry.name)").font(.title2.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            if let problem { Text(problem).foregroundStyle(Color.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Outline()).keyboardShortcut(.cancelAction)
                Button(prompt.isNew ? "Create" : "Rename", action: save).buttonStyle(Outline()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 420).background(Color.page).foregroundStyle(Color.ink)
        .onAppear { name = prompt.isNew ? "" : prompt.entry.name }
    }
    func save() {
        do { try m.apply(prompt, name: name); dismiss() }
        catch { problem = (error as? Problem)?.text ?? error.localizedDescription }
    }
}

struct Danger: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.fontWeight(.semibold).foregroundStyle(Color.danger).padding(.horizontal, 13).frame(height: 34)
            .background(configuration.isPressed ? Color.line : Color.card, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.danger))
    }
}

struct Notice: View {
    @EnvironmentObject var m: Model
    var body: some View {
        if let n = m.notice {
            HStack(alignment: .top, spacing: 12) {
                Text(n).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                if !m.lastTrash.isEmpty { Button("Undo") { m.undo() }.buttonStyle(Outline()).keyboardShortcut("z") }
                Button { m.notice = nil } label: { Image(systemName: "xmark").frame(width: 30, height: 34) }.buttonStyle(.plain).accessibilityLabel("Dismiss")
            }.padding(14).background(Color.picked)
        }
    }
}

extension Model {
    func selectedLock() -> String? {
        guard let s = selected else { return "Nothing is selected." }
        return s.grouped ? "Expand this in Finder to change single files." : lockReason(s.path)
    }
    func askTrash() {
        guard let s = selected, !s.grouped else { return }
        trashPlan = TrashPlan(title: "Move \(s.name) to the Trash?", items: [item(s.path, s.name, s, true)])
    }
    func askUninstall(_ a: AppUsage, cachesOnly: Bool = false) {
        let parts = a.parts.filter { !cachesOnly || $0.kind == .cache }
        trashPlan = TrashPlan(title: cachesOnly ? "Clear caches for \(a.name)?" : "Uninstall \(a.name)?", items: parts.map {
            item($0.path, $0.kind.rawValue, engine?.entry($0.path), $0.kind != .possible, app: a)
        }, appPath: cachesOnly ? nil : a.parts.first { $0.kind == .app }?.path)
    }
    private func item(_ path: String, _ title: String, _ e: Entry?, _ on: Bool, app: AppUsage? = nil) -> TrashItem {
        var why = lockReason(path) ?? runningApp(in: path).map { "Quit \($0) first." }
        if why == nil, let app, let r = runningApp(in: app.path) { why = "Quit \(r) first." }
        return TrashItem(path: path, title: title, entry: e, on: on && why == nil, blocked: why, stamp: Stamp(path))
    }
    func run(_ plan: TrashPlan) {
        var done: [Trashed] = [], errors: [String] = []
        // The app goes first; if it fails, its data stays.
        let order = plan.items.filter { $0.on && $0.path == plan.appPath } + plan.items.filter { $0.on && $0.path != plan.appPath }
        for i in order {
            do {
                guard let s = i.stamp else { throw Problem(text: "It no longer exists.") }
                if let a = plan.appPath, let r = runningApp(in: a) { throw Problem(text: "Quit \(r) first.") }
                let t = try moveToTrash(i.path, expecting: s)
                done.append(Trashed(original: i.path, trash: t, entry: i.entry))
                if let e = i.entry { engine?.mark(e, gone: true) }
            } catch {
                errors.append("\((i.path as NSString).lastPathComponent): \((error as? Problem)?.text ?? error.localizedDescription)")
                if i.path == plan.appPath { break }
            }
        }
        lastTrash = done
        notice = ([done.isEmpty ? nil : "Moved \(done.count) \(done.count == 1 ? "item" : "items") to the Trash."] + errors.map(Optional.some)).compactMap { $0 }.joined(separator: "\n")
        selected = nil
        refresh()
    }
    func undo() {
        var left: [Trashed] = [], errors: [String] = []
        for t in lastTrash.reversed() {
            do {
                try restore(t)
                if let e = t.entry { engine?.mark(e, gone: false) }
            } catch {
                left.insert(t, at: 0)
                errors.append("\((t.original as NSString).lastPathComponent): \((error as? Problem)?.text ?? error.localizedDescription)")
            }
        }
        lastTrash = left
        notice = errors.isEmpty ? "Put everything back." : errors.joined(separator: "\n")
        refresh()
    }
    func newFolderTarget() -> Entry? {
        guard let s = selected, !s.grouped else { return root }
        return s.isFolder ? s : engine?.entry((s.path as NSString).deletingLastPathComponent)
    }
    func apply(_ p: NamePrompt, name: String) throws {
        if p.isNew {
            let n = try makeFolder(in: p.entry.path, named: name)
            engine?.addFolder(n, in: p.entry)
            expanded.insert(p.entry.path)
        } else {
            let old = p.entry.path
            let n = try renameItem(old, to: name)
            engine?.renamed(p.entry, to: n)
            let new = ((old as NSString).deletingLastPathComponent as NSString).appendingPathComponent(n)
            expanded = Set(expanded.map { $0 == old ? new : $0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0 })
            if mapPath == old { mapPath = new } else if mapPath.hasPrefix(old + "/") { mapPath = new + mapPath.dropFirst(old.count) }
            lastTrash = [] // saved original paths may no longer be right
            notice = nil
            selected = nil
        }
        refresh()
    }
}
