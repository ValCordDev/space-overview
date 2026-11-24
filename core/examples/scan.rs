fn main() {
    let path = std::env::args().nth(1).expect("usage: scan PATH");
    let t0 = std::time::Instant::now();
    let mut s = space_core::Scan::start(path.as_ref(), 8);
    s.wait();
    let t = s.shared.tree.get().unwrap().read().unwrap();
    println!("{} KB, {} items, {} folders, {} large files, {} denied, {:.1?}", t.dirs[0].size / 1024, t.dirs[0].items, t.dirs.len(), t.large.len(), s.shared.denied.load(std::sync::atomic::Ordering::Relaxed), t0.elapsed());
}
