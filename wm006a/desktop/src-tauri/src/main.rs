use std::path::Path;
use wm006a_native::wire::{request, UI_OK, UI_PING, UI_SOCKET};

#[tauri::command]
async fn local_ping() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(|| match request(Path::new(UI_SOCKET), UI_PING) {
        Ok(bytes) if bytes == UI_OK => Ok("Signer and gateway replied.".to_string()),
        Ok(_) => Err("The signer could not complete the IPC check.".to_string()),
        Err(error) => Err(format!("Local IPC unavailable: {error}")),
    })
    .await
    .map_err(|_| "Local IPC worker stopped.".to_string())?
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![local_ping])
        .run(tauri::generate_context!())
        .expect("start 006A desktop");
}
