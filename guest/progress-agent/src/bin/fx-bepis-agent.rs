mod asset_mod;
#[cfg(target_os = "linux")]
mod recovery_inventory;
mod reloadedii_metadata;
use std::collections::BTreeMap;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::os::fd::AsRawFd;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::thread;
use std::time::{Duration, Instant};

const PORT: &str = "/dev/virtio-ports/fx.bepis";
const MAX_LINE: usize = 16 * 1024;

#[derive(Debug, Clone)]
struct SteamGame {
    app_id: u32,
    name: String,
    install_path: PathBuf,
    library_path: PathBuf,
}

fn open_port() -> io::Result<std::fs::File> {
    OpenOptions::new().read(true).write(true).open(PORT)
}

fn send(file: &mut std::fs::File, line: &str) -> io::Result<()> {
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    file.flush()
}

fn encode_field(value: &str) -> String {
    let mut out = String::with_capacity(value.len());

    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'/' | b':' => {
                out.push(byte as char)
            }
            _ => {
                use std::fmt::Write as _;
                let _ = write!(&mut out, "%{byte:02X}");
            }
        }
    }

    out
}

fn steam_roots() -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    if let Some(home) = env::var_os("HOME") {
        let home = PathBuf::from(home);

        candidates.push(home.join(".local/share/Steam"));
        candidates.push(home.join(".steam/steam"));
        candidates.push(home.join(".steam/root"));
    }

    let mut roots = Vec::new();

    for candidate in candidates {
        if candidate.join("steamapps").is_dir() && !roots.contains(&candidate) {
            roots.push(candidate);
        }
    }

    roots
}

fn quoted_pairs(text: &str) -> Vec<(String, String)> {
    fn quoted_strings(line: &str) -> Vec<String> {
        let bytes = line.as_bytes();
        let mut strings = Vec::new();
        let mut index = 0;

        while index < bytes.len() {
            if bytes[index] != b'"' {
                index += 1;
                continue;
            }

            index += 1;
            let mut value = Vec::new();
            let mut closed = false;

            while index < bytes.len() {
                match bytes[index] {
                    b'\\' if index + 1 < bytes.len()
                        && matches!(bytes[index + 1], b'"' | b'\\') =>
                    {
                        index += 1;
                        value.push(bytes[index]);
                        index += 1;
                    }
                    b'"' => {
                        index += 1;
                        closed = true;
                        break;
                    }
                    byte => {
                        value.push(byte);
                        index += 1;
                    }
                }
            }

            if !closed {
                break;
            }

            if let Ok(value) = String::from_utf8(value) {
                strings.push(value);
            }
        }

        strings
    }

    text.lines()
        .filter_map(|line| {
            let strings = quoted_strings(line);
            if strings.len() == 2 {
                Some((strings[0].clone(), strings[1].clone()))
            } else {
                None
            }
        })
        .collect()
}

#[cfg(test)]
mod vdf_parser_tests {
    use super::{quoted_pairs, vdf_value};

    #[test]
    fn parses_digimon_manifest() {
        let manifest = r#"
"AppState"
{
    "appid"       "1984270"
    "name"        "Digimon Story Time Stranger"
    "StateFlags"  "4"
    "installdir"  "Digimon Story Time Stranger"
}
"#;

        assert_eq!(
            vdf_value(manifest, "appid").as_deref(),
            Some("1984270")
        );
        assert_eq!(
            vdf_value(manifest, "name").as_deref(),
            Some("Digimon Story Time Stranger")
        );
        assert_eq!(
            vdf_value(manifest, "installdir").as_deref(),
            Some("Digimon Story Time Stranger")
        );
    }

    #[test]
    fn parses_steam_libraryfolders() {
        let config = r#"
"libraryfolders"
{
    "0"
    {
        "path" "/home/steamos/.local/share/Steam"
        "apps"
        {
            "1984270" "32434790206"
        }
    }
}
"#;

        let paths: Vec<_> = quoted_pairs(config)
            .into_iter()
            .filter(|(key, _)| key == "path")
            .map(|(_, value)| value)
            .collect();

        assert_eq!(
            paths,
            vec!["/home/steamos/.local/share/Steam"]
        );
    }

    #[test]
    fn preserves_unicode_and_escaped_quotes() {
        let manifest = r#"
"AppState"
{
    "name" "Pokémon \"Test\""
}
"#;

        assert_eq!(
            vdf_value(manifest, "name").as_deref(),
            Some("Pokémon \"Test\"")
        );
    }

    #[test]
    fn preserves_windows_style_backslashes() {
        let config = r#"
"libraryfolders"
{
    "0"
    {
        "path" "C:\SteamLibrary"
    }
}
"#;

        assert_eq!(
            vdf_value(config, "path").as_deref(),
            Some(r"C:\SteamLibrary")
        );
    }
}

fn vdf_value(text: &str, wanted: &str) -> Option<String> {
    quoted_pairs(text)
        .into_iter()
        .find_map(|(key, value)| key.eq_ignore_ascii_case(wanted).then_some(value))
}

fn discover_libraries() -> Vec<PathBuf> {
    let roots = steam_roots();
    let mut libraries = roots.clone();

    for root in roots {
        let config = root.join("steamapps/libraryfolders.vdf");
        let Ok(text) = fs::read_to_string(config) else {
            continue;
        };

        for (key, value) in quoted_pairs(&text) {
            if key.eq_ignore_ascii_case("path") {
                let path = PathBuf::from(value);

                if path.join("steamapps").is_dir() && !libraries.contains(&path) {
                    libraries.push(path);
                }
            }
        }
    }

    libraries
}

fn game_from_manifest(library: &Path, manifest: &Path) -> Option<SteamGame> {
    let text = fs::read_to_string(manifest).ok()?;

    let app_id = vdf_value(&text, "appid")?.parse::<u32>().ok()?;
    let name = vdf_value(&text, "name")?;
    let install_dir = vdf_value(&text, "installdir")?;

    if install_dir.is_empty() {
        return None;
    }

    let install_path = library.join("steamapps/common").join(install_dir);

    if !install_path.is_dir() {
        return None;
    }

    Some(SteamGame {
        app_id,
        name,
        install_path,
        library_path: library.to_path_buf(),
    })
}

fn discover_games() -> Vec<SteamGame> {
    let mut games = BTreeMap::<u32, SteamGame>::new();

    for library in discover_libraries() {
        let steamapps = library.join("steamapps");

        let Ok(entries) = fs::read_dir(&steamapps) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();

            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                continue;
            };

            if !name.starts_with("appmanifest_") || !name.ends_with(".acf") {
                continue;
            }

            if let Some(game) = game_from_manifest(&library, &path) {
                games.entry(game.app_id).or_insert(game);
            }
        }
    }

    games.into_values().collect()
}

const BEPIS_OVERRIDE: &str = r#"WINEDLLOVERRIDES=\"winhttp=n,b\""#;

#[derive(Debug, Clone)]
struct VdfToken {
    value: String,
    start: usize,
    end: usize,
    quoted: bool,
}

#[derive(Debug, Clone)]
struct VdfSection {
    name: String,
    body_start: usize,
    body_end: usize,
}

fn vdf_tokens(text: &str) -> Result<Vec<VdfToken>, String> {
    let bytes = text.as_bytes();
    let mut tokens = Vec::new();
    let mut i = 0usize;

    while i < bytes.len() {
        match bytes[i] {
            b' ' | b'\t' | b'\r' | b'\n' => {
                i += 1;
            }

            b'/' if i + 1 < bytes.len() && bytes[i + 1] == b'/' => {
                i += 2;
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
            }

            b'{' | b'}' => {
                tokens.push(VdfToken {
                    value: (bytes[i] as char).to_string(),
                    start: i,
                    end: i + 1,
                    quoted: false,
                });
                i += 1;
            }

            b'"' => {
                let start = i;
                i += 1;
                let mut value = String::new();

                while i < bytes.len() {
                    match bytes[i] {
                        b'"' => {
                            i += 1;
                            break;
                        }

                        b'\\' if i + 1 < bytes.len() => {
                            i += 1;
                            value.push(bytes[i] as char);
                            i += 1;
                        }

                        byte => {
                            value.push(byte as char);
                            i += 1;
                        }
                    }
                }

                if i > bytes.len() || bytes.get(i.saturating_sub(1)) != Some(&b'"') {
                    return Err("unterminated quoted VDF token".to_string());
                }

                tokens.push(VdfToken {
                    value,
                    start,
                    end: i,
                    quoted: true,
                });
            }

            _ => {
                let start = i;

                while i < bytes.len()
                    && !matches!(bytes[i], b' ' | b'\t' | b'\r' | b'\n' | b'{' | b'}')
                {
                    i += 1;
                }

                tokens.push(VdfToken {
                    value: text[start..i].to_string(),
                    start,
                    end: i,
                    quoted: false,
                });
            }
        }
    }

    Ok(tokens)
}

fn find_vdf_section(text: &str, path: &[&str]) -> Result<Option<VdfSection>, String> {
    let tokens = vdf_tokens(text)?;

    fn descend(
        tokens: &[VdfToken],
        wanted: &[&str],
        begin: usize,
        end: usize,
    ) -> Option<(usize, usize)> {
        if wanted.is_empty() {
            return Some((begin, end));
        }

        let mut i = begin;

        while i + 1 < end {
            if tokens[i].value == "}" {
                break;
            }

            let name = &tokens[i].value;

            if tokens[i + 1].value == "{" {
                let body_begin = i + 2;
                let mut depth = 1usize;
                let mut j = body_begin;

                while j < end {
                    match tokens[j].value.as_str() {
                        "{" => depth += 1,
                        "}" => {
                            depth -= 1;

                            if depth == 0 {
                                if name.eq_ignore_ascii_case(wanted[0]) {
                                    if wanted.len() == 1 {
                                        return Some((body_begin, j));
                                    }

                                    if let Some(found) =
                                        descend(tokens, &wanted[1..], body_begin, j)
                                    {
                                        return Some(found);
                                    }
                                }

                                i = j + 1;
                                break;
                            }
                        }
                        _ => {}
                    }

                    j += 1;
                }

                if j >= end {
                    return None;
                }

                continue;
            }

            i += 2;
        }

        None
    }

    let Some((begin, end)) = descend(&tokens, path, 0, tokens.len()) else {
        return Ok(None);
    };

    let body_start = if begin < tokens.len() {
        tokens[begin].start
    } else {
        text.len()
    };

    let body_end = if end < tokens.len() {
        tokens[end].start
    } else {
        text.len()
    };

    Ok(Some(VdfSection {
        name: path.last().unwrap_or(&"").to_string(),
        body_start,
        body_end,
    }))
}

fn vdf_escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn vdf_unescape(value: &str) -> String {
    let mut result = String::new();
    let mut chars = value.chars();

    while let Some(ch) = chars.next() {
        if ch == '\\' {
            if let Some(next) = chars.next() {
                result.push(next);
            }
        } else {
            result.push(ch);
        }
    }

    result
}

fn find_launch_options(
    text: &str,
    section: &VdfSection,
) -> Result<Option<(usize, usize, String)>, String> {
    let slice = &text[section.body_start..section.body_end];

    let tokens = vdf_tokens(slice)?;

    let mut depth = 0usize;
    let mut i = 0usize;

    while i + 1 < tokens.len() {
        match tokens[i].value.as_str() {
            "{" => {
                depth += 1;
                i += 1;
                continue;
            }

            "}" => {
                depth = depth.saturating_sub(1);
                i += 1;
                continue;
            }

            _ => {}
        }

        if depth == 0
            && tokens[i].value.eq_ignore_ascii_case("LaunchOptions")
            && tokens[i + 1].quoted
        {
            let value_token = &tokens[i + 1];

            let raw = &slice[value_token.start + 1..value_token.end - 1];

            return Ok(Some((
                section.body_start + value_token.start + 1,
                section.body_start + value_token.end - 1,
                vdf_unescape(raw),
            )));
        }

        i += 1;
    }

    Ok(None)
}

fn line_indent_before(text: &str, position: usize) -> String {
    let line_start = text[..position]
        .rfind('\n')
        .map(|index| index + 1)
        .unwrap_or(0);

    text[line_start..position]
        .chars()
        .take_while(|ch| *ch == ' ' || *ch == '\t')
        .collect()
}

fn set_launch_options(
    text: &str,
    app_id: u32,
    value: Option<&str>,
) -> Result<(String, Option<String>), String> {
    let app_id_string = app_id.to_string();

    let section = find_vdf_section(
        text,
        &["Software", "Valve", "Steam", "apps", &app_id_string],
    )?
    .ok_or_else(|| format!("Steam localconfig has no apps/{app_id} section"))?;

    let existing = find_launch_options(text, &section)?;

    let original = existing.as_ref().map(|(_, _, value)| value.clone());

    match (existing, value) {
        (Some((start, end, _)), Some(new_value)) => {
            let mut output = String::with_capacity(text.len() + new_value.len());

            output.push_str(&text[..start]);

            output.push_str(&vdf_escape(new_value));

            output.push_str(&text[end..]);

            Ok((output, original))
        }

        (Some((start, end, _)), None) => {
            let key_start = text[..start]
                .rfind("\"LaunchOptions\"")
                .ok_or_else(|| "could not locate LaunchOptions key".to_string())?;

            let line_start = text[..key_start]
                .rfind('\n')
                .map(|index| index + 1)
                .unwrap_or(0);

            let line_end = text[end..]
                .find('\n')
                .map(|offset| end + offset + 1)
                .unwrap_or(text.len());

            let mut output = String::with_capacity(text.len());

            output.push_str(&text[..line_start]);

            output.push_str(&text[line_end..]);

            Ok((output, original))
        }

        (None, Some(new_value)) => {
            let indent = line_indent_before(text, section.body_end);

            let child_indent = format!("{indent}\t");

            let insertion = format!(
                "{child_indent}\"LaunchOptions\"\t\t\"{}\"\n",
                vdf_escape(new_value)
            );

            let mut output = String::with_capacity(text.len() + insertion.len());

            output.push_str(&text[..section.body_end]);

            output.push_str(&insertion);

            output.push_str(&text[section.body_end..]);

            Ok((output, original))
        }

        (None, None) => Ok((text.to_string(), None)),
    }
}

fn atomic_write(path: &Path, contents: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "target file has no parent directory".to_string())?;

    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "target file name is not valid UTF-8".to_string())?;

    let temporary = parent.join(format!(".{file_name}.bepis-{}.tmp", std::process::id(),));

    fs::write(&temporary, contents.as_bytes())
        .map_err(|error| format!("could not write temporary Steam config: {error}"))?;

    fs::rename(&temporary, path).map_err(|error| {
        let _ = fs::remove_file(&temporary);

        format!("could not replace Steam config atomically: {error}")
    })?;

    Ok(())
}

fn bepis_state_root() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/home/deck"));

            home.join(".local/state")
        })
        .join("steamac")
        .join("bepis")
}

fn state_file_for(account: &str, app_id: u32) -> PathBuf {
    bepis_state_root()
        .join(account)
        .join(format!("{app_id}.launch-options"))
}

fn encode_state(value: Option<&str>) -> String {
    match value {
        Some(value) => {
            let bytes = value.as_bytes();

            let mut output = String::from("value ");

            for byte in bytes {
                use std::fmt::Write as _;
                write!(&mut output, "{byte:02x}").expect("writing to String cannot fail");
            }

            output.push('\n');
            output
        }

        None => "missing\n".to_string(),
    }
}

fn decode_state(text: &str) -> Result<Option<String>, String> {
    let text = text.trim_end();

    if text == "missing" {
        return Ok(None);
    }

    let hex = text
        .strip_prefix("value ")
        .ok_or_else(|| "invalid Bepis launch-options state".to_string())?;

    if hex.len() % 2 != 0 {
        return Err("invalid Bepis launch-options state length".to_string());
    }

    let mut bytes = Vec::with_capacity(hex.len() / 2);

    let raw = hex.as_bytes();

    let mut i = 0usize;

    while i < raw.len() {
        let pair = std::str::from_utf8(&raw[i..i + 2])
            .map_err(|_| "invalid Bepis launch-options state encoding".to_string())?;

        let byte = u8::from_str_radix(pair, 16)
            .map_err(|_| "invalid Bepis launch-options state encoding".to_string())?;

        bytes.push(byte);
        i += 2;
    }

    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| "Bepis launch-options state is not UTF-8".to_string())
}

fn localconfig_files() -> Result<Vec<(String, PathBuf)>, String> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set".to_string())?;

    let userdata = home.join(".local/share/Steam/userdata");

    let entries = match fs::read_dir(&userdata) {
        Ok(entries) => entries,

        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(Vec::new());
        }

        Err(error) => {
            return Err(format!("could not enumerate Steam userdata: {error}"));
        }
    };

    let mut configs = Vec::new();

    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };

        if !file_type.is_dir() {
            continue;
        }

        let account = entry.file_name().to_string_lossy().to_string();

        if account.is_empty() || !account.bytes().all(|byte| byte.is_ascii_digit()) {
            continue;
        }

        let config = entry.path().join("config").join("localconfig.vdf");

        if config.is_file() {
            configs.push((account, config));
        }
    }

    configs.sort_by(|a, b| a.0.cmp(&b.0));

    Ok(configs)
}

fn launch_options_with_bepis(original: Option<&str>) -> String {
    let original = original.unwrap_or("").trim();

    if original.contains("WINEDLLOVERRIDES") {
        // Never overwrite an existing user-specified Wine override.
        // The caller treats this as already configured rather than
        // destructively replacing it.
        return original.to_string();
    }

    if original.is_empty() {
        format!("{BEPIS_OVERRIDE} %command%")
    } else if original.contains("%command%") {
        format!("{BEPIS_OVERRIDE} {original}")
    } else {
        format!("{BEPIS_OVERRIDE} {original} %command%")
    }
}

fn known_steam_app(app_id: u32) -> bool {
    discover_games().iter().any(|game| game.app_id == app_id)
}

fn activate_bepinex(app_id: u32) -> Result<usize, String> {
    if !known_steam_app(app_id) {
        return Err(format!("unknown Steam app ID {app_id}"));
    }

    let configs = localconfig_files()?;

    let mut changed = 0usize;

    for (account, config) in configs {
        let text = fs::read_to_string(&config)
            .map_err(|error| format!("could not read {}: {error}", config.display()))?;

        let app_id_string = app_id.to_string();

        let Some(section) = find_vdf_section(
            &text,
            &["Software", "Valve", "Steam", "apps", &app_id_string],
        )?
        else {
            continue;
        };

        let existing = find_launch_options(&text, &section)?;

        let original = existing.as_ref().map(|(_, _, value)| value.clone());

        if original
            .as_deref()
            .is_some_and(|value| value.contains("WINEDLLOVERRIDES"))
        {
            // User already owns a WINEDLLOVERRIDES policy.
            // Do not mutate or claim ownership of it.
            continue;
        }

        let state = state_file_for(&account, app_id);

        if state.exists() {
            // Already activated by BepisLoader.
            continue;
        }

        let new_options = launch_options_with_bepis(original.as_deref());

        let (updated, _) = set_launch_options(&text, app_id, Some(&new_options))?;

        let state_parent = state
            .parent()
            .ok_or_else(|| "Bepis state path has no parent".to_string())?;

        fs::create_dir_all(state_parent)
            .map_err(|error| format!("could not create Bepis state directory: {error}"))?;

        // Write ownership state FIRST. If the VDF write then fails,
        // remove the state immediately.
        fs::write(&state, encode_state(original.as_deref()))
            .map_err(|error| format!("could not save original Steam launch options: {error}"))?;

        if let Err(error) = atomic_write(&config, &updated) {
            let _ = fs::remove_file(&state);

            return Err(error);
        }

        changed += 1;
    }

    Ok(changed)
}

fn deactivate_bepinex(app_id: u32) -> Result<usize, String> {
    if !known_steam_app(app_id) {
        return Err(format!("unknown Steam app ID {app_id}"));
    }

    let configs = localconfig_files()?;

    let mut changed = 0usize;

    for (account, config) in configs {
        let state = state_file_for(&account, app_id);

        if !state.is_file() {
            continue;
        }

        let original = decode_state(
            &fs::read_to_string(&state)
                .map_err(|error| format!("could not read Bepis launch-options state: {error}"))?,
        )?;

        let text = fs::read_to_string(&config)
            .map_err(|error| format!("could not read {}: {error}", config.display()))?;

        let current_section = find_vdf_section(
            &text,
            &["Software", "Valve", "Steam", "apps", &app_id.to_string()],
        )?
        .ok_or_else(|| format!("Steam localconfig no longer contains app {app_id}"))?;

        let current = find_launch_options(&text, &current_section)?.map(|(_, _, value)| value);

        // Refuse to overwrite a value that no longer looks owned by
        // BepisLoader. The user may have edited it after activation.
        if !current
            .as_deref()
            .is_some_and(|value| value.starts_with(BEPIS_OVERRIDE))
        {
            return Err(
                format!(
                    "Steam launch options for app {app_id} changed after BepisLoader activation; refusing to overwrite them"
                )
            );
        }

        let (updated, _) = set_launch_options(&text, app_id, original.as_deref())?;

        atomic_write(&config, &updated)?;

        fs::remove_file(&state).map_err(|error| {
            format!("Steam config was restored but Bepis state cleanup failed: {error}")
        })?;

        changed += 1;
    }

    Ok(changed)
}

// 41F-21B.8: Pure, read-only BepInEx marker classifier. Game lookup and
// Steam-library containment checks remain in bepinex_inventory below.
// Never follow marker symlinks; unknown/partial must fail closed.
fn classify_bepinex_markers(root: &std::path::Path) -> (&'static str, &'static str) {
    let markers = [
        ("winhttp.dll", false),
        ("doorstop_config.ini", false),
        ("BepInEx", true),
        ("BepInEx/BepInEx.version", false),
    ];
    let mut present = 0usize;
    for (relative, directory) in markers {
        let path = root.join(relative);
        // A nested marker must not traverse a symlinked parent directory.
        if relative.contains('/') {
            let parent = root.join("BepInEx");
            match fs::symlink_metadata(&parent) {
                Ok(metadata) if metadata.file_type().is_symlink() => {
                    return ("unknown", "symlink-marker");
                }
                Ok(metadata) if !metadata.is_dir() => {
                    return ("partial", "unexpected-marker-type");
                }
                Ok(_) => (),
                Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                Err(_) => return ("unknown", "inaccessible-marker"),
            }
        }
        match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return ("unknown", "symlink-marker");
                }
                if (directory && !metadata.is_dir()) || (!directory && !metadata.is_file()) {
                    return ("partial", "unexpected-marker-type");
                }
                present += 1;
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(_) => return ("unknown", "inaccessible-marker"),
        }
    }
    if present == 0 { ("absent", "no-markers") }
    else if present == markers.len() { ("installed", "four-markers-present-not-runtime-verified") }
    else { ("partial", "incomplete-markers") }
}

// 41F-21B.6: AppID-scoped, read-only BepInEx inventory.
fn bepinex_inventory(app_id: u32) -> Result<(&'static str, &'static str), String> {
    let games = discover_games();
    let game = games.iter().find(|game| game.app_id == app_id)
        .ok_or_else(|| format!("unknown Steam AppID: {app_id}"))?;
    let root = game.install_path.canonicalize()
        .map_err(|error| format!("could not resolve game directory: {error}"))?;
    let common = game.library_path.join("steamapps/common").canonicalize()
        .map_err(|error| format!("could not resolve Steam common directory: {error}"))?;
    if !root.starts_with(&common) || root == common {
        return Err("game directory escapes Steam common directory".into());
    }
    Ok(classify_bepinex_markers(&root))
}

#[cfg(test)]
mod bepinex_inventory_fixture_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);

    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            let id = NEXT.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "fx-bepis-21b8-{}-{}", std::process::id(), id
            ));
            fs::create_dir(&root).expect("create isolated test fixture");
            Self(root)
        }
        fn marker(&self, path: &str) {
            let target = self.0.join(path);
            fs::create_dir_all(target.parent().unwrap()).unwrap();
            fs::write(target, b"fixture").unwrap();
        }
        fn complete(&self) {
            self.marker("winhttp.dll");
            self.marker("doorstop_config.ini");
            fs::create_dir(self.0.join("BepInEx")).unwrap();
            self.marker("BepInEx/BepInEx.version");
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
    }

    #[test]
    fn no_markers_is_absent() {
        let f = Fixture::new();
        assert_eq!(classify_bepinex_markers(&f.0), ("absent", "no-markers"));
    }
    #[test]
    fn complete_markers_are_installed_not_runtime_verified() {
        let f = Fixture::new(); f.complete();
        assert_eq!(classify_bepinex_markers(&f.0),
            ("installed", "four-markers-present-not-runtime-verified"));
    }
    #[test]
    fn missing_marker_is_partial() {
        let f = Fixture::new(); f.complete();
        fs::remove_file(f.0.join("doorstop_config.ini")).unwrap();
        assert_eq!(classify_bepinex_markers(&f.0), ("partial", "incomplete-markers"));
    }
    #[test]
    fn incorrect_marker_type_is_partial() {
        let f = Fixture::new();
        fs::create_dir(f.0.join("winhttp.dll")).unwrap();
        assert_eq!(classify_bepinex_markers(&f.0), ("partial", "unexpected-marker-type"));
    }
    #[cfg(unix)]
    #[test]
    fn symlinked_marker_is_unknown() {
        let f = Fixture::new();
        std::os::unix::fs::symlink("/tmp/does-not-exist", f.0.join("winhttp.dll")).unwrap();
        assert_eq!(classify_bepinex_markers(&f.0), ("unknown", "symlink-marker"));
    }
    #[cfg(unix)]
    #[test]
    fn symlinked_directory_is_unknown() {
        let f = Fixture::new();
        std::os::unix::fs::symlink("/tmp", f.0.join("BepInEx")).unwrap();
        assert_eq!(classify_bepinex_markers(&f.0), ("unknown", "symlink-marker"));
    }
}

fn reloadedii_installation_root(app_id: u32) -> Result<Option<PathBuf>, String> {
    // Require this to be a known Steam game. This keeps the
    // operation AppID-scoped rather than exposing arbitrary
    // guest filesystem discovery.
    if !discover_games().iter().any(|game| game.app_id == app_id) {
        return Err(format!("unknown Steam AppID: {app_id}"));
    }

    // proton_prefix() already returns:
    //   .../steamapps/compatdata/<appid>/pfx
    let prefix = proton_prefix(app_id)
        .ok_or_else(|| format!("Proton prefix not found for AppID {app_id}"))?;

    let canonical_prefix = prefix.canonicalize().map_err(|error| {
        format!(
            "failed to canonicalize Proton prefix {}: {error}",
            prefix.display()
        )
    })?;

    let users_root = prefix.join("drive_c").join("users");

    let entries = match fs::read_dir(&users_root) {
        Ok(entries) => entries,

        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(None);
        }

        Err(error) => {
            return Err(format!("failed to read {}: {error}", users_root.display()));
        }
    };

    for entry in entries {
        let entry = entry
            .map_err(|error| format!("failed to inspect {}: {error}", users_root.display()))?;

        let file_type = entry
            .file_type()
            .map_err(|error| format!("failed to inspect {}: {error}", entry.path().display()))?;

        // Do not follow a user-directory symlink.
        if !file_type.is_dir() || file_type.is_symlink() {
            continue;
        }

        let candidate = entry.path().join("Desktop").join("Reloaded-II");

        let executable = candidate.join("Reloaded-II.exe");

        let executable_metadata = match fs::symlink_metadata(&executable) {
            Ok(metadata) => metadata,

            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                continue;
            }

            Err(error) => {
                return Err(format!(
                    "failed to inspect {}: {error}",
                    executable.display()
                ));
            }
        };

        // Reloaded-II.exe itself must be a regular file and
        // must not be a symlink.
        if executable_metadata.file_type().is_symlink() || !executable_metadata.is_file() {
            continue;
        }

        let canonical_candidate = candidate
            .canonicalize()
            .map_err(|error| format!("failed to canonicalize {}: {error}", candidate.display()))?;

        // The discovered installation must remain inside this
        // AppID's Proton prefix after symlink resolution.
        if !canonical_candidate.starts_with(&canonical_prefix) {
            return Err(format!(
                "Reloaded-II path escaped Proton prefix: {}",
                candidate.display()
            ));
        }

        return Ok(Some(canonical_candidate));
    }

    Ok(None)
}

fn steam_compatibility_tool_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();

    for library in discover_libraries() {
        let steamapps = library.join("steamapps");

        // Valve-managed Proton installations normally live here.
        let common = steamapps.join("common");

        if let Ok(canonical) = fs::canonicalize(&common) {
            if canonical.is_dir() && !roots.contains(&canonical) {
                roots.push(canonical);
            }
        }

        // User-installed compatibility tools such as GE-Proton
        // conventionally live beside the Steam root rather than
        // inside steamapps/common.
        let compatibility_tools = library.join("compatibilitytools.d");

        if let Ok(canonical) = fs::canonicalize(&compatibility_tools) {
            if canonical.is_dir() && !roots.contains(&canonical) {
                roots.push(canonical);
            }
        }
    }

    // compatibilitytools.d commonly belongs to the primary Steam
    // root even when games live in secondary libraries.
    for root in steam_roots() {
        let compatibility_tools = root.join("compatibilitytools.d");

        if let Ok(canonical) = fs::canonicalize(&compatibility_tools) {
            if canonical.is_dir() && !roots.contains(&canonical) {
                roots.push(canonical);
            }
        }
    }

    roots
}

fn proton_launcher_from_candidate(candidate: &Path, allowed_roots: &[PathBuf]) -> Option<PathBuf> {
    let metadata = fs::symlink_metadata(candidate).ok()?;

    // Never accept the launcher itself as a symlink.
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }

    // 41F-21C.6: the launcher must be executable, not merely a regular file.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o111 == 0 { return None; }
    }

    let canonical = fs::canonicalize(candidate).ok()?;

    // Reject symlinked ancestors between the allowed tool root and launcher.
    // A canonicalized leaf alone cannot establish that the lexical route is safe.
    let lexical_parent = candidate.parent()?;
    let lexical_root = allowed_roots.iter().find(|root| {
        lexical_parent.starts_with(root) && lexical_parent != root.as_path()
    })?;
    let mut cursor = lexical_root.clone();
    for part in lexical_parent.strip_prefix(lexical_root).ok()?.components() {
        cursor.push(part.as_os_str());
        if fs::symlink_metadata(&cursor).ok()?.file_type().is_symlink() {
            return None;
        }
    }

    if !allowed_roots
        .iter()
        .any(|root| path_is_within(&canonical, root))
    {
        return None;
    }

    if canonical.file_name().and_then(|name| name.to_str()) != Some("proton") {
        return None;
    }

    Some(canonical)
}

fn proton_metadata_tokens(text: &str) -> Vec<String> {
    // config_info is line-oriented. A path may contain spaces, including
    // "Proton 11.0 (ARM64)"; never tokenize an absolute path by whitespace.
    let mut tokens = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('/') {
            let path = line.trim_matches(|ch: char| matches!(ch, '"' | '\'' | '[' | ']' | ',' | ';'));
            if !path.is_empty() { tokens.push(path.to_string()); }
        } else {
            for raw in line.split_whitespace() {
                let token = raw.trim_matches(|ch: char| matches!(ch, '"' | '\'' | '[' | ']' | '(' | ')' | ',' | ';'));
                if !token.is_empty() { tokens.push(token.to_string()); }
            }
        }
    }
    tokens
}

// Resolve *all* eligible launchers from config_info, never a first-match
// guess. Walk metadata path ancestors because config_info often references
// files/share/fonts rather than the Proton tool root itself.
fn proton_launchers_from_metadata(metadata: &str, allowed_roots: &[PathBuf])
    -> std::collections::BTreeSet<PathBuf>
{
    let mut matches = std::collections::BTreeSet::new();
    for token in proton_metadata_tokens(metadata) {
        if !token.starts_with('/') { continue; }
        let path = PathBuf::from(token);
        if path.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
            continue;
        }
        // A file path, directory path, or launcher path can all identify
        // a tool root. Restrict search depth and validate each candidate.
        for ancestor in path.ancestors().take(16) {
            let candidate = ancestor.join("proton");
            if let Some(launcher) = proton_launcher_from_candidate(&candidate, allowed_roots) {
                matches.insert(launcher);
            }
        }
    }
    matches
}

fn proton_runtime_for_app(app_id: u32) -> Result<Option<PathBuf>, String> {
    let game = discover_games()
        .into_iter()
        .find(|game| game.app_id == app_id)
        .ok_or_else(|| format!("unknown Steam AppID: {app_id}"))?;

    let compatdata = game
        .library_path
        .join("steamapps")
        .join("compatdata")
        .join(app_id.to_string());

    let prefix = compatdata.join("pfx");

    if !prefix.is_dir() {
        return Ok(None);
    }

    let canonical_compatdata = fs::canonicalize(&compatdata).map_err(|error| {
        format!(
            "failed to canonicalize compatdata for \
                     AppID {app_id}: {error}"
        )
    })?;

    let expected_compatdata = game.library_path.join("steamapps").join("compatdata");

    let canonical_expected = fs::canonicalize(&expected_compatdata).map_err(|error| {
        format!(
            "failed to canonicalize Steam compatdata \
                     root: {error}"
        )
    })?;

    if !path_is_within(&canonical_compatdata, &canonical_expected) {
        return Err("AppID compatdata escaped its Steam library".to_string());
    }

    let allowed_roots = steam_compatibility_tool_roots();

    if allowed_roots.is_empty() {
        return Ok(None);
    }

    let config_info = compatdata.join("config_info");

    let metadata = match fs::read_to_string(&config_info) {
        Ok(text) => text,

        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(None);
        }

        Err(error) => {
            return Err(format!(
                "failed to read Proton config_info for \
                     AppID {app_id}: {error}"
            ));
        }
    };

    let matches = proton_launchers_from_metadata(&metadata, &allowed_roots);
    if matches.len() > 1 {
        return Err("Proton runtime ambiguous: multiple metadata launchers".to_string());
    }
    if let Some(launcher) = matches.into_iter().next() {
        return Ok(Some(launcher));
    }

    // `version` is intentionally not interpreted as a path.
    // Its presence is useful evidence that this is a Proton
    // prefix, but it does not authoritatively identify the tool.
    let version = compatdata.join("version");

    if version.is_file() {
        return Ok(None);
    }

    Ok(None)
}

// 41F-21C.2: AppID-scoped static Proton runtime attestation.
// Structural evidence only: no execution, game launch, or injection proof.
// A single matching launcher is required; ambiguous or inaccessible data fails closed.
fn proton_attestation_for_app(app_id: u32) -> (&'static str, &'static str) {
    let games: Vec<_> = discover_games().into_iter()
        .filter(|game| game.app_id == app_id).collect();
    if games.len() != 1 { return ("unknown", "game-not-uniquely-resolved"); }
    let game = &games[0];
    let compat_root = game.library_path.join("steamapps/compatdata");
    let compatdata = compat_root.join(app_id.to_string());
    let prefix = compatdata.join("pfx");
    let canonical_root = match compat_root.canonicalize() {
        Ok(root) => root,
        Err(_) => return ("unknown", "compatdata-root-inaccessible"),
    };
    let canonical_app = match compatdata.canonicalize() {
        Ok(path) if path_is_within(&path, &canonical_root) && path != canonical_root => path,
        Ok(_) => return ("unknown", "compatdata-escape"),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return ("missing", "compatdata-missing"),
        Err(_) => return ("unknown", "compatdata-inaccessible"),
    };
    match fs::symlink_metadata(&prefix) {
        Ok(m) if m.file_type().is_symlink() || !m.is_dir() => return ("unknown", "prefix-unsafe"),
        Ok(_) => (),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return ("missing", "prefix-missing"),
        Err(_) => return ("unknown", "prefix-inaccessible"),
    }
    let config = canonical_app.join("config_info");
    let metadata = match fs::symlink_metadata(&config) {
        Ok(m) if m.file_type().is_symlink() || !m.is_file() => return ("unknown", "config-info-unsafe"),
        Ok(_) => match fs::read_to_string(&config) {
            Ok(text) if text.len() <= 64 * 1024 => text,
            _ => return ("unknown", "config-info-unreadable"),
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => return ("missing", "config-info-missing"),
        Err(_) => return ("unknown", "config-info-inaccessible"),
    };
    let allowed = steam_compatibility_tool_roots();
    if allowed.is_empty() { return ("unknown", "compatibility-roots-unavailable"); }
    let matches = proton_launchers_from_metadata(&metadata, &allowed);
    if matches.is_empty() { return ("unknown", "runtime-not-resolved"); }
    if matches.len() != 1 { return ("unknown", "runtime-ambiguous"); }
    let launcher = matches.into_iter().next().expect("one launcher");
    let Some(root) = launcher.parent() else { return ("unknown", "runtime-root-missing"); };
    classify_proton_runtime_root(root)
}

// 41F-21C.6: hardened static runtime checks, not execution attestation.
// Never follow symlinked runtime components; require executable launchers.
fn classify_proton_runtime_root(root: &Path) -> (&'static str, &'static str) {
    for name in ["proton", "toolmanifest.vdf"] {
        let path = root.join(name);
        match fs::symlink_metadata(&path) {
            Ok(meta) if meta.file_type().is_symlink() => return ("unknown", "runtime-symlink"),
            Ok(meta) if !meta.is_file() => return ("incomplete", "runtime-marker-invalid"),
            Ok(meta) => {
                #[cfg(unix)]
                if name == "proton" {
                    use std::os::unix::fs::PermissionsExt;
                    if meta.permissions().mode() & 0o111 == 0 {
                        return ("incomplete", "runtime-launcher-not-executable");
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound =>
                return ("incomplete", "runtime-marker-missing"),
            Err(_) => return ("unknown", "runtime-marker-inaccessible"),
        }
    }
    let mut complete = false;
    for layout in ["files", "dist"] {
        let dir = root.join(layout);
        match fs::symlink_metadata(&dir) {
            Ok(meta) if meta.file_type().is_symlink() => return ("unknown", "runtime-symlink"),
            Ok(meta) if meta.is_dir() => (),
            Ok(_) => return ("incomplete", "runtime-layout-invalid"),
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(_) => return ("unknown", "runtime-layout-inaccessible"),
        }
        for bin_name in if layout == "files" {
            &["bin", "bin-arm64"][..]
        } else {
            &["bin"][..]
        } {
            let bin = dir.join(bin_name);
            match fs::symlink_metadata(&bin) {
                Ok(meta) if meta.file_type().is_symlink() => return ("unknown", "runtime-symlink"),
                Ok(meta) if meta.is_dir() => (),
                Ok(_) => return ("incomplete", "runtime-layout-invalid"),
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(_) => return ("unknown", "runtime-component-inaccessible"),
            }
            let wine = bin.join("wine");
            match fs::symlink_metadata(&wine) {
                Ok(meta) if meta.file_type().is_symlink() => return ("unknown", "runtime-symlink"),
                Ok(meta) if meta.is_file() => complete = true,
                Ok(_) => return ("incomplete", "runtime-component-invalid"),
                Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                Err(_) => return ("unknown", "runtime-component-inaccessible"),
            }
        }
    }
    if complete { ("verified", "static-layout-only-not-launch-verified") }
    else { ("incomplete", "runtime-components-missing") }
}

#[cfg(test)]
mod proton_attestation_fixture_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = env::temp_dir().join(format!("fx-bepis-21c2-{}-{}",
                std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
            fs::create_dir(&root).unwrap(); Self(root)
        }
        fn file(&self, path: &str) {
            let path = self.0.join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, b"fixture").unwrap();
            #[cfg(unix)]
            if path.file_name().and_then(|n| n.to_str()) == Some("proton") {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
            }
        }
        fn complete(&self) {
            self.file("proton"); self.file("toolmanifest.vdf");
            self.file("files/bin/wine");
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
    }
    #[test]
    fn modern_layout_is_static_only() {
        let f = Fixture::new(); f.complete();
        assert_eq!(classify_proton_runtime_root(&f.0),
            ("verified", "static-layout-only-not-launch-verified"));
    }
    #[test]
    fn missing_manifest_is_incomplete() {
        let f = Fixture::new(); f.file("proton"); f.file("files/bin/wine");
        assert_eq!(classify_proton_runtime_root(&f.0),
            ("incomplete", "runtime-marker-missing"));
    }
    #[test]
    fn missing_wine_is_incomplete() {
        let f = Fixture::new(); f.file("proton"); f.file("toolmanifest.vdf");
        assert_eq!(classify_proton_runtime_root(&f.0),
            ("incomplete", "runtime-components-missing"));
    }
    #[cfg(unix)]
    #[test]
    fn symlinked_wine_is_unknown() {
        let f = Fixture::new(); f.complete();
        fs::remove_file(f.0.join("files/bin/wine")).unwrap();
        std::os::unix::fs::symlink("/tmp/other", f.0.join("files/bin/wine")).unwrap();
        assert_eq!(classify_proton_runtime_root(&f.0),
            ("unknown", "runtime-symlink"));
    }
    #[test]
    fn legacy_layout_is_static_only() {
        let f = Fixture::new(); f.file("proton"); f.file("toolmanifest.vdf");
        f.file("dist/bin/wine");
        assert_eq!(classify_proton_runtime_root(&f.0),
            ("verified", "static-layout-only-not-launch-verified"));
    }
    #[cfg(unix)]
    #[test]
    fn nonexecutable_launcher_is_incomplete() {
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new(); f.complete();
        fs::set_permissions(f.0.join("proton"), fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(classify_proton_runtime_root(&f.0),
            ("incomplete", "runtime-launcher-not-executable"));
    }
    #[cfg(unix)]
    #[test]
    fn symlinked_bin_is_unknown() {
        let f = Fixture::new(); f.complete();
        fs::rename(f.0.join("files/bin"), f.0.join("real-bin")).unwrap();
        std::os::unix::fs::symlink(f.0.join("real-bin"), f.0.join("files/bin")).unwrap();
        assert_eq!(classify_proton_runtime_root(&f.0), ("unknown", "runtime-symlink"));
    }
    #[cfg(unix)]
    #[test]
    fn symlinked_layout_is_unknown() {
        let f = Fixture::new(); f.complete();
        fs::rename(f.0.join("files"), f.0.join("real-files")).unwrap();
        std::os::unix::fs::symlink(f.0.join("real-files"), f.0.join("files")).unwrap();
        assert_eq!(classify_proton_runtime_root(&f.0), ("unknown", "runtime-symlink"));
    }
    #[cfg(unix)]
    #[test]
    fn nonexecutable_launcher_is_rejected_by_discovery() {
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new(); f.complete();
        fs::set_permissions(f.0.join("proton"), fs::Permissions::from_mode(0o644)).unwrap();
        assert!(proton_launcher_from_candidate(&f.0.join("proton"),
            &[f.0.parent().unwrap().to_path_buf()]).is_none());
    }

    #[test]
    fn arm64_layout_is_static_only() {
        let f = Fixture::new();
        f.file("proton"); f.file("toolmanifest.vdf");
        f.file("files/bin-arm64/wine");
        assert_eq!(classify_proton_runtime_root(&f.0),
            ("verified", "static-layout-only-not-launch-verified"));
    }
    #[test]
    fn metadata_preserves_proton_path_with_spaces() {
        let text = "11.0-100\n/tmp/Proton 11.0 (ARM64)/files/share/fonts/\n";
        assert!(proton_metadata_tokens(text).contains(
            &"/tmp/Proton 11.0 (ARM64)/files/share/fonts/".to_string()));
    }
    #[test]
    fn resolves_nested_arm64_metadata_path_with_spaces() {
        let f = Fixture::new();
        let root = f.0.join("steamapps/common/Proton 11.0 (ARM64)");
        fs::create_dir_all(root.join("files/share/fonts")).unwrap();
        fs::write(root.join("proton"), b"fixture").unwrap();
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(root.join("proton"), fs::Permissions::from_mode(0o755)).unwrap();
        }
        let metadata = format!("11.0-100\n{}/files/share/fonts/\n", root.display());
        let found = proton_launchers_from_metadata(&metadata, &[f.0.join("steamapps/common")]);
        assert_eq!(found.len(), 1);
        assert!(found.contains(&root.join("proton")));
    }
    #[test]
    fn ambiguous_metadata_returns_multiple_candidates() {
        let f = Fixture::new();
        let common = f.0.join("steamapps/common");
        for name in ["Proton A", "Proton B"] {
            let root = common.join(name);
            fs::create_dir_all(root.join("files/share/fonts")).unwrap();
            fs::write(root.join("proton"), b"fixture").unwrap();
            #[cfg(unix)] {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(root.join("proton"), fs::Permissions::from_mode(0o755)).unwrap();
            }
        }
        let metadata = format!("{}/Proton A/files/share/fonts/\n{}/Proton B/files/share/fonts/\n",
            common.display(), common.display());
        let found = proton_launchers_from_metadata(&metadata, &[common]);
        assert_eq!(found.len(), 2);
    }
    #[cfg(unix)]
    #[test]
    fn symlinked_arm64_bin_is_unknown() {
        let f = Fixture::new(); f.file("proton"); f.file("toolmanifest.vdf");
        f.file("files/real-bin/wine");
        std::os::unix::fs::symlink(f.0.join("files/real-bin"), f.0.join("files/bin-arm64")).unwrap();
        assert_eq!(classify_proton_runtime_root(&f.0), ("unknown", "runtime-symlink"));
    }

}

fn reloadedii_setup_path(app_id: u32, encoded_path: &str) -> Result<PathBuf, String> {
    let game = discover_games()
        .into_iter()
        .find(|game| game.app_id == app_id)
        .ok_or_else(|| format!("unknown Steam AppID: {app_id}"))?;

    let decoded =
        decode_field(encoded_path).ok_or_else(|| "invalid Reloaded-II setup path".to_string())?;

    let requested = PathBuf::from(decoded);

    if !requested.is_absolute() {
        return Err("Reloaded-II setup path is not absolute".to_string());
    }

    if requested
        .components()
        .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err("Reloaded-II setup path contains parent traversal".to_string());
    }

    // The installer may only be staged inside this AppID's
    // own compatdata tree.
    let app_compatdata = game
        .library_path
        .join("steamapps")
        .join("compatdata")
        .join(app_id.to_string());

    let canonical_compatdata = fs::canonicalize(&app_compatdata).map_err(|error| {
        format!(
            "failed to canonicalize compatdata for \
                     AppID {app_id}: {error}"
        )
    })?;

    // Reuse the existing central Steam guest-path validator,
    // including the 40F-3A symlink checks.
    let validated = validated_guest_path(encoded_path)?;

    let metadata = fs::symlink_metadata(&validated).map_err(|error| {
        format!(
            "could not inspect Reloaded-II setup: \
                     {error}"
        )
    })?;

    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err("Reloaded-II setup is not a regular file".to_string());
    }

    let file_name = validated
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "Reloaded-II setup filename is not UTF-8".to_string())?;

    // This capability must never become "execute arbitrary EXE".
    if file_name != "Setup-Linux.exe" {
        return Err("Reloaded-II setup must be named Setup-Linux.exe".to_string());
    }

    let canonical_setup = fs::canonicalize(&validated).map_err(|error| {
        format!(
            "failed to canonicalize Reloaded-II \
                     setup: {error}"
        )
    })?;

    if !path_is_within(&canonical_setup, &canonical_compatdata) {
        return Err("Reloaded-II setup is outside this AppID's \
             compatdata"
            .to_string());
    }

    Ok(canonical_setup)
}


// 42A-2-R1: supervised diagnostic readers.
//
// Both pipes are made nonblocking. Readers drain output continuously,
// retain at most 4096 combined bytes, and obey an explicit stop flag.
//
// Unlike the original 42A-2 implementation, reader threads are joined
// before the installer operation returns. Descendants holding inherited
// pipe descriptors therefore cannot keep reader threads alive forever.
fn capture_reloadedii_output<R>(
    mut reader: R,
    output: Arc<Mutex<Vec<u8>>>,
    stop: Arc<AtomicBool>,
) -> Result<thread::JoinHandle<()>, String>
where
    R: Read + AsRawFd + Send + 'static,
{
    let fd = reader.as_raw_fd();

    let flags = unsafe {
        libc::fcntl(fd, libc::F_GETFL)
    };

    if flags < 0 {
        return Err(format!(
            "failed to inspect installer diagnostic pipe: {}",
            io::Error::last_os_error()
        ));
    }

    let result = unsafe {
        libc::fcntl(
            fd,
            libc::F_SETFL,
            flags | libc::O_NONBLOCK,
        )
    };

    if result < 0 {
        return Err(format!(
            "failed to configure installer diagnostic pipe: {}",
            io::Error::last_os_error()
        ));
    }

    Ok(thread::spawn(move || {
        let mut buffer = [0u8; 1024];

        loop {
            if stop.load(Ordering::Acquire) {
                break;
            }

            match reader.read(&mut buffer) {
                Ok(0) => break,

                Ok(count) => {
                    let Ok(mut captured) = output.lock() else {
                        break;
                    };

                    captured.extend_from_slice(&buffer[..count]);

                    if captured.len() > 4096 {
                        let excess = captured.len() - 4096;
                        captured.drain(..excess);
                    }
                }

                Err(error)
                    if error.kind() == io::ErrorKind::Interrupted =>
                {
                    continue;
                }

                Err(error)
                    if error.kind() == io::ErrorKind::WouldBlock =>
                {
                    thread::sleep(Duration::from_millis(20));
                }

                Err(_) => break,
            }
        }
    }))
}

fn reloadedii_diagnostic_snapshot(
    output: &Arc<Mutex<Vec<u8>>>,
) -> String {
    let Ok(captured) = output.lock() else {
        return "diagnostic capture unavailable".to_string();
    };

    if captured.is_empty() {
        return "no installer output captured".to_string();
    }

    let text = String::from_utf8_lossy(&captured);
    let mut result = String::new();

    for character in text.chars().take(1024) {
        match character {
            '\n' | '\r' | '\t' => result.push(' '),
            c if c.is_control() => result.push('?'),
            c if c.is_ascii() => result.push(c),
            _ => result.push('?'),
        }
    }

    result
}

// Only supervise the immediate Proton child.
//
// This does not terminate Wine descendants or claim that the
// installation has been completely cancelled.
fn stop_reloadedii_child(
    child: &mut std::process::Child,
) -> String {
    let termination = match child.kill() {
        Ok(()) => "direct Proton child termination requested".to_string(),

        Err(error) if error.kind() == io::ErrorKind::InvalidInput => {
            "direct Proton child already exited".to_string()
        }

        Err(error) => {
            format!("direct Proton child termination failed: {error}")
        }
    };

    // Never block indefinitely while reaping the immediate child.
    let reap_deadline =
        Instant::now() + Duration::from_secs(3);

    loop {
        match child.try_wait() {
            Ok(Some(_)) => return termination,

            Ok(None) if Instant::now() >= reap_deadline => {
                return format!(
                    "{termination}; direct child reap not confirmed"
                );
            }

            Ok(None) => {
                thread::sleep(Duration::from_millis(50));
            }

            Err(error) => {
                return format!(
                    "{termination}; child reap failed: {error}"
                );
            }
        }
    }
}

fn run_reloadedii_setup(app_id: u32, encoded_path: &str) -> Result<i32, String> {
    let game = discover_games()
        .into_iter()
        .find(|game| game.app_id == app_id)
        .ok_or_else(|| format!("unknown Steam AppID: {app_id}"))?;

    let setup = reloadedii_setup_path(app_id, encoded_path)?;

    // 41C-1 owns Proton selection.
    let proton = proton_runtime_for_app(app_id)?.ok_or_else(|| {
        format!(
            "could not resolve Proton runtime for \
                     AppID {app_id}"
        )
    })?;

    let compatdata = game
        .library_path
        .join("steamapps")
        .join("compatdata")
        .join(app_id.to_string());

    let canonical_compatdata = fs::canonicalize(&compatdata).map_err(|error| {
        format!(
            "failed to canonicalize compatdata for \
                     AppID {app_id}: {error}"
        )
    })?;

    let steam_client = steam_roots()
        .into_iter()
        .next()
        .ok_or_else(|| "Steam client installation not found".to_string())?;

    let canonical_steam_client = fs::canonicalize(&steam_client).map_err(|error| {
        format!(
            "failed to canonicalize Steam client \
                     path: {error}"
        )
    })?;

    // Intentionally direct execution:
    //
    //   <resolved-proton> run <validated-Setup-Linux.exe>
    //
    // There is no shell and no caller-controlled argument list.
    // 42A-2-R1: supervised diagnostic readers.
    //
    // Only the validated installer is executed, through the
    // AppID-selected Proton runtime. No shell is involved.
    let mut child = Command::new(&proton)
        .arg("run")
        .arg(&setup)
        .env("STEAM_COMPAT_DATA_PATH", &canonical_compatdata)
        .env("STEAM_COMPAT_CLIENT_INSTALL_PATH", &canonical_steam_client)
        .env("SteamAppId", app_id.to_string())
        .env("SteamGameId", app_id.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            format!(
                "failed to launch Reloaded-II setup \
                 through Proton: {error}"
            )
        })?;

    let diagnostics = Arc::new(Mutex::new(Vec::<u8>::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let mut readers = Vec::new();

    let mut reader_error = None;

    if let Some(stdout) = child.stdout.take() {
        match capture_reloadedii_output(
            stdout,
            Arc::clone(&diagnostics),
            Arc::clone(&stop),
        ) {
            Ok(handle) => readers.push(handle),
            Err(error) => reader_error = Some(error),
        }
    }

    if reader_error.is_none() {
        if let Some(stderr) = child.stderr.take() {
            match capture_reloadedii_output(
                stderr,
                Arc::clone(&diagnostics),
                Arc::clone(&stop),
            ) {
                Ok(handle) => readers.push(handle),
                Err(error) => reader_error = Some(error),
            }
        }
    }

    if let Some(error) = reader_error {
        let termination = stop_reloadedii_child(&mut child);

        stop.store(true, Ordering::Release);

        for reader in readers {
            let _ = reader.join();
        }

        return Err(format!(
            "Reloaded-II diagnostic setup failed: \
             {error}; {termination}"
        ));
    }

    let deadline =
        Instant::now() + Duration::from_secs(540);

    let outcome = loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                break Ok(status.code().unwrap_or(-1));
            }

            Ok(None) if Instant::now() >= deadline => {
                let termination =
                    stop_reloadedii_child(&mut child);

                break Err(format!(
                    "Reloaded-II setup exceeded 540 seconds \
                     for AppID {app_id}; {termination}; \
                     installation state is uncertain"
                ));
            }

            Ok(None) => {
                thread::sleep(Duration::from_millis(200));
            }

            Err(error) => {
                let termination =
                    stop_reloadedii_child(&mut child);

                break Err(format!(
                    "failed to monitor Reloaded-II setup \
                     for AppID {app_id}: {error}; \
                     {termination}"
                ));
            }
        }
    };

    // Give the readers a brief opportunity to capture final output
    // before signalling shutdown. Never wait for pipe EOF from
    // potentially surviving Wine descendants.
    thread::sleep(Duration::from_millis(100));

    stop.store(true, Ordering::Release);

    for reader in readers {
        let _ = reader.join();
    }

    let detail =
        reloadedii_diagnostic_snapshot(&diagnostics);

    match outcome {
        Ok(0) => Ok(0),

        Ok(code) => {
            eprintln!(
                "Reloaded-II setup failed for AppID {app_id} \
                 with exit code {code}: {detail}"
            );

            Ok(code)
        }

        Err(error) => {
            eprintln!(
                "Reloaded-II setup supervision error: \
                 {error}; diagnostic: {detail}"
            );

            Err(format!(
                "{error}; diagnostic: {detail}"
            ))
        }
    }
}


// 41F-19A: Read-only inspection of a game's Proton environment.
//
// Each filesystem component is inspected independently. A missing or
// incomplete prefix must never be mistaken for a usable Windows environment.
fn inspect_proton_environment(app_id: u32) -> Result<String, String> {
    let game = discover_games()
        .into_iter()
        .find(|game| game.app_id == app_id)
        .ok_or_else(|| format!("unknown Steam AppID: {app_id}"))?;

    let compatdata = game
        .library_path
        .join("steamapps")
        .join("compatdata")
        .join(app_id.to_string());

    let prefix = compatdata.join("pfx");

    // Do not follow a symlinked prefix outside its expected Steam
    // compatdata location.
    if prefix.exists() {
        let canonical = fs::canonicalize(&prefix)
            .map_err(|error| format!("cannot resolve Proton prefix: {error}"))?;

        let canonical_root = fs::canonicalize(
            game.library_path.join("steamapps").join("compatdata")
        ).map_err(|error| format!("cannot resolve compatdata root: {error}"))?;

        if !path_is_within(&canonical, &canonical_root) {
            return Err("Proton prefix escaped its Steam library".to_string());
        }
    }

    let status = |path: &Path, directory: bool| -> &'static str {
        match fs::symlink_metadata(path) {
            Ok(_) if directory && path.is_dir() => "present",
            Ok(_) if !directory && path.is_file() => "present",
            Ok(_) => "invalid",
            Err(error) if error.kind() == io::ErrorKind::NotFound => "missing",
            Err(_) => "inaccessible",
        }
    };

    Ok(format!(
        "proton-inspect {app_id} {} {} {} {} {} {}",
        encode_field(&prefix.to_string_lossy()),
        status(&prefix, true),
        status(&prefix.join("drive_c"), true),
        status(&prefix.join("dosdevices"), true),
        status(&prefix.join("system.reg"), false),
        status(&prefix.join("user.reg"), false),
    ))
}

fn proton_prefix(app_id: u32) -> Option<PathBuf> {
    for game in discover_games() {
        if game.app_id != app_id {
            continue;
        }

        let prefix = game
            .library_path
            .join("steamapps/compatdata")
            .join(app_id.to_string())
            .join("pfx");

        if prefix.is_dir() {
            return Some(prefix);
        }

        return None;
    }

    // compatdata can exist even when the game's manifest is unavailable.
    for library in discover_libraries() {
        let prefix = library
            .join("steamapps/compatdata")
            .join(app_id.to_string())
            .join("pfx");

        if prefix.is_dir() {
            return Some(prefix);
        }
    }

    None
}

fn decode_field(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return None;
            }

            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }

    String::from_utf8(out).ok()
}

fn encode_hex(value: &[u8]) -> String {
    let mut output = String::with_capacity(value.len() * 2);

    for byte in value {
        use std::fmt::Write as _;

        write!(&mut output, "{byte:02x}").expect("writing to String cannot fail");
    }

    output
}

fn decode_hex(value: &str) -> Option<Vec<u8>> {
    if value.len() % 2 != 0 {
        return None;
    }

    value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let text = std::str::from_utf8(pair).ok()?;
            u8::from_str_radix(text, 16).ok()
        })
        .collect()
}

fn guest_path_allowed(path: &Path) -> bool {
    if !path.is_absolute() {
        return false;
    }

    let mut allowed = false;

    for library in discover_libraries() {
        if path.starts_with(library.join("steamapps/common"))
            || path.starts_with(library.join("steamapps/compatdata"))
        {
            allowed = true;
            break;
        }
    }

    allowed
}

// ─────────────────────────────────────────────
//  Reloaded-II mod discovery
//
//  This is intentionally framework-specific.
//
//  BepisLoader does NOT receive a generic guest directory
//  listing primitive. The agent resolves Reloaded-II itself,
//  constrains traversal to that installation's Mods tree,
//  rejects symlinks, and exposes only ModConfig.json paths.
// ─────────────────────────────────────────────

const MAX_RELOADEDII_MOD_CONFIGS: usize = 4096;
const MAX_RELOADEDII_MOD_DEPTH: usize = 16;

fn discover_reloadedii_mod_configs(app_id: u32) -> Result<Vec<PathBuf>, String> {
    let root = match reloadedii_installation_root(app_id)? {
        Some(root) => root,
        None => return Ok(Vec::new()),
    };

    let mods_root = root.join("Mods");

    let root_metadata = match fs::symlink_metadata(&mods_root) {
        Ok(metadata) => metadata,

        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(Vec::new());
        }

        Err(error) => {
            return Err(format!("failed to inspect Reloaded-II Mods root: {error}"));
        }
    };

    if root_metadata.file_type().is_symlink() {
        return Err("Reloaded-II Mods root is a symlink".to_string());
    }

    if !root_metadata.is_dir() {
        return Err("Reloaded-II Mods root is not a directory".to_string());
    }

    let canonical_mods_root = fs::canonicalize(&mods_root).map_err(|error| {
        format!(
            "failed to canonicalize Reloaded-II Mods root: \
                 {error}"
        )
    })?;

    // reloadedii_installation_root() already constrains the
    // installation to the AppID's Proton prefix. Re-check the
    // Mods root against the canonical installation root before
    // walking anything below it.
    let canonical_installation = fs::canonicalize(&root).map_err(|error| {
        format!(
            "failed to canonicalize Reloaded-II installation: \
                 {error}"
        )
    })?;

    if !path_is_within(&canonical_mods_root, &canonical_installation) {
        return Err("Reloaded-II Mods root escaped its installation".to_string());
    }

    let mut pending = vec![(canonical_mods_root.clone(), 0usize)];

    let mut configs = Vec::new();

    while let Some((directory, depth)) = pending.pop() {
        if depth > MAX_RELOADEDII_MOD_DEPTH {
            return Err(format!(
                "Reloaded-II Mods traversal exceeded maximum \
                 depth of {MAX_RELOADEDII_MOD_DEPTH}"
            ));
        }

        if !path_is_within(&directory, &canonical_mods_root) {
            return Err("Reloaded-II mod traversal escaped Mods root".to_string());
        }

        let entries = fs::read_dir(&directory).map_err(|error| {
            format!(
                "failed to read Reloaded-II mod directory {}: \
                     {error}",
                directory.display()
            )
        })?;

        for entry in entries {
            let entry = entry.map_err(|error| {
                format!(
                    "failed to inspect Reloaded-II mod \
                         directory {}: {error}",
                    directory.display()
                )
            })?;

            let path = entry.path();

            let metadata = fs::symlink_metadata(&path).map_err(|error| {
                format!(
                    "failed to inspect Reloaded-II mod path {}: \
                         {error}",
                    path.display()
                )
            })?;

            // Never follow symlinks during framework discovery.
            if metadata.file_type().is_symlink() {
                continue;
            }

            if metadata.is_dir() {
                if depth >= MAX_RELOADEDII_MOD_DEPTH {
                    continue;
                }

                let canonical = fs::canonicalize(&path).map_err(|error| {
                    format!(
                        "failed to canonicalize Reloaded-II \
                             mod directory {}: {error}",
                        path.display()
                    )
                })?;

                if !path_is_within(&canonical, &canonical_mods_root) {
                    return Err("Reloaded-II mod directory escaped Mods root".to_string());
                }

                pending.push((canonical, depth + 1));

                continue;
            }

            if !metadata.is_file() {
                continue;
            }

            if path.file_name().and_then(|name| name.to_str()) != Some("ModConfig.json") {
                continue;
            }

            let canonical = fs::canonicalize(&path).map_err(|error| {
                format!(
                    "failed to canonicalize Reloaded-II \
                         ModConfig.json {}: {error}",
                    path.display()
                )
            })?;

            if !path_is_within(&canonical, &canonical_mods_root) {
                return Err("Reloaded-II ModConfig.json escaped Mods root".to_string());
            }

            configs.push(canonical);

            if configs.len() > MAX_RELOADEDII_MOD_CONFIGS {
                return Err(format!(
                    "Reloaded-II mod discovery exceeded maximum \
                     result count of \
                     {MAX_RELOADEDII_MOD_CONFIGS}"
                ));
            }
        }
    }

    // Stable ordering makes the bridge response deterministic.
    configs.sort();

    Ok(configs)
}

fn canonical_allowed_guest_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();

    for library in discover_libraries() {
        let steamapps = library.join("steamapps");

        for candidate in [steamapps.join("common"), steamapps.join("compatdata")] {
            let Ok(canonical) = fs::canonicalize(&candidate) else {
                continue;
            };

            if canonical.is_dir() && !roots.contains(&canonical) {
                roots.push(canonical);
            }
        }
    }

    roots
}

fn nearest_existing_ancestor(path: &Path) -> Result<PathBuf, String> {
    let mut current = path.to_path_buf();

    loop {
        match fs::symlink_metadata(&current) {
            Ok(_) => {
                return Ok(current);
            }

            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if !current.pop() {
                    return Err("guest path has no existing ancestor".to_string());
                }
            }

            Err(error) => {
                return Err(format!("could not inspect guest path ancestor: {error}"));
            }
        }
    }
}

fn path_is_within(path: &Path, root: &Path) -> bool {
    path == root || path.starts_with(root)
}

fn reject_existing_symlink_components(path: &Path, stop_at: &Path) -> Result<(), String> {
    // Walk from the canonical permitted root toward the requested
    // path. Any existing symlink component is rejected rather than
    // followed.
    let relative = path
        .strip_prefix(stop_at)
        .map_err(|_| "guest path is outside its permitted Steam root".to_string())?;

    let mut current = stop_at.to_path_buf();

    for component in relative.components() {
        current.push(component.as_os_str());

        match fs::symlink_metadata(&current) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Err(format!(
                        "guest path contains symlink component: {}",
                        current.display(),
                    ));
                }
            }

            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                // Once a component does not exist, descendants cannot
                // exist either in a normal resolved path. This is the
                // expected case for a new write/mkdir target.
                break;
            }

            Err(error) => {
                return Err(format!("could not inspect guest path component: {error}"));
            }
        }
    }

    Ok(())
}

fn validate_guest_path_canonical(path: &Path) -> Result<(), String> {
    let roots = canonical_allowed_guest_roots();

    if roots.is_empty() {
        return Err("no canonical Steam filesystem roots are available".to_string());
    }

    // First match the requested lexical path to an allowed Steam
    // root. The existing validated_guest_path() already rejects ..
    // traversal; this step identifies the root whose filesystem
    // boundary we must enforce.
    let mut matched_root: Option<(PathBuf, PathBuf)> = None;

    for library in discover_libraries() {
        let steamapps = library.join("steamapps");

        for lexical_root in [steamapps.join("common"), steamapps.join("compatdata")] {
            if path == lexical_root || path.starts_with(&lexical_root) {
                let Ok(canonical_root) = fs::canonicalize(&lexical_root) else {
                    continue;
                };

                if roots.contains(&canonical_root) {
                    matched_root = Some((lexical_root, canonical_root));
                    break;
                }
            }
        }

        if matched_root.is_some() {
            break;
        }
    }

    let (lexical_root, canonical_root) =
        matched_root.ok_or_else(|| "guest path is outside permitted Steam roots".to_string())?;

    // Explicitly reject symlink components in the lexical tree.
    //
    // This is stronger than merely checking where canonicalization
    // ends up: even a symlink that points somewhere else inside the
    // allowed root is not accepted for mutation/path access.
    reject_existing_symlink_components(path, &lexical_root)?;

    let ancestor = nearest_existing_ancestor(path)?;

    let canonical_ancestor = fs::canonicalize(&ancestor)
        .map_err(|error| format!("could not canonicalize guest path ancestor: {error}"))?;

    if !path_is_within(&canonical_ancestor, &canonical_root) {
        return Err("guest path escapes permitted Steam roots".to_string());
    }

    Ok(())
}

fn validated_guest_path(encoded: &str) -> Result<PathBuf, String> {
    let decoded = decode_field(encoded).ok_or("invalid-path".to_string())?;
    let path = PathBuf::from(decoded);

    if path
        .components()
        .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err("invalid-path".to_string());
    }

    if !guest_path_allowed(&path) {
        return Err("path-not-allowed".to_string());
    }

    validate_guest_path_canonical(&path)?;

    Ok(path)
}

fn encode_bepis_field(value: &str) -> String {
    let mut output = String::with_capacity(value.len());

    for byte in value.as_bytes() {
        let allowed =
            byte.is_ascii_alphanumeric() || matches!(*byte, b'-' | b'_' | b'.' | b'/' | b':');

        if allowed {
            output.push(*byte as char);
        } else {
            use std::fmt::Write as _;
            write!(&mut output, "%{:02X}", byte).expect("writing to String cannot fail");
        }
    }

    output
}

#[derive(Debug, Clone, Copy)]
enum PeArchitecture {
    X86,
    X64,
}

fn pe_architecture(path: &Path) -> io::Result<Option<PeArchitecture>> {
    use std::io::{Read, Seek, SeekFrom};

    let mut file = fs::File::open(path)?;

    let mut dos = [0u8; 64];
    file.read_exact(&mut dos)?;

    if &dos[0..2] != b"MZ" {
        return Ok(None);
    }

    let pe_offset = u32::from_le_bytes([dos[0x3c], dos[0x3d], dos[0x3e], dos[0x3f]]) as u64;

    // Defensive ceiling: a sane PE header should not require seeking
    // hundreds of megabytes into a file.
    if pe_offset > 16 * 1024 * 1024 {
        return Ok(None);
    }

    file.seek(SeekFrom::Start(pe_offset))?;

    let mut header = [0u8; 6];
    file.read_exact(&mut header)?;

    if &header[0..4] != b"PE\0\0" {
        return Ok(None);
    }

    let machine = u16::from_le_bytes([header[4], header[5]]);

    match machine {
        0x014c => Ok(Some(PeArchitecture::X86)),
        0x8664 => Ok(Some(PeArchitecture::X64)),
        _ => Ok(None),
    }
}

fn discover_game_executables(root: &Path) -> Vec<PathBuf> {
    fn walk(directory: &Path, depth: usize, results: &mut Vec<PathBuf>) {
        // Enough for normal game layouts without recursively crawling
        // huge content trees forever.
        if depth > 4 || results.len() >= 256 {
            return;
        }

        let entries = match fs::read_dir(directory) {
            Ok(entries) => entries,
            Err(_) => return,
        };

        for entry in entries.flatten() {
            if results.len() >= 256 {
                return;
            }

            let path = entry.path();

            let file_type = match entry.file_type() {
                Ok(file_type) => file_type,
                Err(_) => continue,
            };

            // Never follow symlinks while discovering executables.
            if file_type.is_symlink() {
                continue;
            }

            if file_type.is_dir() {
                let name = entry.file_name().to_string_lossy().to_ascii_lowercase();

                // Skip directories that are extremely unlikely to contain
                // the game's launch executable and can be enormous.
                if matches!(
                    name.as_str(),
                    "bepinex" | "mods" | "plugins" | "workshop" | "shadercache" | "screenshots"
                ) {
                    continue;
                }

                walk(&path, depth + 1, results);
                continue;
            }

            if !file_type.is_file() {
                continue;
            }

            let is_exe = path
                .extension()
                .and_then(|value| value.to_str())
                .map(|value| value.eq_ignore_ascii_case("exe"))
                .unwrap_or(false);

            if is_exe {
                results.push(path);
            }
        }
    }

    let mut results = Vec::new();
    walk(root, 0, &mut results);

    results.sort();
    results.dedup();
    results
}

fn permitted_guest_root_for_path(path: &Path) -> Result<PathBuf, String> {
    let canonical_roots = canonical_allowed_guest_roots();

    let canonical_path = if path.exists() {
        fs::canonicalize(path)
            .map_err(|error| format!("could not canonicalize guest path: {error}"))?
    } else {
        let ancestor = nearest_existing_ancestor(path)?;

        fs::canonicalize(&ancestor)
            .map_err(|error| format!("could not canonicalize guest path ancestor: {error}"))?
    };

    canonical_roots
        .into_iter()
        .find(|root| path_is_within(&canonical_path, root))
        .ok_or_else(|| "guest path is outside permitted Steam roots".to_string())
}

// 41F-21D.39: publish a staged DLL using hard_link(2), which is atomic
// and fails with AlreadyExists rather than replacing an existing plugin.
// Stage files must be created in the selected game's BepInEx/plugins directory.
fn plugin_commit(app_id: u32, encoded_stage: &str, encoded_name: &str) -> Result<(), String> {
    let game = discover_games().into_iter().find(|g| g.app_id == app_id)
        .ok_or_else(|| "unknown-appid".to_string())?;
    let name = decode_field(encoded_name).ok_or("invalid-plugin-name")?;
    if name.len() < 5 || name.len() > 255 || !name.to_ascii_lowercase().ends_with(".dll")
        || name == "." || name == ".." || name.contains('/') || name.contains('\\')
        || name.chars().any(|c| c.is_control()) {
        return Err("invalid-plugin-name".into());
    }
    let game_root = game.install_path.canonicalize()
        .map_err(|_| "game-root-unavailable")?;
    let common = game.library_path.join("steamapps/common").canonicalize()
        .map_err(|_| "steam-common-unavailable")?;
    if !path_is_within(&game_root, &common) || game_root == common {
        return Err("game-root-escape".into());
    }
    let plugins = game_root.join("BepInEx/plugins");
    let meta = fs::symlink_metadata(&plugins).map_err(|_| "plugins-directory-missing")?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err("plugins-directory-unsafe".into());
    }
    let canonical_plugins = plugins.canonicalize().map_err(|_| "plugins-directory-unsafe")?;
    if canonical_plugins != plugins { return Err("plugins-directory-redirected".into()); }
    let stage = validated_guest_path(encoded_stage)?;
    if stage.parent() != Some(plugins.as_path()) { return Err("stage-outside-plugins".into()); }
    let stage_name = stage.file_name().and_then(|n| n.to_str()).ok_or("invalid-stage")?;
    if !stage_name.starts_with(".bepis-stage-") || !stage_name.ends_with(".tmp") {
        return Err("invalid-stage".into());
    }
    let stage_meta = fs::symlink_metadata(&stage).map_err(|_| "stage-missing")?;
    if !stage_meta.is_file() || stage_meta.file_type().is_symlink()
        || stage_meta.len() == 0 || stage_meta.len() > 64 * 1024 * 1024 {
        return Err("stage-unsafe".into());
    }
    let destination = plugins.join(name);
    // hard_link never replaces an existing destination, even if another
    // writer creates it concurrently. Same directory => same filesystem.
    fs::hard_link(&stage, &destination).map_err(|e| {
        if e.kind() == io::ErrorKind::AlreadyExists { "plugin-already-exists".to_string() }
        else { format!("plugin-commit-failed:{e}") }
    })?;
    // The destination is already safely published; cleanup failure is not
    // reported as a failed install (host may clean the stage separately).
    let _ = fs::remove_file(&stage);
    Ok(())
}

fn handle_fs_request(port: &mut std::fs::File, request: &str) -> io::Result<bool> {
    if let Some(rest)=request.strip_prefix("asset-profile-state ") {
        let result=(||->Result<serde_json::Value,String>{
            let app_id=rest.parse::<u32>().map_err(|_|"invalid-appid")?;
            let game=discover_games().into_iter().find(|g|g.app_id==app_id).ok_or("unknown-appid")?;
            asset_mod::profile_state(app_id,&game.install_path)
        })();
        match result{Ok(state)=>send(port,&format!("asset-profile-state {}",encode_field(&state.to_string())))?,Err(e)=>send(port,&format!("error {}",encode_field(&e)))?}
        return Ok(true);
    }
    if let Some(rest)=request.strip_prefix("asset-profile-publish ") {
        let result=(||->Result<PathBuf,String>{
            let fields:Vec<_>=rest.split_whitespace().collect();if fields.len()!=3{return Err("invalid-profile-request".into());}
            let app_id=fields[0].parse::<u32>().map_err(|_|"invalid-appid")?;
            let game=discover_games().into_iter().find(|g|g.app_id==app_id).ok_or("unknown-appid")?;
            let common=game.library_path.join("steamapps/common").canonicalize().map_err(|_|"common-unavailable")?;
            let root=game.install_path.canonicalize().map_err(|_|"game-unavailable")?;
            if root==common || !path_is_within(&root,&common){return Err("game-root-escape".into());}
            asset_mod::profile_publish(app_id,fields[1],&validated_guest_path(fields[2])?,&root)
        })();
        match result{Ok(root)=>send(port,&format!("asset-profile-published {}",encode_field(&root.to_string_lossy())))?,Err(e)=>send(port,&format!("error {}",encode_field(&e)))?}
        return Ok(true);
    }
    if let Some(rest)=request.strip_prefix("asset-mod-disable ") {
        let result=(||->Result<(),String>{
            let app_id=rest.parse::<u32>().map_err(|_|"invalid-appid")?;
            let game=discover_games().into_iter().find(|g|g.app_id==app_id).ok_or("unknown-appid")?;
            let common=game.library_path.join("steamapps/common").canonicalize().map_err(|_|"common-unavailable")?;
            let root=game.install_path.canonicalize().map_err(|_|"game-unavailable")?;
            if root==common || !path_is_within(&root,&common){return Err("game-root-escape".into());}
            asset_mod::disable(app_id,&root)
        })();
        match result{Ok(())=>send(port,"asset-mod-disabled")?,Err(e)=>send(port,&format!("error {}",encode_field(&e)))?,}
        return Ok(true);
    }
    if let Some(rest) = request.strip_prefix("asset-mod-install ") {
        let fields: Vec<_> = rest.split_whitespace().collect();
        let result = (|| -> Result<PathBuf, String> {
            if fields.len()!=3 { return Err("invalid-asset-install-request".into()); }
            let app_id=fields[0].parse::<u32>().map_err(|_|"invalid-appid")?;
            let game=discover_games().into_iter().find(|g|g.app_id==app_id).ok_or("unknown-appid")?;
            let common=game.library_path.join("steamapps/common").canonicalize().map_err(|_|"common-unavailable")?;
            let root=game.install_path.canonicalize().map_err(|_|"game-unavailable")?;
            if root==common || !path_is_within(&root,&common){return Err("game-root-escape".into());}
            let stage=validated_guest_path(fields[2])?;
            asset_mod::install(app_id,fields[1],&stage,&root)
        })();
        match result { Ok(root)=>send(port,&format!("asset-mod-installed {}",encode_field(&root.to_string_lossy())))?, Err(e)=>send(port,&format!("error {}",encode_field(&e)))? }
        return Ok(true);
    }


    if let Some(rest) = request.strip_prefix("plugin-commit ") {
        let parts: Vec<_> = rest.split_whitespace().collect();
        if parts.len() != 3 { send(port, "error invalid-plugin-commit")?; return Ok(true); }
        match parts[0].parse::<u32>() {
            Ok(app_id) => match plugin_commit(app_id, parts[1], parts[2]) {
                Ok(()) => send(port, "plugin-committed")?,
                Err(e) => send(port, &format!("error {e}"))?,
            },
            Err(_) => send(port, "error invalid-appid")?,
        }
        return Ok(true);
    }
    if let Some(encoded) = request.strip_prefix("pe-info ") {
        match validated_guest_path(encoded) {
            Ok(path) => match pe_architecture(&path) {
                Ok(Some(PeArchitecture::X86)) => {
                    send(port, "pe-info x86")?;
                }
                Ok(Some(PeArchitecture::X64)) => {
                    send(port, "pe-info x64")?;
                }
                Ok(None) => {
                    send(port, "pe-info unknown")?;
                }
                Err(error) => {
                    send(port, &format!("error {error}"))?;
                }
            },
            Err(error) => {
                send(port, &format!("error {error}"))?;
            }
        }

        return Ok(true);
    }

    if let Some(encoded) = request.strip_prefix("game-executables ") {
        match validated_guest_path(encoded) {
            Ok(path) => {
                let executables = discover_game_executables(&path);

                send(port, &format!("game-executables {}", executables.len()))?;

                for executable in executables {
                    send(
                        port,
                        &format!(
                            "executable {}",
                            encode_bepis_field(&executable.to_string_lossy()),
                        ),
                    )?;
                }

                send(port, "game-executables-end")?;
            }
            Err(error) => {
                send(port, &format!("error {error}"))?;
            }
        }

        return Ok(true);
    }

    if let Some(encoded) = request.strip_prefix("fs-stat ") {
        match validated_guest_path(encoded) {
            Ok(path) => match fs::symlink_metadata(&path) {
                Ok(metadata) => {
                    let kind = if metadata.file_type().is_symlink() {
                        "symlink"
                    } else if metadata.is_dir() {
                        "directory"
                    } else if metadata.is_file() {
                        "file"
                    } else {
                        "other"
                    };

                    send(port, &format!("fs-stat {kind} {}", metadata.len()))?;
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    send(port, "fs-stat missing 0")?;
                }
                Err(_) => {
                    send(port, "error fs-stat-failed")?;
                }
            },
            Err(error) => send(port, &format!("error {error}"))?,
        }

        return Ok(true);
    }

    if let Some(rest) = request.strip_prefix("fs-read ") {
        let mut parts = rest.split(' ');

        let Some(encoded_path) = parts.next() else {
            send(port, "error invalid-read")?;
            return Ok(true);
        };

        let Some(raw_offset) = parts.next() else {
            send(port, "error invalid-read")?;
            return Ok(true);
        };

        let Some(raw_length) = parts.next() else {
            send(port, "error invalid-read")?;
            return Ok(true);
        };

        if parts.next().is_some()
            || encoded_path.is_empty()
            || raw_offset.is_empty()
            || raw_length.is_empty()
        {
            send(port, "error invalid-read")?;
            return Ok(true);
        }

        let offset = match raw_offset.parse::<u64>() {
            Ok(value) => value,

            Err(_) => {
                send(port, "error invalid-read-offset")?;
                return Ok(true);
            }
        };

        let length = match raw_length.parse::<usize>() {
            Ok(value) => value,

            Err(_) => {
                send(port, "error invalid-read-length")?;
                return Ok(true);
            }
        };

        // Keep the encoded response comfortably below the
        // bridge's 16 KiB line limit:
        //
        //   6144 raw bytes -> 12288 hex characters
        //
        // plus the small protocol header.
        if length > 6 * 1024 {
            send(port, "error chunk-too-large")?;
            return Ok(true);
        }

        let path = match validated_guest_path(encoded_path) {
            Ok(path) => path,

            Err(error) => {
                send(port, &format!("error {error}"))?;
                return Ok(true);
            }
        };

        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,

            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                send(port, "error fs-read-missing")?;
                return Ok(true);
            }

            Err(_) => {
                send(port, "error fs-read-failed")?;
                return Ok(true);
            }
        };

        // validated_guest_path() already rejects existing
        // symlink components. Keep the leaf check explicit too:
        // fs-read is for ordinary files only.
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            send(port, "error fs-read-not-file")?;
            return Ok(true);
        }

        let mut file = match fs::File::open(&path) {
            Ok(file) => file,

            Err(_) => {
                send(port, "error fs-read-failed")?;
                return Ok(true);
            }
        };

        if file.seek(SeekFrom::Start(offset)).is_err() {
            send(port, "error fs-read-failed")?;
            return Ok(true);
        }

        let mut data = vec![0u8; length];

        let count = match file.read(&mut data) {
            Ok(count) => count,

            Err(_) => {
                send(port, "error fs-read-failed")?;
                return Ok(true);
            }
        };

        data.truncate(count);

        send(
            port,
            &format!("fs-read {} {}", data.len(), encode_hex(&data)),
        )?;

        return Ok(true);
    }

    if let Some(encoded) = request.strip_prefix("fs-mkdir ") {
        match validated_guest_path(encoded) {
            Ok(path) => match fs::create_dir_all(path) {
                Ok(()) => send(port, "ok")?,
                Err(_) => send(port, "error fs-mkdir-failed")?,
            },
            Err(error) => send(port, &format!("error {error}"))?,
        }

        return Ok(true);
    }

    if let Some(rest) = request.strip_prefix("fs-write ") {
        let Some((encoded_path, hex)) = rest.split_once(' ') else {
            send(port, "error invalid-write")?;
            return Ok(true);
        };

        let path = match validated_guest_path(encoded_path) {
            Ok(path) => path,
            Err(error) => {
                send(port, &format!("error {error}"))?;
                return Ok(true);
            }
        };

        let Some(data) = decode_hex(hex) else {
            send(port, "error invalid-data")?;
            return Ok(true);
        };

        if data.len() > 6 * 1024 {
            send(port, "error chunk-too-large")?;
            return Ok(true);
        }

        if let Some(parent) = path.parent() {
            if let Err(_) = fs::create_dir_all(parent) {
                send(port, "error fs-mkdir-failed")?;
                return Ok(true);
            }
        }

        match OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(path)
            .and_then(|mut file| file.write_all(&data))
        {
            Ok(()) => send(port, "ok")?,
            Err(_) => send(port, "error fs-write-failed")?,
        }

        return Ok(true);
    }

    if let Some(rest) = request.strip_prefix("fs-append ") {
        let Some((encoded_path, hex)) = rest.split_once(' ') else {
            send(port, "error invalid-write")?;
            return Ok(true);
        };

        let path = match validated_guest_path(encoded_path) {
            Ok(path) => path,
            Err(error) => {
                send(port, &format!("error {error}"))?;
                return Ok(true);
            }
        };

        let Some(data) = decode_hex(hex) else {
            send(port, "error invalid-data")?;
            return Ok(true);
        };

        if data.len() > 6 * 1024 {
            send(port, "error chunk-too-large")?;
            return Ok(true);
        }

        match OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .and_then(|mut file| file.write_all(&data))
        {
            Ok(()) => send(port, "ok")?,
            Err(_) => send(port, "error fs-write-failed")?,
        }

        return Ok(true);
    }

    if let Some(rest) = request.strip_prefix("fs-rename ") {
        let Some((encoded_source, encoded_destination)) = rest.split_once(' ') else {
            send(port, "error invalid-rename")?;

            return Ok(true);
        };

        let source = match validated_guest_path(encoded_source) {
            Ok(path) => path,
            Err(error) => {
                send(port, &format!("error {error}"))?;

                return Ok(true);
            }
        };

        let destination = match validated_guest_path(encoded_destination) {
            Ok(path) => path,
            Err(error) => {
                send(port, &format!("error {error}"))?;

                return Ok(true);
            }
        };

        let source_metadata = match fs::symlink_metadata(&source) {
            Ok(metadata) => metadata,

            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                send(port, "error fs-rename-source-not-found")?;

                return Ok(true);
            }

            Err(_) => {
                send(port, "error fs-rename-stat-failed")?;

                return Ok(true);
            }
        };

        if source_metadata.file_type().is_symlink() {
            send(port, "error fs-rename-source-symlink")?;

            return Ok(true);
        }

        // Never inherit rename() replacement semantics.
        match fs::symlink_metadata(&destination) {
            Ok(_) => {
                send(port, "error fs-rename-destination-exists")?;

                return Ok(true);
            }

            Err(error) if error.kind() == io::ErrorKind::NotFound => {}

            Err(_) => {
                send(port, "error fs-rename-stat-failed")?;

                return Ok(true);
            }
        }

        // Both paths must belong to the same permitted
        // Steam filesystem root.
        let source_root = match permitted_guest_root_for_path(&source) {
            Ok(root) => root,

            Err(error) => {
                send(port, &format!("error {error}"))?;

                return Ok(true);
            }
        };

        let destination_root = match permitted_guest_root_for_path(&destination) {
            Ok(root) => root,

            Err(error) => {
                send(port, &format!("error {error}"))?;

                return Ok(true);
            }
        };

        if source_root != destination_root {
            send(port, "error fs-rename-cross-root")?;

            return Ok(true);
        }

        if let Some(parent) = destination.parent() {
            if fs::create_dir_all(parent).is_err() {
                send(port, "error fs-mkdir-failed")?;

                return Ok(true);
            }
        }

        match fs::rename(&source, &destination) {
            Ok(()) => {
                send(port, "ok")?;
            }

            Err(_) => {
                send(port, "error fs-rename-failed")?;
            }
        }

        return Ok(true);
    }

    if let Some(encoded) = request.strip_prefix("fs-remove ") {
        match validated_guest_path(encoded) {
            Ok(path) => {
                let result = match fs::symlink_metadata(&path) {
                    Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path),
                    Ok(_) => fs::remove_file(path),
                    Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
                    Err(error) => Err(error),
                };

                match result {
                    Ok(()) => send(port, "ok")?,
                    Err(_) => send(port, "error fs-remove-failed")?,
                }
            }
            Err(error) => send(port, &format!("error {error}"))?,
        }

        return Ok(true);
    }

    Ok(false)
}

fn send_games(port: &mut std::fs::File) -> io::Result<()> {
    let games = discover_games();

    send(port, &format!("steam-games {}", games.len()))?;

    for game in games {
        let name = encode_field(&game.name);
        let install = encode_field(&game.install_path.to_string_lossy());
        let library = encode_field(&game.library_path.to_string_lossy());

        send(
            port,
            &format!("game {} {name} {install} {library}", game.app_id),
        )?;
    }

    send(port, "steam-games-end")
}


// 41F-15: persistent launch reservation protocol. No executable dispatch here:
// a mod-aware launch must first supply runtime injection attestation.
fn mod_launch_token(token: &str) -> bool {
    token.len() == 36
        && token.bytes().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) { b == b'-' }
            else { b.is_ascii_hexdigit() }
        })
}

fn mod_launch_record(app_id: u32, token: &str) -> Result<PathBuf, String> {
    if !mod_launch_token(token) { return Err("invalid-launch-id".to_string()); }
    if !known_steam_app(app_id) { return Err("unknown-appid".to_string()); }
    let root = bepis_state_root().join("mod-launch-v1").join(app_id.to_string());
    fs::create_dir_all(&root).map_err(|_| "launch-state-unavailable".to_string())?;
    Ok(root.join(token))
}

fn mod_launch_status(app_id: u32, token: &str) -> Result<&'static str, String> {
    let record = mod_launch_record(app_id, token)?;
    match fs::symlink_metadata(&record) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            // Reservations survive agent reconnects/restarts. They are never
            // interpreted as evidence of a running process or mod injection.
            Ok("blocked-unverified")
        }
        Ok(_) => Err("invalid-launch-state".to_string()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok("not-requested"),
        Err(_) => Err("launch-state-unavailable".to_string()),
    }
}

fn mod_launch_request(app_id: u32, token: &str) -> Result<&'static str, String> {
    let record = mod_launch_record(app_id, token)?;
    if mod_launch_status(app_id, token)? != "not-requested" {
        return Ok("blocked-unverified");
    }
    // No game is launched here. The reservation prevents a later replay from
    // accidentally executing a request whose earlier result was ambiguous.
    // Runtime injection attestation is mandatory before enabling execution.
    let mut file = match OpenOptions::new().write(true).create_new(true).open(&record) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            return Ok("blocked-unverified");
        }
        Err(_) => return Err("launch-state-unavailable".to_string()),
    };
    file.write_all(b"blocked-unverified\n")
        .map_err(|_| "launch-state-unavailable".to_string())?;
    file.sync_all().map_err(|_| "launch-state-unavailable".to_string())?;
    Ok("blocked-unverified")
}

fn handle_mod_launch_request(port: &mut std::fs::File, request: &str) -> io::Result<bool> {
    for (verb, command) in [
        ("mod-launch-status ", "status"),
        ("mod-launch-request ", "request"),
    ] {
        if let Some(rest) = request.strip_prefix(verb) {
            let fields: Vec<_> = rest.split_whitespace().collect();
            if fields.len() != 2 {
                send(port, "error invalid-mod-launch-request")?;
                return Ok(true);
            }
            let Ok(app_id) = fields[0].parse::<u32>() else {
                send(port, "error invalid-appid")?;
                return Ok(true);
            };
            let token = fields[1];
            let result = if command == "status" {
                mod_launch_status(app_id, token)
            } else {
                mod_launch_request(app_id, token)
            };
            match result {
                Ok(state) => send(port, &format!("mod-launch-{command} {app_id} {token} {state}"))?,
                Err(error) => send(port, &format!("error {error}"))?,
            }
            return Ok(true);
        }
    }
    Ok(false)
}

fn serve(mut port: std::fs::File) -> io::Result<()> {
    let reader_file = port.try_clone()?;
    let mut reader = BufReader::new(reader_file);
    let mut line = String::new();

    loop {
        line.clear();

        let count = reader.read_line(&mut line)?;
        if count == 0 {
            return Ok(());
        }

        if count > MAX_LINE {
            send(&mut port, "error request-too-large")?;
            continue;
        }

        let request = line.trim_end_matches(['\r', '\n']);

        if request == "hello" {
            send(
                &mut port,
                "hello 1 KiwiSingh/steamac guestFileAccess pluginCommitV1 assetModInstallV1 assetModProfilesV1 recoveryInventoryV1 steamLibraryDiscovery protonPrefixResolution protonRuntimeResolution protonEnvironmentInspection reloadedIIPathDiscovery reloadedIISetupExecution reloadedIIModDiscovery reloadedIIModInventoryV1 reloadedIIModMetadataV1 bepInExInstallationInventoryV1 modLaunchReservationV1 protonRuntimeAttestationV1",
            )?;
            continue;
        }

        if let Some(token) = request.strip_prefix("ping ") {
            if token.is_empty() || token.len() > 256 {
                send(&mut port, "error invalid-ping")?;
            } else {
                send(&mut port, &format!("pong {token}"))?;
            }
            continue;
        }

        #[cfg(target_os = "linux")]
        if let Some(args) = request.strip_prefix("recovery-inventory ") {
            let parts: Vec<_> = args.split_whitespace().collect();
            let result = (|| -> Result<serde_json::Value, String> {
                if parts.len() != 2 { return Err("invalid-inventory-request".into()); }
                let app_id = parts[0].parse::<u32>().map_err(|_| "invalid-appid")?;
                let game = discover_games().into_iter().find(|g| g.app_id == app_id).ok_or("unknown-appid")?;
                let common = game.library_path.join("steamapps/common");
                if !game.install_path.starts_with(&common) || game.install_path == common {
                    return Err("game-root-outside-library".into());
                }
                if parts[1] == "userdata" {
                    let root = steam_roots().into_iter().next().ok_or("steam-root-unavailable")?.join("userdata");
                    return recovery_inventory::userdata(&root, app_id);
                }
                let root = match parts[1] {
                    "game" => game.install_path,
                    "prefix" => proton_prefix(app_id).ok_or("prefix-unavailable")?,
                    "users" => proton_prefix(app_id).ok_or("prefix-unavailable")?.join("drive_c/users"),
                    _ => return Err("invalid-scope".into()),
                };
                recovery_inventory::inventory(&root)
            })();
            match result {
                Ok(value) => {
                    let text = value.to_string();
                    // Chunk JSON below per-line protocol limits; total is bounded by walker.
                    send(&mut port, "recovery-inventory-begin")?;
                    for chunk in text.as_bytes().chunks(2048) {
                        let hex: String = chunk.iter().map(|b| format!("{b:02x}")).collect();
                        send(&mut port, &format!("recovery-inventory-chunk {hex}"))?;
                    }
                    send(&mut port, "recovery-inventory-end")?;
                }
                Err(error) => send(&mut port, &format!("error recovery-inventory-{}", encode_field(&error)))?,
            }
            continue;
        }

        // 41F-21B.6: read-only BepInEx inventory (no filesystem mutation).
        if let Some(raw_app_id) = request.strip_prefix("bepinex-inventory ") {
            match raw_app_id.parse::<u32>() {
                Ok(app_id) => match bepinex_inventory(app_id) {
                    Ok((state, evidence)) => send(
                        &mut port,
                        &format!("bepinex-inventory {app_id} {state} {}", encode_field(evidence)),
                    )?,
                    Err(error) => send(&mut port, &format!("error {error}"))?,
                },
                Err(_) => send(&mut port, "error invalid-appid")?,
            }
            continue;
        }

        if let Some(raw_app_id) = request.strip_prefix("bepinex-activate ") {
            match raw_app_id.parse::<u32>() {
                Ok(app_id) => match activate_bepinex(app_id) {
                    Ok(changed) => {
                        send(&mut port, &format!("bepinex-activated {app_id} {changed}"))?;
                    }

                    Err(error) => {
                        send(&mut port, &format!("error {error}"))?;
                    }
                },

                Err(_) => {
                    send(&mut port, "error invalid Steam app ID")?;
                }
            }

            continue;
        }

        if let Some(raw_app_id) = request.strip_prefix("bepinex-deactivate ") {
            match raw_app_id.parse::<u32>() {
                Ok(app_id) => match deactivate_bepinex(app_id) {
                    Ok(changed) => {
                        send(
                            &mut port,
                            &format!("bepinex-deactivated {app_id} {changed}"),
                        )?;
                    }

                    Err(error) => {
                        send(&mut port, &format!("error {error}"))?;
                    }
                },

                Err(_) => {
                    send(&mut port, "error invalid Steam app ID")?;
                }
            }

            continue;
        }

        if let Some(raw_app_id) = request.strip_prefix("reloadedii-paths ") {
            match raw_app_id.parse::<u32>() {
                Ok(app_id) => match reloadedii_installation_root(app_id) {
                    Ok(Some(root)) => {
                        send(
                            &mut port,
                            &format!(
                                "reloadedii-paths {app_id} {}",
                                encode_field(&root.to_string_lossy())
                            ),
                        )?;
                    }

                    Ok(None) => {
                        send(&mut port, &format!("reloadedii-paths {app_id} none"))?;
                    }

                    Err(error) => {
                        send(&mut port, &format!("error {error}"))?;
                    }
                },

                Err(_) => {
                    send(&mut port, "error invalid-appid")?;
                }
            }

            continue;
        }

        if let Some(raw_app_id) = request.strip_prefix("reloadedii-mods ") {
            match raw_app_id.parse::<u32>() {
                Ok(app_id) => match discover_reloadedii_mod_configs(app_id) {
                    Ok(configs) => {
                        send(
                            &mut port,
                            &format!(
                                "reloadedii-mods \
                                     {app_id} {}",
                                configs.len()
                            ),
                        )?;

                        for config in configs {
                            send(
                                &mut port,
                                &format!(
                                    "reloadedii-mod {}",
                                    encode_field(&config.to_string_lossy())
                                ),
                            )?;
                        }

                        send(
                            &mut port,
                            &format!(
                                "reloadedii-mods-end \
                                     {app_id}"
                            ),
                        )?;
                    }

                    Err(error) => {
                        send(&mut port, &format!("error {error}"))?;
                    }
                },

                Err(_) => {
                    send(&mut port, "error invalid-appid")?;
                }
            }

            continue;
        }


        // 41F-20A: Read-only Reloaded-II inventory protocol.
        //
        // This intentionally exposes only previously validated
        // ModConfig.json paths, not arbitrary filesystem access.
        if let Some(raw_app_id) = request.strip_prefix("reloadedii-inventory ") {
            match raw_app_id.parse::<u32>() {
                Ok(app_id) => {
                    let result = (|| -> Result<_, String> {
                        let installation = reloadedii_installation_root(app_id)?;
                        let configs = discover_reloadedii_mod_configs(app_id)?;

                        Ok((installation.is_some(), configs))
                    })();

                    match result {
                        Ok((installed, configs)) => {
                            let state = if installed { "installed" } else { "absent" };

                            send(
                                &mut port,
                                &format!(
                                    "reloadedii-inventory {app_id} {state} {}",
                                    configs.len()
                                ),
                            )?;

                            for config in configs {
                                send(
                                    &mut port,
                                    &format!(
                                        "reloadedii-inventory-item {}",
                                        encode_field(&config.to_string_lossy())
                                    ),
                                )?;
                            }

                            send(&mut port, &format!("reloadedii-inventory-end {app_id}"))?;
                        }

                        Err(error) => {
                            send(&mut port, &format!("error {error}"))?;
                        }
                    }
                }

                Err(_) => {
                    send(&mut port, "error invalid-appid")?;
                }
            }

            continue;
        }


        // 41F-20C.2: Read-only Reloaded-II metadata.
        //
        // No generic file-read primitive is exposed.
        // Paths originate exclusively from AppID-scoped discovery.
        if let Some(raw_app_id) = request.strip_prefix("reloadedii-metadata ") {
            match raw_app_id.parse::<u32>() {
                Ok(app_id) => {
                    match discover_reloadedii_mod_configs(app_id) {
                        Ok(configs) => {
                            // 41F-20C.4: Prepare every record before sending
                            // the header. A framing failure must not produce
                            // a partial inventory.
                            let records: Result<Vec<String>, String> = configs
                                .iter()
                                .map(|config| reloadedii_metadata_record(config))
                                .collect();

                            match records {
                                Ok(records) => {
                                    send(
                                        &mut port,
                                        &format!(
                                            "reloadedii-metadata {app_id} {}",
                                            records.len()
                                        ),
                                    )?;

                                    for record in records {
                                        send(&mut port, &record)?;
                                    }

                                    send(
                                        &mut port,
                                        &format!("reloadedii-metadata-end {app_id}"),
                                    )?;
                                }

                                Err(error) => {
                                    send(&mut port, &format!("error {error}"))?;
                                }
                            }
                        }

                        Err(error) => {
                            send(&mut port, &format!("error {error}"))?;
                        }
                    }
                }

                Err(_) => {
                    send(&mut port, "error invalid-appid")?;
                }
            }

            continue;
        }

        if request == "steam-games" {
            send_games(&mut port)?;
            continue;
        }

        // 41F-21C.2: static, read-only Proton runtime attestation.
        if let Some(raw) = request.strip_prefix("proton-attest ") {
            match raw.parse::<u32>() {
                Ok(app_id) => {
                    let (state, evidence) = proton_attestation_for_app(app_id);
                    send(&mut port, &format!("proton-attest {app_id} {state} {evidence}"))?;
                }
                Err(_) => send(&mut port, "error invalid-appid")?,
            }
            continue;
        }

        if let Some(value) = request.strip_prefix("proton-runtime ") {
            match value.parse::<u32>() {
                Ok(app_id) => match proton_runtime_for_app(app_id) {
                    Ok(Some(runtime)) => {
                        send(
                            &mut port,
                            &format!(
                                "proton-runtime {app_id} {}",
                                encode_field(&runtime.to_string_lossy())
                            ),
                        )?;
                    }

                    Ok(None) => {
                        send(&mut port, &format!("proton-runtime {app_id} none"))?;
                    }

                    Err(error) => {
                        send(&mut port, &format!("error {error}"))?;
                    }
                },

                Err(_) => {
                    send(&mut port, "error invalid-appid")?;
                }
            }

            continue;
        }

        if let Some(rest) = request.strip_prefix("reloadedii-setup ") {
            let Some((raw_app_id, encoded_path)) = rest.split_once(' ') else {
                send(&mut port, "error invalid-reloadedii-setup")?;
                continue;
            };

            if encoded_path.is_empty() || encoded_path.contains(' ') {
                send(&mut port, "error invalid-reloadedii-setup")?;
                continue;
            }

            match raw_app_id.parse::<u32>() {
                Ok(app_id) => match run_reloadedii_setup(app_id, encoded_path) {
                    Ok(exit_code) => {
                        send(
                            &mut port,
                            &format!(
                                "reloadedii-setup-result \
                                     {app_id} {exit_code}"
                            ),
                        )?;
                    }

                    Err(error) => {
                        send(&mut port, &format!("error {error}"))?;
                    }
                },

                Err(_) => {
                    send(&mut port, "error invalid-appid")?;
                }
            }

            continue;
        }


        if let Some(value) = request.strip_prefix("proton-inspect ") {
            match value.parse::<u32>() {
                Ok(app_id) => match inspect_proton_environment(app_id) {
                    Ok(response) => send(&mut port, &response)?,
                    Err(error) => send(&mut port, &format!("error {error}"))?,
                },
                Err(_) => send(&mut port, "error invalid-appid")?,
            }

            continue;
        }

        if let Some(value) = request.strip_prefix("proton-prefix ") {
            match value.parse::<u32>() {
                Ok(app_id) => {
                    if let Some(prefix) = proton_prefix(app_id) {
                        send(
                            &mut port,
                            &format!(
                                "proton-prefix {app_id} {}",
                                encode_field(&prefix.to_string_lossy())
                            ),
                        )?;
                    } else {
                        send(&mut port, &format!("proton-prefix {app_id} none"))?;
                    }
                }
                Err(_) => {
                    send(&mut port, "error invalid-appid")?;
                }
            }

            continue;
        }

        if handle_mod_launch_request(&mut port, request)? {
            continue;
        }

        if handle_fs_request(&mut port, request)? {
            continue;
        }

        send(&mut port, "error unsupported-request")?;
    }
}


// 41F-20C.2: Read-only metadata wire representation.
//
// This serializes only fields explicitly validated by the
// Reloaded-II metadata parser. No enabled/loaded state is inferred.

fn reloadedii_metadata_payload(
    metadata: &reloadedii_metadata::ModMetadata,
) -> Result<String, String> {
    let json = serde_json::json!({
        "ModId": metadata.mod_id,
        "ModName": metadata.mod_name,
        "ModAuthor": metadata.author,
        "ModVersion": metadata.version,
        "ModDescription": metadata.description,
        "SupportedAppId": metadata.supported_app_ids,
        "IsUniversalMod": metadata.is_universal,
    });

    let serialized = serde_json::to_string(&json)
        .map_err(|_| "metadata-serialization-failed".to_string())?;

    let encoded = encode_field(&serialized);

    // Bound the encoded JSON independently of individual fields.
    // A long supported-ID array must not create an oversized line.
    if encoded.len() > 12 * 1024 {
        return Err("metadata-response-too-large".into());
    }

    Ok(encoded)
}

fn reloadedii_metadata_record(
    config: &std::path::Path,
) -> Result<String, String> {
    let encoded_path = encode_field(&config.to_string_lossy());

    // 41F-20C.4: Never emit an error frame inside an inventory.
    if encoded_path.len() > 2048 {
        return Err("metadata-path-too-long".to_string());
    }

    match reloadedii_metadata::read_config(config) {
        Ok(metadata) => match reloadedii_metadata_payload(&metadata) {
            Ok(payload) => {
                let record = format!(
                    "reloadedii-metadata-item {encoded_path} parsed {payload}"
                );

                if record.len() > 15 * 1024 {
                    Ok(format!(
                        "reloadedii-metadata-item {encoded_path} invalid \
                         metadata-response-too-large"
                    ))
                } else {
                    Ok(record)
                }
            }

            Err(error) => Ok(format!(
                "reloadedii-metadata-item {encoded_path} invalid {}",
                encode_field(&error)
            )),
        },

        Err(error) => Ok(format!(
            "reloadedii-metadata-item {encoded_path} invalid {}",
            encode_field(&error)
        )),
    }
}


// 41F-20C.4: Metadata protocol framing tests.
#[cfg(test)]
mod reloadedii_metadata_wire_tests {
    use super::{
        reloadedii_metadata_payload,
        reloadedii_metadata_record,
    };
    use std::path::Path;

    #[test]
    fn oversized_path_is_a_protocol_error() {
        let path = format!("/tmp/{}/ModConfig.json", "x".repeat(2100));

        let result = reloadedii_metadata_record(Path::new(&path));

        assert_eq!(
            result.unwrap_err(),
            "metadata-path-too-long"
        );
    }

    #[test]
    fn nonexistent_config_produces_framed_invalid_record() {
        let path = Path::new(
            "/tmp/bepis-41f20c4-nonexistent/ModConfig.json"
        );

        let record = reloadedii_metadata_record(path)
            .expect("bounded path must produce a record");

        assert!(
            record.starts_with("reloadedii-metadata-item "),
            "{record}"
        );

        assert!(
            record.contains(" invalid "),
            "{record}"
        );

        assert!(
            !record.starts_with("error "),
            "{record}"
        );
    }

    #[test]
    fn oversized_path_prevents_batch_construction() {
        let valid = Path::new(
            "/tmp/bepis-41f20c4-nonexistent/ModConfig.json"
        );

        let oversized = format!(
            "/tmp/{}/ModConfig.json",
            "x".repeat(2100)
        );

        let paths = [
            valid,
            Path::new(&oversized),
        ];

        let records: Result<Vec<String>, String> = paths
            .iter()
            .map(|path| reloadedii_metadata_record(path))
            .collect();

        assert_eq!(
            records.unwrap_err(),
            "metadata-path-too-long"
        );
    }

    #[test]
    fn serialized_metadata_is_bounded() {
        let metadata = super::reloadedii_metadata::ModMetadata {
            mod_id: "test.mod".to_string(),
            mod_name: "Test Mod".to_string(),
            author: "Test Author".to_string(),
            version: "1.0".to_string(),
            description: "Test description".to_string(),
            supported_app_ids: vec!["1984270".to_string()],
            is_universal: false,
        };

        let payload = reloadedii_metadata_payload(&metadata)
            .expect("valid metadata should serialize");

        assert!(payload.len() <= 12 * 1024);
        assert!(!payload.contains('\n'));
        assert!(!payload.contains(' '));
    }
}

fn main() {
    loop {
        match open_port() {
            Ok(port) => {
                if let Err(error) = serve(port) {
                    eprintln!("fx-bepis-agent: {error}");
                }
            }
            Err(error) => {
                // The service can start before the virtio port is visible.
                eprintln!("fx-bepis-agent: waiting for {PORT}: {error}");
            }
        }

        thread::sleep(Duration::from_secs(1));
    }
}
