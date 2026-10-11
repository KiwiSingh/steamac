//! Isolated fixtures and explicit manual deployment use the production checked installer.
#[path = "../src/bin/reshade/mod.rs"] mod reshade;
fn main() {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 { eprintln!("usage: reshade-install APP_ID GAME_ROOT STAGE"); std::process::exit(2); }
    let app_id = args[1].parse().expect("numeric AppID");
    if let Err(error) = reshade::install(app_id,std::path::Path::new(&args[3]),std::path::Path::new(&args[2])) {
        eprintln!("{error}"); std::process::exit(1);
    }
    println!("reshade-installed");
}
