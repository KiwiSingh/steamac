use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd};
use std::ffi::{CString, CStr};
use std::time::{Instant, Duration};
use std::path::Path;
use serde_json::{Value, json};

pub fn inventory(root: &Path) -> Result<Value, String> {
    let mut dir = File::open("/").map_err(|e| e.to_string())?;
    for component in root.components() {
        match component {
            std::path::Component::RootDir => (),
            std::path::Component::Normal(name) => {
                use std::os::unix::ffi::OsStrExt;
                dir = child_dir(&dir, name.as_bytes())?;
            }
            _ => return Err("invalid-root-components".into()),
        }
    }
    let dev = stat_fd(&dir)?.st_dev;
    let mut state = State { entries: Vec::new(), issues: Vec::new(), started: Instant::now(), bytes: 0, root_mount: mount_id(&dir)? };
    walk(&dir, "", dev, 0, &mut state)?;
    Ok(json!({"root":root.to_str().ok_or("non-utf8-root")?,"entries":state.entries,
        "issues":state.issues,"complete":state.issues.is_empty(),
        "limits":{"entries":4096,"depth":12,"seconds":3,"jsonBytes":600000}}))
}
// Enumerate account names only, then descend exclusively into this AppID's subtree.
pub fn userdata(root: &Path, app_id: u32) -> Result<Value, String> {
    let mut dir=File::open("/").map_err(|e|e.to_string())?;
    for c in root.components() { match c {
        std::path::Component::RootDir=>(),
        std::path::Component::Normal(n)=> { use std::os::unix::ffi::OsStrExt; dir=child_dir(&dir,n.as_bytes())?; },
        _=>return Err("invalid-root".into())
    } }
    let dev=stat_fd(&dir)?.st_dev;
    let mut state=State{entries:Vec::new(),issues:Vec::new(),started:Instant::now(),bytes:0,root_mount:mount_id(&dir)?};
    // /proc descriptor path is used only to enumerate this already-open directory.
    let accounts=std::fs::read_dir(format!("/proc/self/fd/{}",dir.as_raw_fd())).map_err(|e|e.to_string())?;
    for (count,item) in accounts.enumerate() {
        if count >= 64 || state.started.elapsed()>Duration::from_secs(3) { state.issues.push("account/time-limit".into());break; }
        let item=item.map_err(|e|e.to_string())?;
        let name=item.file_name(); let name=name.to_str().ok_or("non-utf8-account")?;
        if name.is_empty() || !name.bytes().all(|b|b.is_ascii_digit()) { continue; }
        let account=match child_dir(&dir,name.as_bytes()) { Ok(d)=>d,Err(_)=>{state.issues.push(format!("account-unsafe:{name}"));continue;} };
        let app=app_id.to_string();
        match child_dir(&account,app.as_bytes()) {
            Ok(child)=> {
                let meta=stat_fd(&child)?;
                if meta.st_dev!=dev || mount_id(&child)?!=state.root_mount { state.issues.push(format!("userdata-mount-crossing:{name}/{app}"));continue; }
                walk(&child,&format!("{name}/{app}"),dev,0,&mut state)?;
            },
            Err(e)=> {
                // Distinguish an absent AppID subtree from unreadable/unsafe paths.
                let app_c=CString::new(app).unwrap(); let mut st=unsafe{std::mem::zeroed()};
                let rc=unsafe{libc::fstatat(account.as_raw_fd(),app_c.as_ptr(),&mut st,libc::AT_SYMLINK_NOFOLLOW)};
                if rc==0 || std::io::Error::last_os_error().raw_os_error()!=Some(libc::ENOENT) { state.issues.push(format!("userdata-unavailable:{name}:{e}")); }
            }
        }
    }
    Ok(json!({"root":root.to_str().ok_or("invalid-root")?,"entries":state.entries,"issues":state.issues,"complete":state.issues.is_empty()}))
}

fn mount_id(file: &File) -> Result<u64, String> {
    let text=std::fs::read_to_string(format!("/proc/self/fdinfo/{}",file.as_raw_fd())).map_err(|e|e.to_string())?;
    if text.len()>4096 { return Err("fdinfo-too-large".into()); }
    text.lines().find_map(|line|line.strip_prefix("mnt_id:").and_then(|id|id.trim().parse().ok())).ok_or("mount-id-unavailable".into())
}

fn stat_fd(file: &File) -> Result<libc::stat, String> {
    let mut st = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(file.as_raw_fd(), &mut st) } != 0 { return Err(std::io::Error::last_os_error().to_string()) }
    Ok(st)
}
fn child_dir(parent: &File, name: &[u8]) -> Result<File, String> {
    let name = CString::new(name).map_err(|_| "invalid-name")?;
    let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), libc::O_RDONLY|libc::O_DIRECTORY|libc::O_NOFOLLOW|libc::O_CLOEXEC) };
    if fd < 0 { return Err(std::io::Error::last_os_error().to_string()) }
    Ok(unsafe { File::from_raw_fd(fd) })
}
struct State { entries: Vec<Value>, issues: Vec<String>, started: Instant, bytes: usize, root_mount: u64 }
fn walk(dir: &File, relative: &str, root_dev: libc::dev_t, depth: usize, state: &mut State) -> Result<(), String> {
    if mount_id(dir)? != state.root_mount { state.issues.push(format!("mount-changed/not-traversed:{relative}")); return Ok(()); }
    if depth > 12 { state.issues.push(format!("depth-limit:{relative}")); return Ok(()) }
    // fdopendir owns the duplicated descriptor; no path-based traversal is used.
    let duplicate = unsafe { libc::dup(dir.as_raw_fd()) };
    if duplicate < 0 { return Err("dup-failed".into()) }
    let stream = unsafe { libc::fdopendir(duplicate) };
    if stream.is_null() { unsafe { libc::close(duplicate); } return Err("fdopendir-failed".into()) }
    struct Close(*mut libc::DIR);
    impl Drop for Close { fn drop(&mut self) { unsafe { libc::closedir(self.0); } } }
    let _close = Close(stream);
    loop {
        if state.issues.len() >= 64 || state.entries.len() >= 4096 || state.bytes >= 600000 || state.started.elapsed() > Duration::from_secs(3) {
            state.issues.push("entry/byte/time-limit:inventory-truncated".into()); return Ok(())
        }
        unsafe { *libc::__errno_location() = 0; }
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            if unsafe { *libc::__errno_location() } != 0 { state.issues.push(format!("readdir-failed:{relative}")); }
            break;
        }
        let bytes = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if bytes == b"." || bytes == b".." { continue }
        let name = match std::str::from_utf8(bytes) { Ok(n) => n, Err(_) => { state.issues.push("non-utf8-name".into()); continue } };
        let path = if relative.is_empty() { name.to_owned() } else { format!("{relative}/{name}") };
        let c_name = CString::new(bytes).map_err(|_| "invalid-name")?;
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstatat(dir.as_raw_fd(), c_name.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) } != 0 {
            state.issues.push(format!("stat-failed:{path}")); continue;
        }
        let kind = match st.st_mode & libc::S_IFMT { libc::S_IFREG => "file", libc::S_IFDIR => "directory", libc::S_IFLNK => "symlink", _ => "other" };
        let path_fd=unsafe { libc::openat(dir.as_raw_fd(),c_name.as_ptr(),libc::O_PATH|libc::O_NOFOLLOW|libc::O_CLOEXEC) };
        if path_fd<0 { state.issues.push(format!("metadata-open-failed:{path}"));continue; }
        let pinned=unsafe{File::from_raw_fd(path_fd)};
        let pinned_stat=stat_fd(&pinned)?;
        if pinned_stat.st_dev!=st.st_dev || pinned_stat.st_ino!=st.st_ino {state.issues.push(format!("entry-changed:{path}"));continue;}
        let mount=mount_id(&pinned)?;
        let crossing = st.st_dev != root_dev || mount != state.root_mount;
        let mut target = None;
        if kind == "symlink" {
            let mut buffer = vec![0u8; 4096];
            let n = unsafe { libc::readlinkat(dir.as_raw_fd(), c_name.as_ptr(), buffer.as_mut_ptr().cast(), buffer.len()) };
            if n < 0 || n as usize == buffer.len() { state.issues.push(format!("readlink-failed/truncated:{path}")); }
            else { target = std::str::from_utf8(&buffer[..n as usize]).ok().map(str::to_owned); if target.is_none() { state.issues.push(format!("non-utf8-link:{path}")); } }
        }
        let value = json!({"path":path,"kind":kind,"size":st.st_size,"mode":st.st_mode & 0o7777,
            "uid":st.st_uid,"gid":st.st_gid,"device":st.st_dev,"inode":st.st_ino,"mountCrossing":crossing,"mountID":mount,"linkTarget":target});
        state.bytes += value.to_string().len(); state.entries.push(value);
        if crossing { state.issues.push(format!("mount-crossing-not-traversed:{path}")); continue }
        if kind == "directory" {
            match child_dir(dir, bytes) {
                Ok(child) => {
                    let opened = stat_fd(&child)?;
                    if opened.st_dev != st.st_dev || opened.st_ino != st.st_ino { state.issues.push(format!("directory-changed:{path}")); continue }
                    walk(&child, &path, root_dev, depth+1, state)?;
                }
                Err(_) => state.issues.push(format!("directory-open-failed:{path}")),
            }
        }
    }
    Ok(())
}
#[cfg(test)] mod tests {
 use super::*;
 #[test] fn links_are_recorded_not_followed() {
   let root = std::env::temp_dir().join(format!("inventory-test-{}",std::process::id()));
   std::fs::create_dir_all(&root).unwrap();
   std::fs::write(root.join("file"),b"fixture").unwrap();
   std::os::unix::fs::symlink("/",root.join("escape")).unwrap();
   let v=inventory(&root).unwrap(); assert_eq!(v["entries"].as_array().unwrap().len(),2);
   assert!(v["entries"].as_array().unwrap().iter().any(|e|e["linkTarget"]=="/"));
   assert!(inventory(&root.join("escape")).is_err()); std::fs::remove_dir_all(root).unwrap();
 }
 #[test] fn depth_limit_marks_inventory_incomplete() {
   let root=std::env::temp_dir().join(format!("inventory-depth-test-{}",std::process::id()));
   let mut child=root.clone(); for _ in 0..15 { child=child.join("nested"); }
   std::fs::create_dir_all(&child).unwrap();
   let v=inventory(&root).unwrap(); assert_eq!(v["complete"],false);
   assert!(v["issues"].as_array().unwrap().iter().any(|x|x.as_str().unwrap().contains("depth-limit")));
   std::fs::remove_dir_all(root).unwrap();
 }

 #[test] fn userdata_is_confined_to_selected_appid() {
   let root=std::env::temp_dir().join(format!("inventory-userdata-test-{}",std::process::id()));
   std::fs::create_dir_all(root.join("123/1984270/remote")).unwrap();
   std::fs::create_dir_all(root.join("123/999/remote")).unwrap();
   std::fs::write(root.join("123/1984270/remote/save.bin"),b"fixture").unwrap();
   std::fs::write(root.join("123/999/remote/private.bin"),b"other-game").unwrap();
   let v=userdata(&root,1984270).unwrap();
   let entries=v["entries"].as_array().unwrap(); assert!(entries.iter().all(|e|e["path"].as_str().unwrap().starts_with("123/1984270/")));
   assert!(entries.iter().any(|e|e["path"]=="123/1984270/remote/save.bin"));
   std::fs::remove_dir_all(root).unwrap();
 }

 #[test] fn mount_identifiers_distinguish_proc() {
   let root=File::open("/").unwrap(); let proc=File::open("/proc").unwrap();
   assert_ne!(mount_id(&root).unwrap(),mount_id(&proc).unwrap());
 }

}
