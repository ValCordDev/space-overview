import SwiftUI

/// Squarified treemap: one rectangle per weight (largest first), each area proportional to its weight.
func treemap(_ weights: [Double], in frame: CGRect) -> [CGRect] {
    var out: [CGRect] = [], free = frame, i = 0
    var left = weights.reduce(0, +)
    guard left > 0, frame.width > 0, frame.height > 0 else { return weights.map { _ in .zero } }
    while i < weights.count {
        guard left > 0, free.width > 0, free.height > 0 else { out.append(.zero); i += 1; continue }
        let scale = Double(free.width * free.height) / left
        let side = Double(min(free.width, free.height))
        func worst(_ sum: Double, _ big: Double, _ small: Double) -> Double {
            max(side * side * big / (sum * sum), sum * sum / (side * side * max(small, 1e-9)))
        }
        // Grow the row while its least square cell keeps getting better.
        var j = i + 1, sum = weights[i] * scale
        let big = sum
        while j < weights.count {
            let w = weights[j] * scale
            if worst(sum + w, big, w) > worst(sum, big, weights[j - 1] * scale) { break }
            sum += w
            j += 1
        }
        let thick = sum / side, wide = free.width >= free.height
        var at = wide ? free.minY : free.minX
        for k in i..<j {
            let len = thick > 0 ? weights[k] * scale / thick : 0
            out.append(wide ? CGRect(x: free.minX, y: at, width: thick, height: len) : CGRect(x: at, y: free.minY, width: len, height: thick))
            at += len
            left -= weights[k]
        }
        if wide { free.origin.x += thick; free.size.width = max(0, free.width - thick) }
        else { free.origin.y += thick; free.size.height = max(0, free.height - thick) }
        i = j
    }
    return out
}

/// Largest first; everything past the limit becomes one block.
func mapItems(_ all: [Entry], in parent: Entry, limit: Int) -> [Entry] {
    let items = all.filter { $0.size > 0 }
    guard items.count > limit else { return items }
    let rest = items[limit...]
    let more = Entry(path: parent.path + "/\u{0}more", name: "\(rest.count.formatted()) smaller items", size: rest.reduce(0) { $0 + $1.size },
                     items: rest.reduce(0) { $0 + $1.items }, modified: parent.modified, node: UInt32.max, denied: false, grouped: true)
    return (Array(items[..<limit]) + [more]).sorted { $0.size > $1.size }
}

extension Model {
    var mapRoot: Entry? { engine?.entry(mapPath) ?? engine?.entry(NSHomeDirectory()) }
    func openMap(_ path: String) { mapPath = path; selected = nil }
}

struct MapView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        if let root = m.mapRoot {
            let shown = m.selected ?? root
            VStack(spacing: 0) {
                Header(title: "Map", detail: bytes(root.size), reveal: shown.grouped ? nil : shown.path, searches: false)
                crumbs(root)
                HStack(spacing: 14) {
                    GeometryReader { g in blocks(root, g.size) }
                    MapDetail(entry: shown, root: root).frame(width: 260)
                }.padding([.horizontal, .bottom], 18)
            }
        }
    }
    func crumbs(_ root: Entry) -> some View {
        let parts = root.path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb("Macintosh HD", "/", root.path == "/")
                ForEach(parts.indices, id: \.self) { i in
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.dim).accessibilityHidden(true)
                    crumb(parts[i], "/" + parts[...i].joined(separator: "/"), i == parts.count - 1)
                }
            }
        }.padding(.horizontal, 18).padding(.vertical, 8)
    }
    func crumb(_ name: String, _ path: String, _ here: Bool) -> some View {
        Button { m.openMap(path) } label: {
            Text(name).fontWeight(here ? .bold : .regular).foregroundStyle(here ? Color.ink : Color.dim)
                .padding(.horizontal, 6).frame(height: 30).contentShape(.rect)
        }.buttonStyle(.plain)
    }
    func blocks(_ root: Entry, _ size: CGSize) -> some View {
        let items = mapItems(m.children(root), in: root, limit: 40)
        let rects = treemap(items.map { Double($0.size) }, in: CGRect(origin: .zero, size: size))
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(items.indices, id: \.self) { i in
                let e = items[i], r = rects[i].insetBy(dx: 1.5, dy: 1.5)
                if rects[i].width > 4, rects[i].height > 4 {
                    MapBlock(entry: e, rank: i, size: r.size, nested: false).offset(x: r.minX, y: r.minY)
                    if e.isFolder, r.width > 110, r.height > 90 { inner(e, i, r) }
                }
            }
            if items.isEmpty {
                Text("Nothing to show here").foregroundStyle(Color.dim).frame(width: size.width, height: size.height)
            }
        }
    }
    /// What's inside a large folder, below its name.
    func inner(_ e: Entry, _ rank: Int, _ r: CGRect) -> some View {
        let items = mapItems(m.children(e), in: e, limit: 18)
        let rects = treemap(items.map { Double($0.size) }, in: CGRect(x: r.minX + 5, y: r.minY + 42, width: r.width - 10, height: r.height - 47))
        return ForEach(items.indices, id: \.self) { i in
            let c = rects[i].insetBy(dx: 1, dy: 1)
            if rects[i].width > 5, rects[i].height > 5 {
                MapBlock(entry: items[i], rank: rank, size: c.size, nested: true).offset(x: c.minX, y: c.minY)
            }
        }
    }
}

struct MapBlock: View {
    @EnvironmentObject var m: Model
    let entry: Entry, rank: Int, size: CGSize, nested: Bool
    var body: some View {
        let on = m.selected?.id == entry.id
        // Larger folders are brighter. Their contents sit on the same shade, outlined.
        let fill: Color = rank == 0 ? .amber : rank == 1 ? Color(hex: 0xC98113) : rank < 5 ? Color(hex: 0x7A4C0F) : Color(hex: 0x43321F)
        let text: Color = rank < 2 ? .onAmber : .ink
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: nested ? 3 : 5).fill(fill)
            if nested { RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(rank < 2 ? 0.08 : 0.22)) }
            if size.width > 58, size.height > 32 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).fontWeight(.semibold)
                    Text(bytes(entry.size)).monospacedDigit()
                }.font(nested ? .caption : .callout).lineLimit(1).foregroundStyle(text).padding(nested ? 5 : 6)
            }
            RoundedRectangle(cornerRadius: nested ? 3 : 5).strokeBorder(on ? Color.white : Color.page.opacity(nested ? 0.35 : 0), lineWidth: on ? 3 : 1)
        }
        .frame(width: max(0, size.width), height: max(0, size.height), alignment: .topLeading).clipped().contentShape(.rect)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if entry.isFolder { m.openMap(entry.path) } })
        .simultaneousGesture(TapGesture().onEnded { m.selected = entry })
        .help("\(entry.name), \(bytes(entry.size))")
        .accessibilityElement(children: .ignore).accessibilityLabel("\(entry.name), \(bytes(entry.size))")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { m.selected = entry }
    }
}

struct MapDetail: View {
    @EnvironmentObject var m: Model
    let entry: Entry, root: Entry
    var body: some View {
        let picked = m.selected != nil
        let why = picked ? m.selectedLock() : nil
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.name).font(.title2.bold()).lineLimit(3)
            Text(bytes(entry.size)).font(.system(size: 32, weight: .semibold)).monospacedDigit()
            if !entry.grouped {
                Text((entry.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(Color.dim).textSelection(.enabled).lineLimit(4)
            }
            fact("Items", entry.items.formatted())
            if !entry.grouped { fact("Modified", entry.modified.formatted(.dateTime.day().month(.abbreviated).year())) }
            if picked, root.size > 0 {
                fact("Share of view", min(1, Double(entry.size) / Double(root.size)).formatted(.percent.precision(.fractionLength(0))))
            }
            Spacer()
            if !picked { Text("Click a block to select it. Double-click a folder to open it.").foregroundStyle(Color.dim) }
            if let why { Label(why, systemImage: "lock").foregroundStyle(Color.dim) }
            if picked {
                if entry.isFolder { Button("Open folder") { m.openMap(entry.path) }.buttonStyle(Outline()) }
                Button("Rename") { m.namePrompt = NamePrompt(entry: entry, isNew: false) }.buttonStyle(Outline()).disabled(why != nil).opacity(why == nil ? 1 : 0.5)
                Button("Move to Trash") { m.askTrash() }.buttonStyle(Danger()).keyboardShortcut(.delete).disabled(why != nil).opacity(why == nil ? 1 : 0.5)
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.card, in: .rect(cornerRadius: 10))
    }
    func fact(_ a: String, _ b: String) -> some View {
        HStack { Text(a).foregroundStyle(Color.dim); Spacer(); Text(b).monospacedDigit() }
    }
}
