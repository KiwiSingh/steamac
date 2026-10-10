//! Explicit manual package publication using production game/hash/closed checks.
#[path = "../src/bin/asset_mod/mod.rs"] mod asset_mod;
fn main(){let args:Vec<_>=std::env::args().collect();assert_eq!(args.len(),3);match asset_mod::install(1984270,"dsts-mvgl-v1",std::path::Path::new(&args[2]),std::path::Path::new(&args[1])){Ok(root)=>println!("{}",root.display()),Err(e)=>{eprintln!("{e}");std::process::exit(1);}}}
