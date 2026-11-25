fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(&["local_ping"])),
    )
    .expect("generate Tauri configuration and command permission");
}
