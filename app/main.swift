import SwiftUI

struct SpaceOverview: App {
    @StateObject private var model = Model()
    var body: some Scene {
        Window("Space Overview", id: "main") { ContentView().environmentObject(model) }
            .defaultSize(width: 1280, height: 800)
    }
}

// `--report` prints what the app would show, for checking without opening a window.
if CommandLine.arguments.contains("--selftest") {
    exit(selfTest() ? 0 : 1)
} else if CommandLine.arguments.contains("--report") {
    let e = Engine()
    while !e.progress.done { usleep(50_000) }
    if let h = e.entry(NSHomeDirectory()) {
        print("Home", bytes(h.size), h.items)
        for c in e.children(of: h).prefix(8) { print("  ", c.name, bytes(c.size)) }
    }
    print("Large files:", e.largeFiles().count)
    for a in findApps(e).prefix(12) {
        print(a.name, bytes(a.total), "app", bytes(a.size(.app)), "data", bytes(a.size(.data)), "cache", bytes(a.size(.cache)), "possible", bytes(a.size(.possible)))
    }
} else {
    SpaceOverview.main()
}
