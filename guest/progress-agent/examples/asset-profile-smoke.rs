//! End-to-end publication fixture. Requires a private isolated folder containing
//! the pinned game EXE and adapter.payload/proxy.payload; never launches the EXE.
#[path = "../src/bin/asset_mod/mod.rs"] mod asset_mod;
use std::{fs,path::{Path,PathBuf}};
use serde_json::{json,Value};
use sha2::{Digest,Sha256};
fn stage(game:&Path,id:&str,bytes:Option<&[u8]>,profile:Option<&Value>)->PathBuf{
    let root=game.join(format!(".bepis-asset-stage-{id}"));fs::create_dir(&root).unwrap();fs::create_dir(root.join("assets")).unwrap();
    let mut files=serde_json::Map::new();
    if let Some(bytes)=bytes{let key="app_0/images/pc002a_b01l_01.img";let file=root.join("assets").join(key);fs::create_dir_all(file.parent().unwrap()).unwrap();fs::write(file,bytes).unwrap();files.insert(key.into(),Value::String(format!("{:x}",Sha256::digest(bytes))));}
    fs::write(root.join("manifest.json"),json!({"schema":1,"adapter":"dsts-mvgl-v1","name":id,"files":files}).to_string()).unwrap();
    for name in ["adapter.payload","proxy.payload"]{fs::copy(game.join(name),root.join(name)).unwrap();}
    if let Some(state)=profile{fs::write(root.join("profile.json"),state.to_string()).unwrap();}
    root
}
fn main(){
    let game=fs::canonicalize(std::env::args().nth(1).expect("isolated game fixture directory required")).unwrap();
    assert!(!game.join(".bepis-assets-active").exists(),"fixture must be fresh");
    let first=asset_mod::install(1984270,"dsts-mvgl-v1",&stage(&game,"a",Some(b"one"),None),&game).unwrap();
    let second=asset_mod::install(1984270,"dsts-mvgl-v1",&stage(&game,"b",Some(b"two"),None),&game).unwrap();
    let imported=asset_mod::profile_state(1984270,&game).unwrap();
    assert_eq!(imported["mods"].as_array().unwrap().len(),2);assert!(imported["mods"].as_array().unwrap().iter().all(|m|m["enabled"]==false));
    let mut state=json!({"schema":1,"baseRoot":"","mods":[{"id":"a","name":"Eyes","root":first,"enabled":true},{"id":"b","name":"Costume","root":second,"enabled":true}]});
    let stable=asset_mod::profile_publish(1984270,"dsts-mvgl-v1",&stage(&game,"c",Some(b"two"),Some(&state)),&game).unwrap();
    let asset="app_0/images/pc002a_b01l_01.img";assert_eq!(fs::read(stable.join(asset)).unwrap(),b"two");
    let stale=state.clone();state=asset_mod::profile_state(1984270,&game).unwrap();state["mods"].as_array_mut().unwrap().reverse();
    assert_eq!(stable,asset_mod::profile_publish(1984270,"dsts-mvgl-v1",&stage(&game,"d",Some(b"one"),Some(&state)),&game).unwrap());assert_eq!(fs::read(stable.join(asset)).unwrap(),b"one");
    state=asset_mod::profile_state(1984270,&game).unwrap();state["mods"][1]["enabled"]=Value::Bool(false);
    asset_mod::profile_publish(1984270,"dsts-mvgl-v1",&stage(&game,"e",Some(b"two"),Some(&state)),&game).unwrap();assert_eq!(fs::read(stable.join(asset)).unwrap(),b"two");
    let bad=stage(&game,"f",Some(b"two"),Some(&stale));assert!(asset_mod::profile_publish(1984270,"dsts-mvgl-v1",&bad,&game).unwrap_err().contains("refresh-required"));assert!(bad.exists());
    state=asset_mod::profile_state(1984270,&game).unwrap();for m in state["mods"].as_array_mut().unwrap(){m["enabled"]=Value::Bool(false);}
    asset_mod::profile_publish(1984270,"dsts-mvgl-v1",&stage(&game,"1",None,Some(&state)),&game).unwrap();assert!(!stable.join(asset).exists());
    assert!(first.join(asset).exists() && second.join(asset).exists());
    println!("PASS: actual pinned payload publication, legacy import, stable path, conflict priority, individual/all disable, persisted state, stale-update rejection and retained originals");
}
