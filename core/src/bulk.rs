//! Directory listing with getattrlistbulk: names and sizes in one system call.
use std::ffi::CStr;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

pub struct Item<'a> {
    pub name: &'a [u8],
    pub is_dir: bool,
    pub dev: i32,
    pub inode: u64,
    pub links: u32,
    pub size: u64,
    /// Bytes not shared with clones or snapshots. Only filled when asked for.
    pub private: u64,
    pub mtime: i64,
    pub flags: u32,
}

/// Cloud placeholder: its contents aren't on this disk and reading downloads them.
pub const SF_DATALESS: u32 = 0x4000_0000;

const NAME: u32 = 0x1;
const DEVID: u32 = 0x2;
const OBJTYPE: u32 = 0x8;
const MODTIME: u32 = 0x400;
const FLAGS: u32 = 0x4_0000;
const FILEID: u32 = 0x200_0000;
const ERROR: u32 = 0x2000_0000;
const RETURNED: u32 = 0x8000_0000;
const F_LINKS: u32 = 0x1;
const F_ALLOC: u32 = 0x4;
const X_PRIVATE: u32 = 0x8;
const OPT_EXTENDED: u64 = 0x20;
const VDIR: u32 = 2;

extern "C" {
    fn getattrlistbulk(fd: i32, list: *const libc::attrlist, buf: *mut u8, len: usize, opts: u64) -> i32;
    fn setiopolicy_np(kind: i32, scope: i32, policy: i32) -> i32;
}

/// Stops this thread from downloading cloud files by looking at them.
pub fn no_downloads() {
    unsafe { setiopolicy_np(3, 1, 1) };
}

pub fn new_buffer() -> Vec<u64> {
    vec![0; 32 * 1024]
}

struct Reader<'a>(&'a [u8], usize);
impl Reader<'_> {
    fn u32(&mut self) -> Option<u32> {
        let v = u32::from_ne_bytes(self.0.get(self.1..self.1 + 4)?.try_into().ok()?);
        self.1 += 4;
        Some(v)
    }
    fn u64(&mut self) -> Option<u64> {
        let v = u64::from_ne_bytes(self.0.get(self.1..self.1 + 8)?.try_into().ok()?);
        self.1 += 8;
        Some(v)
    }
}

fn parse(rec: &[u8]) -> Option<Item<'_>> {
    let mut r = Reader(rec, 4);
    let common = r.u32()?;
    let (_, _) = (r.u32()?, r.u32()?);
    let file = r.u32()?;
    let ext = r.u32()?;
    if common & ERROR != 0 && r.u32()? != 0 {
        return None;
    }
    let mut it = Item { name: &[], is_dir: false, dev: 0, inode: 0, links: 1, size: 0, private: 0, mtime: 0, flags: 0 };
    if common & NAME != 0 {
        let at = r.1;
        let off = r.u32()? as i32;
        let len = r.u32()? as usize;
        let start = usize::try_from(at as i64 + off as i64).ok()?;
        it.name = rec.get(start..start + len.checked_sub(1)?)?;
    }
    if common & DEVID != 0 { it.dev = r.u32()? as i32; }
    if common & OBJTYPE != 0 { it.is_dir = r.u32()? == VDIR; }
    if common & MODTIME != 0 { it.mtime = r.u64()? as i64; r.u64()?; }
    if common & FLAGS != 0 { it.flags = r.u32()?; }
    if common & FILEID != 0 { it.inode = r.u64()?; }
    if file & F_LINKS != 0 { it.links = r.u32()?; }
    if file & F_ALLOC != 0 { it.size = r.u64()?; }
    if ext & X_PRIVATE != 0 { it.private = r.u64()?; }
    if it.name.is_empty() { return None; }
    Some(it)
}

/// Lists one folder. Returns the folder's device id. Errors are unreadable folders.
pub fn list(path: &CStr, want_dev: Option<i32>, private: bool, buf: &mut [u64], mut each: impl FnMut(Item)) -> io::Result<i32> {
    let raw = unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd.as_raw_fd(), &mut st) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if want_dev.is_some_and(|d| d != st.st_dev) {
        return Ok(st.st_dev); // another volume is mounted here
    }
    let mut al: libc::attrlist = unsafe { std::mem::zeroed() };
    al.bitmapcount = 5;
    al.commonattr = RETURNED | ERROR | NAME | DEVID | OBJTYPE | MODTIME | FLAGS | FILEID;
    al.fileattr = F_LINKS | F_ALLOC;
    if private { al.forkattr = X_PRIVATE; }
    let opts = if private { OPT_EXTENDED } else { 0 };
    let bytes = buf.len() * 8;
    loop {
        let n = unsafe { getattrlistbulk(fd.as_raw_fd(), &al, buf.as_mut_ptr().cast(), bytes, opts) };
        if n == 0 { return Ok(st.st_dev); }
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted { continue; }
            return Err(e);
        }
        let data = unsafe { std::slice::from_raw_parts(buf.as_ptr().cast::<u8>(), bytes) };
        let mut at = 0;
        for _ in 0..n {
            let len = u32::from_ne_bytes(data[at..at + 4].try_into().unwrap()) as usize;
            if len < 24 || at + len > bytes { break; }
            if let Some(it) = parse(&data[at..at + len]) { each(it); }
            at += len;
        }
    }
}
