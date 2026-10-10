//! Narrow, game-adapter-based asset publication. Never enables generic mod launch.
use std::{fs, path::{Path, PathBuf}, io::Read};
use serde_json::Value;
const EXE: &str = "Digimon Story Time Stranger.exe";
const GAME_HASH: &str = "ff9de825a543bf874cfb7e73ed951256d3ce4e8702957afa3b26ca6487a81688";
const ASI_HASH: &str = "06c996ce4b0072aea2b21eda90e1991265a7b3728f069f7d6a1090774060bcaf";
const PROXY_HASH: &str = "412d410eb6091fb483b150bea1b13f8aeb746be8c62802ea7e081fd15ea64b69";
fn digest(path: &Path) -> Result<String, String> {
    use sha2::{Digest,Sha256};
    let mut file=fs::File::open(path).map_err(|_|"hash-open-failed")?;
    let mut hash=Sha256::new();let mut buffer=[0u8;65536];
    loop { let n=file.read(&mut buffer).map_err(|_|"hash-read-failed")?;if n==0{break;}hash.update(&buffer[..n]); }
    Ok(format!("{:x}",hash.finalize()))
}
fn regular(path: &Path) -> Result<u64, String> {
    let m=fs::symlink_metadata(path).map_err(|_| "file-missing")?;
    if !m.is_file() || m.file_type().is_symlink() { return Err("nonregular-file".into()); }
    Ok(m.len())
}
fn checked_hash(path: &Path, expected: &str) -> Result<(), String> {
    regular(path)?;
    if digest(path)? != expected { return Err("hash-mismatch".into()); }
    Ok(())
}
fn key_valid(key: &str) -> bool {
    key.len()<1024 && key.is_ascii()
        && !key.contains('\\') && !key.contains(':') && !key.bytes().any(|b| b<32 || b==127)
        && key.split('/').all(|x| !x.is_empty() && x!="." && x!="..")
}
fn tree(root: &Path, at: &Path, out: &mut Vec<String>, depth: usize) -> Result<(), String> {
    if depth>32 { return Err("depth-limit".into()); }
    for e in fs::read_dir(at).map_err(|_| "tree-unreadable")? {
        let e=e.map_err(|_| "tree-unreadable")?;let t=e.file_type().map_err(|_| "tree-unreadable")?;
        if t.is_symlink() { return Err("symlink-rejected".into()); }
        if t.is_dir() { tree(root,&e.path(),out,depth+1)?; }
        else if t.is_file() { out.push(e.path().strip_prefix(root).unwrap().to_str().ok_or("nonascii-key")?.replace('\\',"/")); }
        else { return Err("special-file-rejected".into()); }
        if out.len()>4099 { return Err("file-limit".into()); }
    }
    Ok(())
}
pub(super) fn validate_stage(stage: &Path) -> Result<(), String> { validate_with_hashes(stage,ASI_HASH,PROXY_HASH) }
fn validate_with_hashes(stage: &Path, asi_hash:&str,proxy_hash:&str) -> Result<(), String> {
    if fs::canonicalize(stage).map_err(|_| "stage-missing")? != stage { return Err("redirected-stage".into()); }
    if regular(&stage.join("manifest.json"))?>1024*1024 { return Err("manifest-limit".into()); }
    let manifest:Value=serde_json::from_slice(&fs::read(stage.join("manifest.json")).map_err(|_| "manifest-unreadable")?).map_err(|_| "manifest-invalid")?;
    if manifest["adapter"]!="dsts-mvgl-v1" || manifest["schema"]!=1 { return Err("unsupported-adapter".into()); }
    let files=manifest["files"].as_object().ok_or("missing-files")?;
    if files.is_empty() || files.len()>4096 { return Err("asset-count".into()); }
    let mut seen=std::collections::HashSet::new();let mut total=0;
    for (key,hash) in files {
        if !key_valid(key) || !seen.insert(key.to_ascii_lowercase()) { return Err("unsafe-or-duplicate-key".into()); }
        let p=stage.join("assets").join(key);
        if fs::canonicalize(&p).map_err(|_| "asset-missing")? != p { return Err("redirected-asset".into()); }
        let size=regular(&p)?;total+=size;
        if size==0 || size>64*1024*1024 || total>256*1024*1024 { return Err("asset-size-limit".into()); }
        let hash=hash.as_str().ok_or("invalid-hash")?;
        checked_hash(&p,hash)?;
    }
    checked_hash(&stage.join("adapter.payload"),asi_hash)?;
    checked_hash(&stage.join("proxy.payload"),proxy_hash)?;
    let mut actual=Vec::new();tree(stage,stage,&mut actual,0)?;
    let expected:std::collections::HashSet<String>=files.keys().map(|k|format!("assets/{k}")).chain(["manifest.json","adapter.payload","proxy.payload"].map(str::to_owned)).collect();
    if actual.into_iter().collect::<std::collections::HashSet<_>>()!=expected { return Err("unexpected-package-files".into()); }
    Ok(())
}
#[cfg(target_os="linux")]
fn publish(source:&Path,dest:&Path)->Result<(),String> {
    use std::os::unix::ffi::OsStrExt;
    let a=std::ffi::CString::new(source.as_os_str().as_bytes()).map_err(|_|"invalid-path")?;
    let b=std::ffi::CString::new(dest.as_os_str().as_bytes()).map_err(|_|"invalid-path")?;
    let r=unsafe{libc::syscall(libc::SYS_renameat2,libc::AT_FDCWD,a.as_ptr(),libc::AT_FDCWD,b.as_ptr(),libc::RENAME_NOREPLACE)};
    if r!=0 { return Err(format!("publish-failed:{}",std::io::Error::last_os_error())); }Ok(())
}
#[cfg(not(target_os="linux"))]
fn publish(_: &Path,_:&Path)->Result<(),String>{Err("linux-required".into())}
pub fn install(app_id:u32,adapter:&str,stage:&Path,game:&Path)->Result<PathBuf,String>{
    if app_id!=1984270 || adapter!="dsts-mvgl-v1" { return Err("unsupported-game-adapter".into()); }
    let game=fs::canonicalize(game).map_err(|_|"game-root-unavailable")?;
    if stage.parent()!=Some(game.as_path()) || !stage.file_name().and_then(|s|s.to_str()).is_some_and(|s| s.starts_with(".bepis-asset-stage-") && s[19..].bytes().all(|b|b.is_ascii_hexdigit() || b==b'-')) { return Err("stage-outside-game".into()); }
    checked_hash(&game.join(EXE),GAME_HASH)?;
    for p in fs::read_dir("/proc").map_err(|_|"process-inspection-unavailable")?.flatten(){
        if let Ok(c)=fs::read(p.path().join("cmdline")){if c.split(|b|*b==0).any(|x| x.ends_with(EXE.as_bytes())) {return Err("game-running".into());}}
    }
    validate_stage(stage)?;
    for entry in fs::read_dir(&game).map_err(|_|"game-unreadable")?.flatten(){
        let name=entry.file_name().to_string_lossy().to_lowercase();
        if name.ends_with(".asi") && name!="bepis-mvgl.asi" {return Err("conflicting-loader".into());}
    }
    for name in ["reloaded-dropin.asi","reloaded-dropin"] {if game.join(name).exists(){return Err("conflicting-loader".into());}}
    for (name,hash) in [("winmm.dll",PROXY_HASH),("bepis-mvgl.asi",ASI_HASH)] {
        let p=game.join(name);
        if p.symlink_metadata().is_ok(){checked_hash(&p,hash)?;}
    }
    let destination=game.join(stage.file_name().unwrap().to_str().unwrap().replacen(".bepis-asset-stage-",".bepis-asset-mod-",1));
    publish(stage,&destination)?;
    // New bootstrap files are linked without replacement. A failed partial
    // publication is inert without explicit activation; retain all evidence.
    for (name,hash) in [("bepis-mvgl.asi",ASI_HASH),("winmm.dll",PROXY_HASH)] {
        let p=game.join(name);
        if let Err(e)=fs::hard_link(destination.join(if name=="bepis-mvgl.asi"{"adapter.payload"}else{"proxy.payload"}),&p){
            if e.kind()!=std::io::ErrorKind::AlreadyExists {return Err("bootstrap-publication-failed-retained".into());}
        }
        checked_hash(&p,hash)?;
    }
    Ok(destination.join("assets"))
}
#[cfg(test)] mod tests {
    use super::*;
    #[test]fn rejects_unsafe_keys(){for k in ["app_0/images/../x.dds","app_0/images//x.dds","C:/app_0/images/x.dds","app_0/images/x\\y.dds"]{assert!(!key_valid(k),"{k}");}assert!(key_valid("app_0/images/eyes.dds"));assert!(key_valid("app_0/images/pc002a_b01l_01.img"));assert!(key_valid("other/texture.custom"));}
    #[test]fn accepts_raw_img_without_renaming(){
        use sha2::{Digest,Sha256};
        let(r,a,p)=fixture();
        fs::remove_file(r.join("assets/app_0/images/eyes.dds")).unwrap();
        let key="app_0/images/pc002a_b01l_01.img";let bytes=b"raw IMG payload";
        fs::write(r.join("assets").join(key),bytes).unwrap();
        fs::write(r.join("manifest.json"),serde_json::json!({"schema":1,"adapter":"dsts-mvgl-v1","files":{key:format!("{:x}",Sha256::digest(bytes))}}).to_string()).unwrap();
        validate_with_hashes(&r,&a,&p).unwrap();assert!(r.join("assets").join(key).exists());fs::remove_dir_all(r).unwrap();
    }
    #[test]fn rejects_unsupported_adapter_before_io(){assert!(install(1,"dsts-mvgl-v1",Path::new("/missing"),Path::new("/missing")).unwrap_err().contains("unsupported"));}
    static NEXT:std::sync::atomic::AtomicUsize=std::sync::atomic::AtomicUsize::new(0);
    fn fixture()->(PathBuf,String,String){
        use sha2::{Digest,Sha256};
        let root=std::env::temp_dir().join(format!("bepis-asset-tests-{}-{}",std::process::id(),NEXT.fetch_add(1,std::sync::atomic::Ordering::Relaxed)));
        fs::create_dir_all(root.join("assets/app_0/images")).unwrap();
        let mut bytes=vec![0;128];bytes[..4].copy_from_slice(b"DDS ");
        fs::write(root.join("assets/app_0/images/eyes.dds"),&bytes).unwrap();
        fs::write(root.join("adapter.payload"),b"test-asi").unwrap();fs::write(root.join("proxy.payload"),b"test-proxy").unwrap();
        fs::write(root.join("manifest.json"),serde_json::json!({"schema":1,"adapter":"dsts-mvgl-v1","files":{"app_0/images/eyes.dds":format!("{:x}",Sha256::digest(&bytes))}}).to_string()).unwrap();
        (root,format!("{:x}",Sha256::digest(b"test-asi")),format!("{:x}",Sha256::digest(b"test-proxy")))
    }
    #[test]fn valid_snapshot_and_tamper_rejection(){
        let (r,a,p)=fixture();validate_with_hashes(&r,&a,&p).unwrap();
        fs::write(r.join("assets/app_0/images/eyes.dds"),Vec::<u8>::new()).unwrap();assert!(validate_with_hashes(&r,&a,&p).is_err());fs::remove_dir_all(r).unwrap();
    }
    #[test]fn rejects_unexpected_executable(){let(r,a,p)=fixture();fs::write(r.join("evil.dll"),b"MZ").unwrap();assert!(validate_with_hashes(&r,&a,&p).unwrap_err().contains("unexpected"));fs::remove_dir_all(r).unwrap();}
    #[test]fn rejects_bootstrap_hash_mismatch(){let(r,a,p)=fixture();fs::write(r.join("proxy.payload"),b"other").unwrap();assert!(validate_with_hashes(&r,&a,&p).unwrap_err().contains("hash-mismatch"));fs::remove_dir_all(r).unwrap();}
    #[cfg(unix)]#[test]fn rejects_asset_symlink(){let(r,a,p)=fixture();fs::remove_file(r.join("assets/app_0/images/eyes.dds")).unwrap();std::os::unix::fs::symlink(r.join("proxy.payload"),r.join("assets/app_0/images/eyes.dds")).unwrap();assert!(validate_with_hashes(&r,&a,&p).is_err());fs::remove_dir_all(r).unwrap();}
    #[test]fn rejects_duplicate_case_paths(){let(r,a,p)=fixture();let mut j:Value=serde_json::from_slice(&fs::read(r.join("manifest.json")).unwrap()).unwrap();j["files"]["app_0/images/EYES.dds"]=j["files"]["app_0/images/eyes.dds"].clone();fs::write(r.join("manifest.json"),j.to_string()).unwrap();assert!(validate_with_hashes(&r,&a,&p).is_err());fs::remove_dir_all(r).unwrap();}
    #[cfg(target_os="linux")]#[test]fn publication_never_replaces_destination(){let(r,_,_)=fixture();let source=r.join("source");let dest=r.join("dest");fs::create_dir(&source).unwrap();fs::create_dir(&dest).unwrap();fs::write(dest.join("owned"),b"keep").unwrap();assert!(publish(&source,&dest).is_err());assert_eq!(fs::read(dest.join("owned")).unwrap(),b"keep");fs::remove_dir_all(r).unwrap();}

}

pub fn disable(app_id:u32,game:&Path)->Result<(),String>{
    if app_id!=1984270 {return Err("unsupported-game-adapter".into());}
    checked_hash(&game.join(EXE),GAME_HASH)?;
    for p in fs::read_dir("/proc").map_err(|_|"process-inspection-unavailable")?.flatten(){
        if let Ok(c)=fs::read(p.path().join("cmdline")){if c.split(|b|*b==0).any(|x|x.ends_with(EXE.as_bytes())){return Err("game-running".into());}}
    }
    checked_hash(&game.join("bepis-mvgl.asi"),ASI_HASH)?;
    publish(&game.join("bepis-mvgl.asi"),&game.join(".bepis-mvgl.asi.disabled"))
}
