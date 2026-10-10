//! Manual checked publication tool: explicit game/staging paths, pinned payloads,
//! exact EXE and game-closed checks are enforced by the same production module.
#[path = "../src/bin/asset_mod/mod.rs"] mod asset_mod;
fn main() {
    let args:Vec<_>=std::env::args().collect();
    assert_eq!(args.len(),3,"expected explicit game and staging paths");
    match asset_mod::profile_publish(1984270,"dsts-mvgl-v1",std::path::Path::new(&args[2]),std::path::Path::new(&args[1])) {
        Ok(root)=>println!("Applied checked asset profile: {}",root.display()),
        Err(error)=>{eprintln!("{error}");std::process::exit(1);}
    }
}
