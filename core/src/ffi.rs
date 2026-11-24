//! C interface used by the Swift app. See include/space_core.h.
use crate::{Scan, Tree, NONE};
use std::ffi::{c_char, c_void, CStr, OsStr};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::atomic::Ordering::Relaxed;
use std::sync::RwLock;

#[repr(C)]
pub struct SoProgress { items: u64, bytes: u64, denied: u64, done: bool }

#[repr(C)]
pub struct SoEntry { name: *const u8, name_len: u64, size: u64, items: u64, mtime: i64, id: u32, parent: u32, denied: bool }

type Callback = extern "C" fn(*mut c_void, *const SoEntry);

unsafe fn lock<'a>(s: *const Scan) -> Option<&'a RwLock<Tree>> { s.as_ref()?.shared.tree.get() }
unsafe fn tree<'a>(s: *const Scan) -> Option<std::sync::RwLockReadGuard<'a, Tree>> { lock(s)?.read().ok() }
unsafe fn edit<'a>(s: *const Scan) -> Option<std::sync::RwLockWriteGuard<'a, Tree>> { lock(s)?.write().ok() }

fn dir(t: &Tree, id: u32) -> Option<SoEntry> {
    let d = t.dirs.get(id as usize)?;
    Some(SoEntry { name: d.name.as_ptr(), name_len: d.name.len() as u64, size: d.size, items: d.items, mtime: d.mtime, id, parent: d.parent, denied: d.denied })
}

fn file(name: &[u8], size: u64, mtime: i64, parent: u32) -> SoEntry {
    SoEntry { name: name.as_ptr(), name_len: name.len() as u64, size, items: 1, mtime, id: NONE, parent, denied: false }
}

/// # Safety
/// `path` must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn so_scan_start(path: *const c_char, threads: u32) -> *mut Scan {
    let p = Path::new(OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
    Box::into_raw(Box::new(Scan::start(p, threads as usize)))
}

/// # Safety
/// `s` must come from so_scan_start; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn so_scan_progress(s: *const Scan, out: *mut SoProgress) {
    let h = &(*s).shared;
    *out = SoProgress { items: h.items.load(Relaxed), bytes: h.bytes.load(Relaxed), denied: h.denied.load(Relaxed), done: h.tree.get().is_some() };
}

/// # Safety
/// `s` must come from so_scan_start and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn so_scan_free(s: *mut Scan) {
    if !s.is_null() { drop(Box::from_raw(s)); }
}

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_find(s: *const Scan, rel: *const c_char) -> u32 {
    tree(s).map_or(NONE, |t| t.find(CStr::from_ptr(rel).to_bytes()))
}

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_entry(s: *const Scan, id: u32, ctx: *mut c_void, cb: Callback) -> bool {
    let Some(t) = tree(s) else { return false };
    match dir(&t, id) {
        Some(e) => { cb(ctx, &e); true }
        None => false,
    }
}

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_child_dirs(s: *const Scan, id: u32, ctx: *mut c_void, cb: Callback) {
    let Some(t) = tree(s) else { return };
    for c in t.children(id) {
        if let Some(e) = dir(&t, c) { cb(ctx, &e); }
    }
}

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_child_files(s: *const Scan, id: u32, ctx: *mut c_void, cb: Callback) {
    let Some(t) = tree(s) else { return };
    if (id as usize) < t.dirs.len() {
        t.files(id, |n, size, m| cb(ctx, &file(n, size, m, id)));
    }
}

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_large_files(s: *const Scan, ctx: *mut c_void, cb: Callback) {
    let Some(t) = tree(s) else { return };
    for l in t.large.iter().filter(|l| !l.gone && !t.is_gone(l.parent)) { cb(ctx, &file(&l.name, l.size, l.mtime, l.parent)); }
}

#[repr(C)]
pub struct SoMeasure { size: u64, frees: u64, items: u64, denied: u64 }

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_measure(path: *const c_char, out: *mut SoMeasure) {
    let m = crate::measure(Path::new(OsStr::from_bytes(CStr::from_ptr(path).to_bytes())));
    *out = SoMeasure { size: m.size, frees: m.frees, items: m.items, denied: m.denied };
}

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_set_dir_gone(s: *const Scan, id: u32, gone: bool) {
    if let Some(mut t) = edit(s) { t.set_dir_gone(id, gone); }
}

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_set_file_gone(s: *const Scan, parent: u32, name: *const c_char, size: u64, gone: bool) {
    if let Some(mut t) = edit(s) { t.set_file_gone(parent, CStr::from_ptr(name).to_bytes(), size, gone); }
}

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_rename_dir(s: *const Scan, id: u32, name: *const c_char) {
    if let Some(mut t) = edit(s) { t.rename_dir(id, CStr::from_ptr(name).to_bytes()); }
}

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_rename_file(s: *const Scan, parent: u32, old: *const c_char, new: *const c_char) {
    if let Some(mut t) = edit(s) { t.rename_file(parent, CStr::from_ptr(old).to_bytes(), CStr::from_ptr(new).to_bytes()); }
}

/// # Safety
/// Pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn so_add_dir(s: *const Scan, parent: u32, name: *const c_char, mtime: i64) {
    if let Some(mut t) = edit(s) { t.add_dir(parent, CStr::from_ptr(name).to_bytes(), mtime); }
}
