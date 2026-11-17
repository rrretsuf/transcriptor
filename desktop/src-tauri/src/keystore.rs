use std::io::Write;
use std::path::{Path, PathBuf};

// The Soniox key lives in the OS credential store: Windows Credential Manager or
// the Linux Secret Service (GNOME Keyring, KWallet). A system without one keeps it
// in a file only its owner can read. It never goes into config.json.

pub const SONIOX: &str = "soniox";

fn fallback(dir: &Path, account: &str) -> PathBuf {
    dir.join(format!("{account}.key"))
}

#[cfg(not(target_os = "macos"))]
fn entry(account: &str) -> Option<keyring::Entry> {
    keyring::Entry::new("com.transcriptor.app", account).ok()
}

pub fn get(dir: &Path, account: &str) -> Option<String> {
    #[cfg(not(target_os = "macos"))]
    if let Some(Ok(key)) = entry(account).map(|e| e.get_password()) {
        if !key.is_empty() {
            return Some(key);
        }
    }
    let key = std::fs::read_to_string(fallback(dir, account)).ok()?;
    let key = key.trim();
    (!key.is_empty()).then(|| key.to_string())
}

/// An empty key removes it.
pub fn set(dir: &Path, account: &str, key: &str) -> Result<(), String> {
    let file = fallback(dir, account);
    #[cfg(not(target_os = "macos"))]
    if let Some(entry) = entry(account) {
        if key.is_empty() {
            let _ = entry.delete_credential();
        } else if entry.set_password(key).is_ok() {
            let _ = std::fs::remove_file(&file);
            return Ok(());
        }
    }
    let _ = std::fs::remove_file(&file);
    if key.is_empty() {
        return Ok(());
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options.open(&file).and_then(|mut f| f.write_all(key.as_bytes())).map_err(|e| e.to_string())
}
