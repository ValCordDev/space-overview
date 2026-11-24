//! Parallel disk scanner. Keeps folders and large files in memory; small files are
//! read live when a folder is opened, so memory stays low.
mod bulk;
pub mod ffi;

use std::collections::{HashMap, HashSet};
use std::ffi::{CString, OsStr};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Condvar, Mutex, OnceLock, RwLock};

pub const NONE: u32 = u32::MAX;
const LARGE: u64 = 1 << 20;

#[derive(Default)]
pub struct Dir {
    pub name: Box<[u8]>,
    pub parent: u32,
    pub size: u64,
    pub items: u64,
    pub mtime: i64,
    pub denied: bool,
    /// Moved to the Trash since the scan.
    pub gone: bool,
}

pub struct Large {
    pub name: Box<[u8]>,
    pub parent: u32,
    pub size: u64,
    pub mtime: i64,
    pub gone: bool,
}

pub struct Tree {
    pub root: PathBuf,
    pub dirs: Vec<Dir>,
    pub large: Vec<Large>,
    child_start: Vec<u32>,
    child_ids: Vec<u32>,
    /// Folders created after the scan, by parent.
    added: HashMap<u32, Vec<u32>>,
}

impl Tree {
    pub fn children(&self, id: u32) -> impl Iterator<Item = u32> + '_ {
        let scanned = match self.child_start.get(id as usize..id as usize + 2) {
            Some(s) => &self.child_ids[s[0] as usize..s[1] as usize],
            None => &[],
        };
        let added = self.added.get(&id).map_or(&[][..], |v| v);
        scanned.iter().chain(added).copied().filter(|c| !self.dirs[*c as usize].gone)
    }
    pub fn is_gone(&self, mut id: u32) -> bool {
        while id != 0 {
            let d = &self.dirs[id as usize];
            if d.gone { return true; }
            id = d.parent;
        }
        false
    }
    fn adjust(&mut self, mut id: u32, size: u64, items: u64, add: bool) {
        while let Some(d) = self.dirs.get_mut(id as usize) {
            let f = if add { u64::saturating_add } else { u64::saturating_sub };
            (d.size, d.items) = (f(d.size, size), f(d.items, items));
            id = d.parent;
        }
    }
    pub fn set_dir_gone(&mut self, id: u32, gone: bool) {
        if id == 0 { return; }
        let Some(d) = self.dirs.get_mut(id as usize) else { return };
        if d.gone == gone { return; }
        d.gone = gone;
        let (p, size, items) = (d.parent, d.size, d.items + 1);
        self.adjust(p, size, items, !gone);
    }
    pub fn set_file_gone(&mut self, parent: u32, name: &[u8], size: u64, gone: bool) {
        for l in self.large.iter_mut().filter(|l| l.parent == parent && &*l.name == name) { l.gone = gone; }
        self.adjust(parent, size, 1, !gone);
    }
    pub fn rename_dir(&mut self, id: u32, name: &[u8]) {
        if let Some(d) = self.dirs.get_mut(id as usize) { d.name = name.into(); }
    }
    pub fn rename_file(&mut self, parent: u32, old: &[u8], new: &[u8]) {
        for l in self.large.iter_mut().filter(|l| l.parent == parent && &*l.name == old) { l.name = new.into(); }
    }
    pub fn add_dir(&mut self, parent: u32, name: &[u8], mtime: i64) {
        if parent as usize >= self.dirs.len() { return; }
        let id = self.dirs.len() as u32;
        self.dirs.push(Dir { name: name.into(), parent, mtime, ..Dir::default() });
        self.added.entry(parent).or_default().push(id);
        self.adjust(parent, 0, 1, true);
    }
    pub fn find(&self, rel: &[u8]) -> u32 {
        let mut id = 0;
        for part in rel.split(|b| *b == b'/').filter(|p| !p.is_empty()) {
            let hit = self.children(id).find(|c| &*self.dirs[*c as usize].name == part);
            match hit {
                Some(c) => id = c,
                None => return NONE,
            }
        }
        id
    }
    pub fn path(&self, mut id: u32) -> PathBuf {
        let mut parts = vec![];
        while id != 0 {
            let d = &self.dirs[id as usize];
            parts.push(&d.name);
            id = d.parent;
        }
        let mut p = self.root.clone();
        parts.iter().rev().for_each(|n| p.push(OsStr::from_bytes(n)));
        p
    }
    pub fn files(&self, id: u32, mut each: impl FnMut(&[u8], u64, i64)) {
        bulk::no_downloads();
        let Ok(path) = CString::new(self.path(id).as_os_str().as_bytes()) else { return };
        let _ = bulk::list(&path, None, false, &mut bulk::new_buffer(), |it| {
            if !it.is_dir { each(it.name, it.size, it.mtime) }
        });
    }
}

#[derive(Default)]
struct Queue {
    jobs: Vec<(u32, PathBuf)>,
    /// Queued plus running folders.
    pending: usize,
}

#[derive(Default)]
struct Build {
    dirs: Vec<Dir>,
    large: Vec<Large>,
}

#[derive(Default)]
pub struct Shared {
    pub items: AtomicU64,
    pub bytes: AtomicU64,
    pub denied: AtomicU64,
    pub cancel: AtomicBool,
    pub tree: OnceLock<RwLock<Tree>>,
    queue: Mutex<Queue>,
    wake: Condvar,
    build: Mutex<Build>,
    hardlinks: Mutex<HashSet<u64>>,
}

pub struct Scan {
    pub shared: Arc<Shared>,
    main: Option<std::thread::JoinHandle<()>>,
}

impl Scan {
    pub fn start(root: &Path, threads: usize) -> Scan {
        let shared = Arc::new(Shared::default());
        let (s, root) = (shared.clone(), root.to_path_buf());
        let main = std::thread::spawn(move || run(&s, root, threads.clamp(1, 32)));
        Scan { shared, main: Some(main) }
    }
    pub fn wait(&mut self) {
        if let Some(h) = self.main.take() { let _ = h.join(); }
    }
}

impl Drop for Scan {
    fn drop(&mut self) {
        self.shared.cancel.store(true, Relaxed);
        self.wait();
    }
}

fn run(s: &Shared, root: PathBuf, threads: usize) {
    let c = CString::new(root.as_os_str().as_bytes()).unwrap_or_default();
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    unsafe { libc::stat(c.as_ptr(), &mut st) };
    s.build.lock().unwrap().dirs.push(Dir { parent: NONE, ..Dir::default() });
    *s.queue.lock().unwrap() = Queue { jobs: vec![(0, root.clone())], pending: 1 };
    std::thread::scope(|scope| {
        for _ in 0..threads { scope.spawn(|| worker(s, st.st_dev)); }
    });
    if s.cancel.load(Relaxed) { return; }
    let b = std::mem::take(&mut *s.build.lock().unwrap());
    s.hardlinks.lock().unwrap().clear();
    let _ = s.tree.set(RwLock::new(finish(root, b)));
}

fn finish(root: PathBuf, Build { mut dirs, large }: Build) -> Tree {
    // A child is always added after its parent, so one backwards pass sums everything.
    for i in (1..dirs.len()).rev() {
        let (size, items, p) = (dirs[i].size, dirs[i].items, dirs[i].parent as usize);
        dirs[p].size += size;
        dirs[p].items += items + 1;
    }
    let mut child_start = vec![0u32; dirs.len() + 1];
    for d in &dirs[1..] { child_start[d.parent as usize + 1] += 1; }
    for i in 1..child_start.len() { child_start[i] += child_start[i - 1]; }
    let mut next = child_start.clone();
    let mut child_ids = vec![0u32; dirs.len() - 1];
    for (i, d) in dirs.iter().enumerate().skip(1) {
        let slot = &mut next[d.parent as usize];
        child_ids[*slot as usize] = i as u32;
        *slot += 1;
    }
    Tree { root, dirs, large, child_start, child_ids, added: HashMap::new() }
}

fn worker(s: &Shared, dev: i32) {
    bulk::no_downloads();
    let mut buf = bulk::new_buffer();
    loop {
        let (id, path) = {
            let mut q = s.queue.lock().unwrap();
            loop {
                if s.cancel.load(Relaxed) || q.pending == 0 {
                    s.wake.notify_all();
                    return;
                }
                if let Some(j) = q.jobs.pop() { break j; }
                q = s.wake.wait_timeout(q, std::time::Duration::from_millis(100)).unwrap().0;
            }
        };
        let (mut size, mut items, mut subs, mut large) = (0u64, 0u64, vec![], vec![]);
        let cpath = CString::new(path.as_os_str().as_bytes()).unwrap_or_default();
        let res = bulk::list(&cpath, Some(dev), false, &mut buf, |it| {
            if it.is_dir {
                if it.dev == dev && it.flags & bulk::SF_DATALESS == 0 {
                    subs.push((Box::<[u8]>::from(it.name), it.mtime));
                }
                return;
            }
            items += 1;
            if it.links > 1 && !s.hardlinks.lock().unwrap().insert(it.inode) { return; }
            size += it.size;
            if it.size >= LARGE {
                large.push(Large { name: it.name.into(), parent: id, size: it.size, mtime: it.mtime, gone: false });
            }
        });
        let denied = matches!(&res, Err(e) if e.kind() != std::io::ErrorKind::NotFound);
        if denied { s.denied.fetch_add(1, Relaxed); }
        s.items.fetch_add(items + subs.len() as u64, Relaxed);
        s.bytes.fetch_add(size, Relaxed);
        let mut jobs = Vec::with_capacity(subs.len());
        {
            let mut b = s.build.lock().unwrap();
            let d = &mut b.dirs[id as usize];
            (d.size, d.items, d.denied) = (size, items, denied);
            b.large.append(&mut large);
            for (name, mtime) in subs {
                jobs.push((b.dirs.len() as u32, path.join(OsStr::from_bytes(&name))));
                b.dirs.push(Dir { name, parent: id, mtime, ..Dir::default() });
            }
        }
        let mut q = s.queue.lock().unwrap();
        q.pending = q.pending + jobs.len() - 1;
        q.jobs.append(&mut jobs);
        s.wake.notify_all();
    }
}

#[derive(Default, Debug)]
pub struct Measure {
    pub size: u64,
    /// Lower bound on what deleting frees: data shared with clones or snapshots is left out.
    pub frees: u64,
    pub items: u64,
    pub denied: u64,
}

/// Measures one file or folder as it is on disk right now.
pub fn measure(path: &Path) -> Measure {
    bulk::no_downloads();
    let mut m = Measure::default();
    let mut links: HashMap<u64, (u32, u32, u64, u64)> = HashMap::new();
    let mut buf = bulk::new_buffer();
    let Ok(meta) = std::fs::symlink_metadata(path) else { return m };
    use std::os::unix::fs::MetadataExt;
    let dev = meta.dev() as i32;
    let only = (!meta.is_dir()).then(|| path.file_name().unwrap_or_default().as_bytes().to_vec());
    let mut todo = vec![if only.is_some() { path.parent().unwrap_or(path).to_path_buf() } else { path.to_path_buf() }];
    m.items = u64::from(only.is_none());
    while let Some(dir) = todo.pop() {
        let Ok(c) = CString::new(dir.as_os_str().as_bytes()) else { continue };
        let res = bulk::list(&c, Some(dev), true, &mut buf, |it| {
            if only.as_ref().is_some_and(|n| n != it.name) { return; }
            m.items += 1;
            if it.is_dir {
                if it.dev == dev && it.flags & bulk::SF_DATALESS == 0 { todo.push(dir.join(OsStr::from_bytes(it.name))); }
                return;
            }
            let frees = it.private.min(it.size);
            if it.links > 1 {
                links.entry(it.inode).or_insert((it.links, 0, it.size, frees)).1 += 1;
            } else {
                m.size += it.size;
                m.frees += frees;
            }
        });
        if res.is_err() { m.denied += 1; }
    }
    for (total, seen, size, frees) in links.into_values() {
        m.size += size;
        if seen >= total { m.frees += frees; } // other names keep the data alive
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn matches_du_and_counts_hardlinks_once() {
        let root = std::env::temp_dir().join(format!("space_core_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("a/b")).unwrap();
        fs::write(root.join("a/big"), vec![7u8; 3 << 20]).unwrap();
        fs::write(root.join("a/b/small"), b"hello").unwrap();
        fs::hard_link(root.join("a/big"), root.join("a/b/link")).unwrap();
        std::os::unix::fs::symlink("/Applications", root.join("a/sym")).unwrap();
        let mut scan = Scan::start(&root, 4);
        scan.wait();
        let mut t = scan.shared.tree.get().unwrap().write().unwrap();
        let out = std::process::Command::new("du").arg("-sk").arg(&root).output().unwrap();
        let du: u64 = String::from_utf8_lossy(&out.stdout).split_whitespace().next().unwrap().parse().unwrap();
        assert_eq!(t.dirs[0].size / 1024, du);
        assert_eq!(t.dirs[0].items, 6);
        assert_eq!(t.large.len(), 1);
        let b = t.find(b"a/b");
        assert_eq!(t.path(b), root.join("a/b"));
        let mut n = 0;
        t.files(b, |_, _, _| n += 1);
        assert_eq!(n, 2);
        assert_eq!(t.find(b"nope"), NONE);
        let m = measure(&root);
        assert_eq!(m.size, t.dirs[0].size);
        assert_eq!(m.frees, m.size);
        assert_eq!(measure(&root.join("a/big")).frees, 0, "other hard link is outside the selection");
        let ok = std::process::Command::new("cp").arg("-c").arg(root.join("a/big")).arg(root.join("clone")).status().unwrap();
        assert!(ok.success());
        let c = measure(&root.join("clone"));
        assert_eq!((c.size, c.frees), (3 << 20, 0), "a clone frees nothing");

        let before = (t.dirs[0].size, t.dirs[0].items);
        t.set_dir_gone(b, true);
        assert_eq!(t.find(b"a/b"), NONE);
        assert_eq!(t.dirs[0].items, before.1 - 3);
        t.set_dir_gone(b, false);
        assert_eq!((t.dirs[0].size, t.dirs[0].items), before);
        t.rename_dir(b, b"c");
        assert_eq!(t.find(b"a/c"), b);
        let a = t.find(b"a");
        t.add_dir(a, b"new", 0);
        assert_ne!(t.find(b"a/new"), NONE);
        let name = t.large[0].name.clone();
        let p = t.large[0].parent;
        t.set_file_gone(p, &name, 3 << 20, true);
        assert!(t.large[0].gone);
        fs::remove_dir_all(&root).unwrap();
    }
}
