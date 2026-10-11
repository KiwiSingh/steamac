//! Checked, game-agnostic x64 DXGI installation. Never replaces an unmanaged file.
use std::{collections::{BTreeMap, BTreeSet}, fs::{self, OpenOptions}, io::{Read, Write}, path::{Path, PathBuf}, os::fd::AsRawFd};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
const COMPILER: &str = "e994847e01a6f1e4cbdc5a864616ac262f67ee4f14db194984661a8d927ab7f4";
const RECEIPT: &str = ".bepis-reshade.json";
fn err(e: impl std::fmt::Display) -> String { format!("reshade:{e}") }
fn regular(path: &Path, limit: u64) -> Result<u64, String> {
    let m = fs::symlink_metadata(path).map_err(err)?;
    if !m.is_file() || m.file_type().is_symlink() || m.len() > limit || fs::canonicalize(path).map_err(err)? != path { return Err("reshade:unsafe-file".into()); }
    Ok(m.len())
}
fn digest(path: &Path) -> Result<String, String> {
    regular(path, 256 * 1024 * 1024)?;
    let mut file = fs::File::open(path).map_err(err)?;
    let mut hash = Sha256::new(); let mut bytes = [0; 65536];
    loop { let n = file.read(&mut bytes).map_err(err)?; if n == 0 { break; } hash.update(&bytes[..n]); }
    Ok(format!("{:x}", hash.finalize()))
}
fn key_valid(key: &str) -> bool {
    !key.is_empty() && key.len() < 1024 && !key.contains(['\\', ':']) && !key.chars().any(|c| c.is_control())
        && key.split('/').all(|s| !s.is_empty() && s != "." && s != "..")
}
fn allowed(key: &str) -> bool {
    key_valid(key) && (key.starts_with("reshade-shaders/") || (!key.contains('/') && (key == "dxgi.dll" || key == "d3dcompiler_47.dll" || key.to_lowercase().ends_with(".ini") || key.ends_with(".addon64"))))
}
fn hash_valid(hash: &str) -> bool { hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()) }
fn pe(path: &Path, dll: bool) -> Result<(), String> {
    use std::io::{Seek, SeekFrom};
    regular(path, 256 * 1024 * 1024)?;
    let mut f = fs::File::open(path).map_err(err)?; let mut dos = [0;64]; f.read_exact(&mut dos).map_err(err)?;
    let offset = u32::from_le_bytes(dos[60..64].try_into().unwrap());
    if &dos[..2] != b"MZ" || offset > 16 * 1024 * 1024 { return Err("reshade:invalid-pe".into()); }
    f.seek(SeekFrom::Start(offset as u64)).map_err(err)?; let mut h = [0;26]; f.read_exact(&mut h).map_err(err)?;
    if &h[..4] != b"PE\0\0" || h[4..6] != [0x64,0x86] || h[24..26] != [0x0b,0x02] || (dll && h[22] & 0x20 == 0) { return Err("reshade:x64-pe-required".into()); } Ok(())
}
fn runtime(path: &Path) -> Result<(), String> {
    regular(path, 128 * 1024 * 1024)?; pe(path,true)?;
    if !fs::read(path).map_err(err)?.windows(7).any(|s| s == b"ReShade") { return Err("reshade:dxgi-is-not-reshade".into()); } Ok(())
}
pub fn target(game: &Path, executable: &Path) -> Result<(PathBuf,String),String> {
    let root = game.canonicalize().map_err(err)?;
    if !executable.starts_with(&root) || executable == root || executable.canonicalize().map_err(err)? != executable
        || !executable.extension().is_some_and(|s| s.eq_ignore_ascii_case("exe")) { return Err("reshade:executable-outside-game".into()); }
    pe(executable,false)?; Ok((executable.parent().ok_or("reshade:executable-parent")?.to_owned(),digest(executable)?))
}
pub fn existing_runtime(game: &Path, executable: &Path) -> Result<Option<String>,String> {
    let (directory,_) = target(game,executable)?;
    let path = directory.join("dxgi.dll");
    match path.symlink_metadata() {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(err(e)),
        Ok(_) => { runtime(&path)?; Ok(Some(digest(&path)?)) }
    }
}
pub fn preflight(game: &Path, executable: &Path) -> Result<(PathBuf,String),String> {
    let result = target(game,executable)?; stopped(executable)?; Ok(result)
}
pub fn installed(app_id: u32, game: &Path, executable: &Path) -> Result<bool,String> {
    installed_checked(app_id,game,executable,COMPILER)
}
fn installed_checked(app_id: u32, game: &Path, executable: &Path, compiler_hash: &str) -> Result<bool,String> {
    let (directory,_) = target(game,executable)?;
    let path = directory.join(RECEIPT);
    if path.symlink_metadata().is_err() { return Ok(false); }
    let receipt = read_json(&path)?;
    if receipt["schema"] != 1 || receipt["appId"] != app_id || receipt["executable"].as_str() != executable.to_str() { return Err("reshade:receipt-mismatch".into()); }
    runtime(&directory.join("dxgi.dll"))?;
    if digest(&directory.join("d3dcompiler_47.dll"))? != compiler_hash { return Err("reshade:compiler-changed".into()); }
    Ok(true)
}
fn stopped(executable: &Path) -> Result<(),String> {
    let name = executable.file_name().ok_or("reshade:executable-name")?.as_encoded_bytes();
    for entry in fs::read_dir("/proc").map_err(err)? {
        let entry = entry.map_err(err)?;
        if let Ok(cmd) = fs::read(entry.path().join("cmdline")) {
            if cmd.split(|b| *b == 0).any(|arg| arg.ends_with(name)) { return Err("reshade:game-running-close-it-first".into()); }
        }
    } Ok(())
}
fn tree(root: &Path, at: &Path, out: &mut BTreeSet<String>, depth: usize) -> Result<(),String> {
    if depth > 32 { return Err("reshade:directory-depth-limit".into()); }
    for entry in fs::read_dir(at).map_err(err)? {
        let entry = entry.map_err(err)?; let kind = entry.file_type().map_err(err)?;
        if kind.is_symlink() { return Err("reshade:symlink-rejected".into()); }
        if kind.is_dir() { tree(root,&entry.path(),out,depth+1)?; }
        else if kind.is_file() { out.insert(entry.path().strip_prefix(root).unwrap().to_str().ok_or("reshade:invalid-filename")?.to_owned()); }
        else { return Err("reshade:special-file-rejected".into()); }
        if out.len() > 4096 { return Err("reshade:file-count-limit".into()); }
    } Ok(())
}
fn parent_checked(root: &Path, key: &str, create: bool) -> Result<(),String> {
    let mut at = root.to_owned(); let parts: Vec<_> = key.split('/').collect();
    for (i, part) in parts.iter().enumerate() {
        // Windows sees case aliases even on a case-sensitive guest filesystem.
        for entry in fs::read_dir(&at).map_err(err)? {
            let name = entry.map_err(err)?.file_name(); let name = name.to_string_lossy();
            if name.to_lowercase() == part.to_lowercase() && name != *part { return Err("reshade:case-conflict".into()); }
        }
        at.push(part);
        if i + 1 < parts.len() {
            if !at.exists() && create { fs::create_dir(&at).map_err(err)?; }
            if at.symlink_metadata().is_err() && !create { return Ok(()); }
            let m = fs::symlink_metadata(&at).map_err(err)?;
            if !m.is_dir() || m.file_type().is_symlink() || at.canonicalize().map_err(err)? != at { return Err("reshade:redirected-directory".into()); }
        } else if at.symlink_metadata().is_ok() { regular(&at,128*1024*1024)?; }
    } Ok(())
}
fn exclusive_copy(source: &Path, destination: &Path) -> Result<(),String> {
    let mut input = fs::File::open(source).map_err(err)?;
    let mut output = OpenOptions::new().write(true).create_new(true).open(destination).map_err(err)?;
    std::io::copy(&mut input,&mut output).map_err(err)?; output.sync_all().map_err(err)
}
fn exchange(a: &Path, b: &Path) -> Result<(),String> {
    use std::os::unix::ffi::OsStrExt;
    let a = std::ffi::CString::new(a.as_os_str().as_bytes()).map_err(err)?;
    let b = std::ffi::CString::new(b.as_os_str().as_bytes()).map_err(err)?;
    let result = unsafe { libc::syscall(libc::SYS_renameat2,libc::AT_FDCWD,a.as_ptr(),libc::AT_FDCWD,b.as_ptr(),libc::RENAME_EXCHANGE) };
    if result != 0 { return Err(err(std::io::Error::last_os_error())); } Ok(())
}
fn read_json(path: &Path) -> Result<Value,String> {
    regular(path,1024*1024)?;
    serde_json::from_slice(&fs::read(path).map_err(err)?).map_err(err)
}

pub fn install(app_id: u32, stage: &Path, game: &Path) -> Result<(),String> {
    install_checked(app_id,stage,game,COMPILER,None)
}
fn install_checked(app_id: u32, stage: &Path, game: &Path, compiler_hash: &str, fail_after: Option<usize>) -> Result<(),String> {
    let manifest = read_json(&stage.join("manifest.json"))?;
    if manifest["schema"] != 1 || manifest["appId"] != app_id { return Err("reshade:manifest-game-mismatch".into()); }
    let executable = PathBuf::from(manifest["executable"].as_str().ok_or("reshade:missing-executable")?);
    let (directory, exe_hash) = target(game,&executable)?;
    if manifest["executableHash"] != exe_hash { return Err("reshade:executable-changed".into()); }
    if stage.parent() != Some(directory.as_path()) || stage.canonicalize().map_err(err)? != stage
        || !stage.file_name().and_then(|s| s.to_str()).is_some_and(|s| s.strip_prefix(".bepis-reshade-stage-").is_some_and(|id| id.len()==36 && id.bytes().all(|b|b.is_ascii_hexdigit() || b==b'-'))) { return Err("reshade:stage-outside-target".into()); }
    let lock = OpenOptions::new().read(true).write(true).create(true).truncate(false).custom_flags(libc::O_NOFOLLOW).open(directory.join(".bepis-reshade.lock")).map_err(err)?;
    regular(&directory.join(".bepis-reshade.lock"),0)?;
    if unsafe { libc::flock(lock.as_raw_fd(),libc::LOCK_EX|libc::LOCK_NB) } != 0 { return Err("reshade:installation-busy".into()); }
    stopped(&executable)?;
    let declared = manifest["files"].as_object().ok_or("reshade:missing-files")?;
    if declared.is_empty() || declared.len() > 4096 || !declared.contains_key("ReShade.ini") { return Err("reshade:invalid-file-count-or-config".into()); }
    let mut hashes = BTreeMap::new(); let mut seen = BTreeSet::new(); let mut total = 0u64;
    for (key, hash) in declared {
        let hash = hash.as_str().ok_or("reshade:invalid-hash")?;
        if !allowed(key) || !hash_valid(hash) || !seen.insert(key.to_lowercase()) { return Err("reshade:unsafe-or-duplicate-path".into()); }
        let source = stage.join("files").join(key); total += regular(&source,128*1024*1024)?;
        if total > 1024*1024*1024 || digest(&source)? != hash { return Err("reshade:size-or-hash-mismatch".into()); }
        if key == "dxgi.dll" { runtime(&source)?; }
        if key == "d3dcompiler_47.dll" && hash != compiler_hash { return Err("reshade:compiler-hash-mismatch".into()); }
        if key.ends_with(".addon64") || key == "d3dcompiler_47.dll" { pe(&source,true)?; }
        parent_checked(&directory,key,false)?;
        hashes.insert(key.clone(),hash.to_owned());
    }
    let mut actual = BTreeSet::new(); tree(&stage.join("files"),&stage.join("files"),&mut actual,0)?;
    if actual != hashes.keys().cloned().collect() { return Err("reshade:unexpected-package-files".into()); }
    for entry in fs::read_dir(stage).map_err(err)? {
        let entry = entry.map_err(err)?;
        if entry.file_name() != "files" && entry.file_name() != "manifest.json" { return Err("reshade:stage-already-used-or-unexpected".into()); }
    }
    if !hashes.contains_key("dxgi.dll") { runtime(&directory.join("dxgi.dll"))?; }
    if !hashes.contains_key("d3dcompiler_47.dll") && digest(&directory.join("d3dcompiler_47.dll"))? != compiler_hash { return Err("reshade:compiler-required".into()); }
    let receipt_path = directory.join(RECEIPT);
    let previous = if receipt_path.symlink_metadata().is_ok() { Some(read_json(&receipt_path)?) } else { None };
    if let Some(ref receipt) = previous {
        if receipt["schema"] != 1 || receipt["appId"] != app_id || receipt["executable"] != manifest["executable"] { return Err("reshade:receipt-mismatch".into()); }
    }
    let mut owned: BTreeMap<String,String> = if let Some(ref receipt) = previous {
        serde_json::from_value(receipt["files"].clone()).map_err(err)?
    } else { BTreeMap::new() };
    let mut changes = Vec::new();
    for (key, hash) in &hashes {
        let destination = directory.join(key);
        let old = if destination.symlink_metadata().is_ok() { Some(digest(&destination)?) } else { None };
        if old.as_deref() == Some(hash) { continue; }
        if let Some(ref old_hash) = old {
            if owned.get(key) != Some(old_hash) {
                if key == "ReShade.ini" && manifest["replaceExistingSettings"] == true {
                    // Explicit configuration-only replacement. Require an actual existing
                    // ReShade runtime and retain the exact previous settings in the journal.
                    runtime(&directory.join("dxgi.dll"))?;
                } else { return Err(format!("reshade:unmanaged-or-edited-file:{key}")); }
            }
        }
        changes.push((key.clone(),hash.clone(),old));
    }
    // Snapshot verified bytes again into an exclusive journal. Leave all evidence and backups
    // inside the game's disk. A failed transaction rolls back only its own exact bytes.
    let journal = stage.join("transaction"); fs::create_dir(&journal).map_err(err)?;
    for (index,(key,hash,_)) in changes.iter().enumerate() {
        let copy = journal.join(index.to_string()); exclusive_copy(&stage.join("files").join(key),&copy)?;
        if digest(&copy)? != *hash { return Err("reshade:stage-changed".into()); }
    }
    for (key,hash) in &hashes { owned.insert(key.clone(),hash.clone()); }
    let new_receipt = journal.join("receipt.json");
    let receipt = json!({"schema":1,"appId":app_id,"executable":manifest["executable"],"executableHash":exe_hash,"name":manifest["name"],"files":owned});
    let mut receipt_file = OpenOptions::new().write(true).create_new(true).open(&new_receipt).map_err(err)?;
    receipt_file.write_all(receipt.to_string().as_bytes()).map_err(err)?; receipt_file.sync_all().map_err(err)?;
    let mut applied: Vec<usize> = Vec::new();
    let operation = (|| -> Result<(),String> {
        stopped(&executable)?;
        if digest(&executable)? != exe_hash { return Err("reshade:executable-changed".into()); }
        for (index,(key,hash,old)) in changes.iter().enumerate() {
            if fail_after == Some(index) { return Err("reshade:injected-publication-failure".into()); }
            stopped(&executable)?; parent_checked(&directory,key,true)?;
            let destination = directory.join(key); let copy = journal.join(index.to_string());
            if let Some(old_hash) = old {
                if digest(&destination)? != *old_hash { return Err("reshade:destination-changed".into()); }
                exchange(&copy,&destination)?; applied.push(index);
                if digest(&copy)? != *old_hash { return Err("reshade:destination-raced".into()); }
            } else { fs::hard_link(&copy,&destination).map_err(err)?; applied.push(index); }
            if digest(&destination)? != *hash { return Err("reshade:publication-hash-mismatch".into()); }
        }
        stopped(&executable)?;
        if previous.is_some() {
            if read_json(&receipt_path)? != previous.clone().unwrap() { return Err("reshade:receipt-changed".into()); }
            exchange(&new_receipt,&receipt_path)?;
        } else { fs::hard_link(&new_receipt,&receipt_path).map_err(err)?; }
        Ok(())
    })();
    if let Err(error) = operation {
        let mut rollback_complete = true;
        for index in applied.into_iter().rev() {
            let (key,hash,old) = &changes[index]; let destination = directory.join(key);
            if digest(&destination).ok().as_ref() != Some(hash) { rollback_complete = false; continue; }
            let result = if old.is_some() { exchange(&journal.join(index.to_string()),&destination) } else { fs::remove_file(&destination).map_err(err) };
            if result.is_err() { rollback_complete = false; }
        }
        return Err(format!("{error};rollback={rollback_complete};journal={}",journal.display()));
    }
    Ok(())
}
use std::os::unix::fs::OpenOptionsExt;

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture { root: PathBuf, compiler: String }
    impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.root); } }
    fn binary(dll: bool) -> Vec<u8> {
        let mut b = vec![0u8;128]; b[..2].copy_from_slice(b"MZ"); b[60] = 64;
        b[64..68].copy_from_slice(b"PE\0\0"); b[68..70].copy_from_slice(&[0x64,0x86]);
        b[88..90].copy_from_slice(&[0x0b,0x02]); if dll { b[86] = 0x20; }
        b[100..107].copy_from_slice(b"ReShade"); b
    }
    fn fixture() -> Fixture {
        let root = std::env::temp_dir().join(format!("reshade-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir(&root).unwrap(); fs::write(root.join("fixture-game.exe"),binary(false)).unwrap();
        fs::write(root.join("winmm.dll"),b"existing asset proxy").unwrap();
        fs::write(root.join("bepis-mvgl.asi"),b"existing asset loader").unwrap();
        fs::write(root.join(".bepis-assets-active"),b"untouched profile sentinel").unwrap();
        let compiler = format!("{:x}",Sha256::digest(binary(true))); Fixture { root,compiler }
    }
    fn stage(f: &Fixture, id: u8, preset: &[u8], runtime_files: bool) -> PathBuf {
        let path = f.root.join(format!(".bepis-reshade-stage-00000000-0000-0000-0000-{id:012}"));
        fs::create_dir_all(path.join("files/reshade-shaders/Shaders")).unwrap();
        let mut files = BTreeMap::from([("ReShade.ini",b"[GENERAL]\nPresetPath=.\\My preset.ini\n".to_vec()),("My preset.ini",preset.to_vec()),("reshade-shaders/Shaders/example.fx",b"shader".to_vec())]);
        if runtime_files { files.insert("dxgi.dll",binary(true)); files.insert("d3dcompiler_47.dll",binary(true)); }
        let mut hashes = BTreeMap::new();
        for (key,bytes) in files { fs::write(path.join("files").join(key),&bytes).unwrap(); hashes.insert(key,format!("{:x}",Sha256::digest(bytes))); }
        let exe = f.root.join("fixture-game.exe");
        fs::write(path.join("manifest.json"),json!({"schema":1,"appId":42,"executable":exe,"executableHash":digest(&exe).unwrap(),"files":hashes}).to_string()).unwrap(); path
    }
    fn install_test(f: &Fixture,s: &Path) -> Result<(),String> { install_checked(42,s,&f.root,&f.compiler,None) }
    fn intact(f: &Fixture) {
        assert_eq!(fs::read(f.root.join("winmm.dll")).unwrap(),b"existing asset proxy");
        assert_eq!(fs::read(f.root.join("bepis-mvgl.asi")).unwrap(),b"existing asset loader");
        assert_eq!(fs::read(f.root.join(".bepis-assets-active")).unwrap(),b"untouched profile sentinel");
    }
    #[test] fn full_install_idempotent_and_preset_update_preserve_other_loaders() {
        let f = fixture(); let s = stage(&f,1,b"Techniques=A",true); install_test(&f,&s).unwrap(); intact(&f);
        let s = stage(&f,2,b"Techniques=A",true); install_test(&f,&s).unwrap(); intact(&f);
        let s = stage(&f,3,b"Techniques=B",false); install_test(&f,&s).unwrap(); intact(&f);
        assert_eq!(fs::read(f.root.join("My preset.ini")).unwrap(),b"Techniques=B");
        let backup = s.join("transaction/0"); assert_eq!(fs::read(backup).unwrap(),b"Techniques=A");
    }
    #[test] fn unmanaged_conflict_is_rejected_before_publication() {
        let f=fixture(); let s=stage(&f,1,b"Techniques=A",true); fs::write(f.root.join("ReShade.ini"),b"user settings").unwrap();
        assert!(install_test(&f,&s).unwrap_err().contains("unmanaged")); assert!(!f.root.join("dxgi.dll").exists()); intact(&f);
    }
    #[test] fn edited_managed_settings_are_preserved() {
        let f=fixture();let s=stage(&f,1,b"Techniques=A",true); install_test(&f,&s).unwrap();
        fs::write(f.root.join("My preset.ini"),b"user edits").unwrap(); let s=stage(&f,2,b"Techniques=B",false);
        assert!(install_test(&f,&s).unwrap_err().contains("edited")); assert_eq!(fs::read(f.root.join("My preset.ini")).unwrap(),b"user edits"); intact(&f);
    }
    #[test] fn tampered_stage_and_extra_files_rejected() {
        let f=fixture(); let s=stage(&f,1,b"Techniques=A",true); fs::write(s.join("files/dxgi.dll"),b"tampered").unwrap();
        assert!(install_test(&f,&s).is_err()); assert!(!f.root.join("ReShade.ini").exists());
        let s=stage(&f,2,b"Techniques=A",true); fs::write(s.join("files/extra.ini"),b"extra").unwrap();
        assert!(install_test(&f,&s).unwrap_err().contains("unexpected")); intact(&f);
    }
    #[test] fn wrong_game_or_changed_executable_rejected() {
        let f=fixture();let s=stage(&f,1,b"Techniques=A",true);
        assert!(install_checked(43,&s,&f.root,&f.compiler,None).unwrap_err().contains("game-mismatch"));
        let mut b=binary(false);b[127]=1;fs::write(f.root.join("fixture-game.exe"),b).unwrap();
        assert!(install_test(&f,&s).unwrap_err().contains("executable-changed"));intact(&f);
    }
    #[test] fn traversal_and_case_aliases_rejected() {
        for key in ["../winmm.dll","/dxgi.dll","C:/dxgi.dll","reshade-shaders//a","reshade-shaders/../a","winmm.dll","bepis-mvgl.asi"] { assert!(!allowed(key)); }
        let f=fixture();let s=stage(&f,1,b"Techniques=A",true);fs::write(f.root.join("DXGI.dll"),b"other proxy").unwrap();
        assert!(install_test(&f,&s).unwrap_err().contains("case-conflict"));intact(&f);
    }
    #[test] fn symlinked_destination_and_payload_rejected() {
        let f=fixture();let s=stage(&f,1,b"Techniques=A",true);let outside=f.root.join("sentinel");fs::write(&outside,b"untouched").unwrap();
        std::os::unix::fs::symlink(&outside,f.root.join("ReShade.ini")).unwrap();assert!(install_test(&f,&s).is_err());
        fs::remove_file(f.root.join("ReShade.ini")).unwrap();fs::remove_file(s.join("files/dxgi.dll")).unwrap();
        std::os::unix::fs::symlink(&outside,s.join("files/dxgi.dll")).unwrap();assert!(install_test(&f,&s).is_err());assert_eq!(fs::read(outside).unwrap(),b"untouched");intact(&f);
    }
    #[test] fn partial_publication_rolls_back_and_keeps_journal() {
        let f=fixture();let s=stage(&f,1,b"Techniques=A",true);
        let e=install_checked(42,&s,&f.root,&f.compiler,Some(1)).unwrap_err();assert!(e.contains("rollback=true"));
        assert!(!f.root.join("ReShade.ini").exists());assert!(!f.root.join(RECEIPT).exists());assert!(s.join("transaction").is_dir());intact(&f);
    }
    #[test] fn managed_replacement_rolls_back_on_later_failure() {
        let f=fixture();let s=stage(&f,1,b"Techniques=A",true);install_test(&f,&s).unwrap();let original_receipt=fs::read(f.root.join(RECEIPT)).unwrap();
        let s=stage(&f,2,b"Techniques=B",false);
        let mut manifest=read_json(&s.join("manifest.json")).unwrap();let bytes=b"new shader";fs::write(s.join("files/reshade-shaders/Shaders/example.fx"),bytes).unwrap();
        manifest["files"]["reshade-shaders/Shaders/example.fx"]=json!(format!("{:x}",Sha256::digest(bytes)));fs::write(s.join("manifest.json"),manifest.to_string()).unwrap();
        assert!(install_checked(42,&s,&f.root,&f.compiler,Some(1)).unwrap_err().contains("rollback=true"));
        assert_eq!(fs::read(f.root.join("My preset.ini")).unwrap(),b"Techniques=A");assert_eq!(fs::read(f.root.join(RECEIPT)).unwrap(),original_receipt);intact(&f);
    }
    #[test] fn preset_only_requires_existing_runtime_and_compiler() {
        let f=fixture();let s=stage(&f,1,b"Techniques=A",false);assert!(install_test(&f,&s).is_err());assert!(!f.root.join("ReShade.ini").exists());
    }
    #[test] fn runtime_architecture_and_identity_checked() {
        let f=fixture();let p=f.root.join("wrong.dll");let mut b=binary(true);b[68]=0x4c;b[69]=1;fs::write(&p,b).unwrap();assert!(runtime(&p).is_err());
        let mut b=binary(true);b[100..107].fill(0);fs::write(&p,b).unwrap();assert!(runtime(&p).unwrap_err().contains("not-reshade"));
    }
    #[test] fn persisted_state_detects_installation_and_broken_compiler() {
        let f=fixture();let exe=f.root.join("fixture-game.exe");
        assert!(!installed_checked(42,&f.root,&exe,&f.compiler).unwrap());
        let s=stage(&f,1,b"Techniques=A",true);install_test(&f,&s).unwrap();
        assert!(installed_checked(42,&f.root,&exe,&f.compiler).unwrap());
        assert!(installed_checked(43,&f.root,&exe,&f.compiler).is_err());
        fs::write(f.root.join("d3dcompiler_47.dll"),b"changed").unwrap();
        assert!(installed_checked(42,&f.root,&exe,&f.compiler).is_err());intact(&f);
    }
    #[test] fn running_game_stops_preflight_and_publication() {
        let f=fixture();let s=stage(&f,1,b"Techniques=A",true);
        let unique=f.root.join(format!("running-{}.exe",f.root.file_name().unwrap().to_string_lossy()));
        fs::rename(f.root.join("fixture-game.exe"),&unique).unwrap();
        let mut manifest=read_json(&s.join("manifest.json")).unwrap();manifest["executable"]=json!(unique);fs::write(s.join("manifest.json"),manifest.to_string()).unwrap();
        let mut child=std::process::Command::new("/bin/sh").args(["-c","read value; :",unique.to_str().unwrap()]).stdin(std::process::Stdio::piped()).spawn().unwrap();
        // spawn can return before the child publishes its final argv under the
        // container runtime. Wait for observable process evidence before testing it.
        let cmdline=PathBuf::from(format!("/proc/{}/cmdline",child.id()));
        let mut visible=false;
        for _ in 0..100 {
            if fs::read(&cmdline).unwrap_or_default().split(|b|*b==0).any(|arg|arg.ends_with(unique.file_name().unwrap().as_encoded_bytes())) { visible=true; break; }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        if !visible { let actual=fs::read(&cmdline);let _=child.kill();let _=child.wait();panic!("test process argv not visible: {actual:?}"); }
        assert!(preflight(&f.root,&unique).unwrap_err().contains("game-running"));
        assert!(install_test(&f,&s).unwrap_err().contains("game-running"));
        let _=child.kill();let _=child.wait();assert!(!f.root.join("ReShade.ini").exists());intact(&f);
    }

    #[test] fn explicit_settings_replacement_keeps_backup_and_requires_reshade() {
        let f=fixture();let s=stage(&f,1,b"Techniques=A",true);
        fs::write(f.root.join("ReShade.ini"),b"original user settings").unwrap();
        let mut m=read_json(&s.join("manifest.json")).unwrap();m["replaceExistingSettings"]=json!(true);fs::write(s.join("manifest.json"),m.to_string()).unwrap();
        assert!(install_test(&f,&s).is_err());assert_eq!(fs::read(f.root.join("ReShade.ini")).unwrap(),b"original user settings");
        fs::write(f.root.join("dxgi.dll"),binary(true)).unwrap();install_test(&f,&s).unwrap();
        assert!(fs::read_dir(s.join("transaction")).unwrap().any(|e|fs::read(e.unwrap().path()).ok().as_deref()==Some(b"original user settings")));
        intact(&f);
    }
    #[test] fn runtime_discovery_preserves_existing_and_rejects_foreign_proxy() {
        let f=fixture();let exe=f.root.join("fixture-game.exe");assert!(existing_runtime(&f.root,&exe).unwrap().is_none());
        fs::write(f.root.join("dxgi.dll"),b"foreign proxy").unwrap();assert!(existing_runtime(&f.root,&exe).is_err());
        fs::write(f.root.join("dxgi.dll"),binary(true)).unwrap();assert!(existing_runtime(&f.root,&exe).unwrap().is_some());
    }

}
