
// 41F-20C: Read-only Reloaded-II metadata parser.
//
// This module parses bounded ModConfig.json contents.
// It does not determine whether mods are enabled or loaded.

use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;
use std::io::Read;
use std::path::Path;

pub const MAX_CONFIG_BYTES: u64 = 256 * 1024;
const MAX_FIELD_BYTES: usize = 2048;
const MAX_SUPPORTED_IDS: usize = 128;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModMetadata {
    pub mod_id: String,
    pub mod_name: String,
    pub author: String,
    pub version: String,
    pub description: String,
    pub supported_app_ids: Vec<String>,
    pub is_universal: bool,
}

fn bounded(value: &str) -> String {
    let mut end = value.len().min(MAX_FIELD_BYTES);

    while !value.is_char_boundary(end) {
        end -= 1;
    }

    value[..end].to_owned()
}

fn optional_string(json: &Value, key: &str) -> Result<String, String> {
    match json.get(key) {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(value)) => Ok(bounded(value)),
        _ => Err(format!("invalid-{key}")),
    }
}

pub fn parse_config_bytes(bytes: &[u8]) -> Result<ModMetadata, String> {
    if bytes.len() as u64 > MAX_CONFIG_BYTES {
        return Err("config-too-large".into());
    }

    let json: Value =
        serde_json::from_slice(bytes).map_err(|_| "invalid-json".to_string())?;

    if !json.is_object() {
        return Err("invalid-json-root".into());
    }

    let mod_id = optional_string(&json, "ModId")?;

    if let Some(serde_json::Value::String(original)) = json.get("ModId") {
        if original.len() > MAX_FIELD_BYTES {
            return Err("mod-id-too-long".into());
        }
    }

    if mod_id.trim().is_empty() {
        return Err("missing-mod-id".into());
    }

    let mut mod_name = optional_string(&json, "ModName")?;

    if mod_name.is_empty() {
        mod_name = mod_id.clone();
    }

    let supported_app_ids = match json.get("SupportedAppId") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(values)) => {
            if values.len() > MAX_SUPPORTED_IDS {
                return Err("too-many-supported-ids".into());
            }

            let mut result = Vec::new();

            for value in values {
                let Some(id) = value.as_str() else {
                    return Err("invalid-supported-id".into());
                };

                if id.len() > MAX_FIELD_BYTES {
                    return Err("supported-id-too-long".into());
                }

                result.push(id.to_owned());
            }

            result
        }
        _ => return Err("invalid-supported-ids".into()),
    };

    let is_universal = match json.get("IsUniversalMod") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(value)) => *value,
        _ => return Err("invalid-universal-flag".into()),
    };

    Ok(ModMetadata {
        mod_id,
        mod_name,
        author: optional_string(&json, "ModAuthor")?,
        version: optional_string(&json, "ModVersion")?,
        description: optional_string(&json, "ModDescription")?,
        supported_app_ids,
        is_universal,
    })
}

pub fn read_config(path: &Path) -> Result<ModMetadata, String> {
    let metadata =
        fs::symlink_metadata(path).map_err(|_| "config-unavailable".to_string())?;

    if metadata.file_type().is_symlink() {
        return Err("config-symlink".into());
    }

    if !metadata.is_file() {
        return Err("config-not-file".into());
    }

    if metadata.len() > MAX_CONFIG_BYTES {
        return Err("config-too-large".into());
    }

    // O_NOFOLLOW prevents a symlink swap at the final path component.
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| "config-open-failed".to_string())?;

    let opened =
        file.metadata().map_err(|_| "config-stat-failed".to_string())?;

    if !opened.is_file() {
        return Err("config-not-file".into());
    }

    if opened.len() > MAX_CONFIG_BYTES {
        return Err("config-too-large".into());
    }

    let mut bytes = Vec::new();

    file.take(MAX_CONFIG_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "config-read-failed".to_string())?;

    parse_config_bytes(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_config() {
        let json = br#"{
            "ModId": "example.mod",
            "ModName": "Example",
            "ModVersion": "1.2.3",
            "SupportedAppId": ["1984270"],
            "IsUniversalMod": false
        }"#;

        let result = parse_config_bytes(json).unwrap();

        assert_eq!(result.mod_id, "example.mod");
        assert_eq!(result.mod_name, "Example");
        assert_eq!(result.version, "1.2.3");
        assert_eq!(result.supported_app_ids, vec!["1984270"]);
        assert!(!result.is_universal);
    }


    #[test]
    fn rejects_oversized_mod_id() {
        let id = "x".repeat(MAX_FIELD_BYTES + 1);
        let json = serde_json::json!({
            "ModId": id
        });

        let bytes = serde_json::to_vec(&json).unwrap();

        assert_eq!(
            parse_config_bytes(&bytes).unwrap_err(),
            "mod-id-too-long"
        );
    }

    #[test]
    fn rejects_oversized_supported_id() {
        let id = "x".repeat(MAX_FIELD_BYTES + 1);
        let json = serde_json::json!({
            "ModId": "example",
            "SupportedAppId": [id]
        });

        let bytes = serde_json::to_vec(&json).unwrap();

        assert_eq!(
            parse_config_bytes(&bytes).unwrap_err(),
            "supported-id-too-long"
        );
    }

    #[test]
    fn rejects_missing_id() {
        assert_eq!(
            parse_config_bytes(br#"{"ModName":"Example"}"#).unwrap_err(),
            "missing-mod-id"
        );
    }

    #[test]
    fn rejects_invalid_json() {
        assert_eq!(
            parse_config_bytes(b"{broken").unwrap_err(),
            "invalid-json"
        );
    }

    #[test]
    fn rejects_oversized_config() {
        let bytes = vec![b'x'; MAX_CONFIG_BYTES as usize + 1];

        assert_eq!(
            parse_config_bytes(&bytes).unwrap_err(),
            "config-too-large"
        );
    }

    #[test]
    fn rejects_invalid_supported_ids() {
        let json = br#"{
            "ModId": "example",
            "SupportedAppId": [123]
        }"#;

        assert_eq!(
            parse_config_bytes(json).unwrap_err(),
            "invalid-supported-id"
        );
    }
}
