// Embeds the app icon and version info into the Windows executable.
fn main() {
    println!("cargo:rerun-if-changed=assets/icon.ico");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        #[cfg(windows)]
        {
            let mut res = winresource::WindowsResource::new();
            res.set_icon("assets/icon.ico");
            res.set("ProductName", "SnapPaste");
            res.set("FileDescription", "SnapPaste — clipboard-first screenshots");
            res.set("LegalCopyright", "MIT License");
            if let Err(e) = res.compile() {
                println!("cargo:warning=couldn't embed the Windows icon: {e}");
            }
        }
    }
}
