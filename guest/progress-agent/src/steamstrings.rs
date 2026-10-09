//! Steam bootstrapper progress messages in any Steam UI language.
//!
//! The bootstrapper writes the messages of its progress window to
//! logs/bootstrap_log.txt in the Steam UI language (registry.vdf
//! HKCU/Software/Valve/Steam/language), e.g. with Russian:
//!   "Загрузка обновления (493,215 из 564,334 КБ)..."
//! while its plain log lines ("Verification complete", "Nothing to do", ...)
//! stay English (matched in main.rs).
//!
//! The texts come from <steam root>/public/steambootstrapper_<language>.txt,
//! shipped with every client (Valve KeyValues):
//!   "Tokens" { "SteamBootstrapper_UpdateDownloading" "Загрузка обновления (%bytes% из %size% КБ)..." ... }
//! Every language found there is loaded - the current one first, then English,
//! then the others - so a line of any language maps back to its message and an
//! ambiguous text resolves to the current language. The English table is also
//! built in: the files appear only once Steam has been unpacked. A download
//! line of a language without a table (or with a changed text) still yields
//! its numbers from its shape (`parse_download_any`).

use std::path::PathBuf;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Msg {
    Verifying,
    Checking,
    /// "Downloading update..." (before the sizes are known).
    DownloadStarting,
    /// (done, total) in KB.
    Downloading(u64, u64),
    Downloaded,
    Extracting,
    Installing,
    CleaningUp,
    UpdateComplete,
}

/// Message keys of interest with their English text (as in
/// public/steambootstrapper_english.txt). `Downloading(0, 0)` stands for the
/// download line; its numbers come from %bytes% / %size%.
const KEYS: &[(&str, Msg, &str)] = &[
    (
        "SteamBootstrapper_InstallVerify",
        Msg::Verifying,
        "Verifying installation...",
    ),
    (
        "SteamBootstrapper_UpdateChecking",
        Msg::Checking,
        "Checking for available updates...",
    ),
    (
        "SteamBootstrapper_UpdateDownload",
        Msg::DownloadStarting,
        "Downloading update...",
    ),
    (
        "SteamBootstrapper_UpdateDownloading",
        Msg::Downloading(0, 0),
        "Downloading update (%bytes% of %size% KB)...",
    ),
    (
        "SteamBootstrapper_DownloadComplete",
        Msg::Downloaded,
        "Download complete.",
    ),
    (
        "SteamBootstrapper_UpdateExtractingPackage",
        Msg::Extracting,
        "Extracting package...",
    ),
    (
        "SteamBootstrapper_UpdateInstalling",
        Msg::Installing,
        "Installing update...",
    ),
    (
        "SteamBootstrapper_UpdateCleanup",
        Msg::CleaningUp,
        "Cleaning up...",
    ),
    (
        "SteamBootstrapper_UpdateComplete",
        Msg::UpdateComplete,
        "Update complete, launching %appname%...",
    ),
];

/// Retry interval for loading the language files while they do not exist yet.
const RETRY: Duration = Duration::from_secs(2);

#[derive(Debug, PartialEq)]
enum Part {
    Lit(String),
    /// %name%: any non-empty text.
    Var(String),
}

struct Template {
    msg: Msg,
    parts: Vec<Part>,
}

pub struct Messages {
    steam_root: PathBuf,
    registry: PathBuf,
    /// Lookup order: current language, English, other languages.
    table: Vec<Template>,
    loaded: bool,
    next_try: Instant,
}

impl Messages {
    /// `steam_root`: ~/.local/share/Steam; `registry`: ~/.steam/registry.vdf.
    pub fn new(steam_root: impl Into<PathBuf>, registry: impl Into<PathBuf>) -> Messages {
        Messages {
            steam_root: steam_root.into(),
            registry: registry.into(),
            table: builtin(),
            loaded: false,
            next_try: Instant::now(),
        }
    }

    /// The bootstrapper message `text` (a log line without its time stamp) is.
    pub fn classify(&mut self, text: &str) -> Option<Msg> {
        if !self.loaded && Instant::now() >= self.next_try {
            self.next_try = Instant::now() + RETRY;
            self.load();
        }
        lookup(&self.table, text)
            .or_else(|| parse_download_any(text).map(|(d, t)| Msg::Downloading(d, t)))
    }

    fn load(&mut self) {
        let lang = std::fs::read_to_string(&self.registry)
            .ok()
            .and_then(|s| registry_language(&s));
        let Ok(dir) = std::fs::read_dir(self.steam_root.join("public")) else {
            return;
        };
        let mut files: Vec<(u8, String, PathBuf)> = dir
            .flatten()
            .filter_map(|e| {
                let name = e.file_name().into_string().ok()?;
                let l = name
                    .strip_prefix("steambootstrapper_")?
                    .strip_suffix(".txt")?
                    .to_ascii_lowercase();
                let rank = if Some(&l) == lang.as_ref() {
                    0
                } else if l == "english" {
                    1
                } else {
                    2
                };
                Some((rank, l, e.path()))
            })
            .collect();
        if files.is_empty() {
            return;
        }
        files.sort();
        let mut table = Vec::new();
        let mut builtin_added = false;
        for (rank, _, path) in &files {
            if *rank == 2 && !builtin_added {
                table.extend(builtin());
                builtin_added = true;
            }
            if let Ok(s) = std::fs::read_to_string(path) {
                table.extend(parse_strings(&s));
            }
        }
        if !builtin_added {
            table.extend(builtin());
        }
        eprintln!(
            "fx-progress: bootstrapper messages: {} languages, current {}",
            files.len(),
            lang.as_deref().unwrap_or("unknown")
        );
        self.table = table;
        self.loaded = true;
    }
}

fn builtin() -> Vec<Template> {
    KEYS.iter()
        .filter_map(|&(_, msg, text)| {
            Some(Template {
                msg,
                parts: compile(text)?,
            })
        })
        .collect()
}

/// The message templates of one steambootstrapper_<language>.txt.
fn parse_strings(text: &str) -> Vec<Template> {
    let mut out = Vec::new();
    kv_for_each(text, |path, key, value| {
        if !path
            .last()
            .is_some_and(|p| p.eq_ignore_ascii_case("Tokens"))
        {
            return;
        }
        if let Some(&(_, msg, _)) = KEYS.iter().find(|(k, _, _)| k.eq_ignore_ascii_case(key)) {
            if let Some(parts) = compile(value) {
                out.push(Template { msg, parts });
            }
        }
    });
    out
}

fn lookup(table: &[Template], text: &str) -> Option<Msg> {
    let text = text.trim();
    for t in table {
        let mut caps = Vec::new();
        if matches(&t.parts, text, &mut caps) {
            return Some(match t.msg {
                Msg::Downloading(..) => {
                    let var = |name: &str| {
                        caps.iter()
                            .find(|(n, _)| *n == name)
                            .and_then(|(_, v)| digits(v))
                    };
                    match (var("bytes"), var("size")) {
                        (Some(done), Some(total)) => Msg::Downloading(done, total),
                        // Template without the expected placeholders: the numbers by shape.
                        _ => match parse_download_any(text) {
                            Some((d, t)) => Msg::Downloading(d, t),
                            None => continue,
                        },
                    }
                }
                m => m,
            });
        }
    }
    None
}

/// "%appname% is ... %percent%%%" -> parts; `%%` is a literal percent sign.
/// None for templates this matcher cannot handle (two adjacent variables).
fn compile(text: &str) -> Option<Vec<Part>> {
    let text = text.trim();
    let mut parts: Vec<Part> = Vec::new();
    let mut lit = String::new();
    let mut rest = text;
    while let Some(i) = rest.find('%') {
        lit.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        if let Some(r) = after.strip_prefix('%') {
            lit.push('%');
            rest = r;
            continue;
        }
        let name_len = after
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
            .unwrap_or(after.len());
        if name_len > 0 && after[name_len..].starts_with('%') {
            if !lit.is_empty() {
                parts.push(Part::Lit(std::mem::take(&mut lit)));
            } else if matches!(parts.last(), Some(Part::Var(_))) {
                return None;
            }
            parts.push(Part::Var(after[..name_len].to_string()));
            rest = &after[name_len + 1..];
        } else {
            lit.push('%');
            rest = after;
        }
    }
    lit.push_str(rest);
    if !lit.is_empty() {
        parts.push(Part::Lit(lit));
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts)
    }
}

fn matches<'a>(parts: &'a [Part], text: &'a str, caps: &mut Vec<(&'a str, &'a str)>) -> bool {
    match parts.split_first() {
        None => text.is_empty(),
        Some((Part::Lit(l), rest)) => text
            .strip_prefix(l.as_str())
            .is_some_and(|t| matches(rest, t, caps)),
        Some((Part::Var(name), rest)) => match rest.first() {
            // Last part: the rest of the line.
            None => {
                caps.push((name.as_str(), text));
                !text.is_empty()
            }
            Some(Part::Lit(next)) => {
                for (i, _) in text.match_indices(next.as_str()) {
                    if i == 0 {
                        continue;
                    }
                    let n = caps.len();
                    caps.push((name.as_str(), &text[..i]));
                    if matches(rest, &text[i..], caps) {
                        return true;
                    }
                    caps.truncate(n);
                }
                false
            }
            Some(Part::Var(_)) => false, // rejected by compile()
        },
    }
}

/// All ASCII digits of `s` as one number ("493,215" -> 493215).
fn digits(s: &str) -> Option<u64> {
    let d: String = s.chars().filter(char::is_ascii_digit).collect();
    d.parse().ok()
}

/// Download line of any language by its shape: the line ends with a
/// parenthesised group (ASCII or full-width parentheses), followed only by an
/// ellipsis / full stop, that holds exactly two numbers (any digit grouping):
///   "Загрузка обновления (493,215 из 564,334 КБ)..."
///   "更新をダウンロード中（12,514 / 662,547 KB）..."
/// -> (smaller, larger) = (done, total) in KB.
pub fn parse_download_any(text: &str) -> Option<(u64, u64)> {
    let s = text.trim().trim_end_matches(['.', '…', '。', ' ']);
    let s = s.strip_suffix(')').or_else(|| s.strip_suffix('）'))?;
    let open = s.rfind(['(', '（'])?;
    let group = &s[open..];
    let nums = numbers(group);
    match nums[..] {
        [a, b] if a.max(b) > 0 => Some((a.min(b), a.max(b))),
        _ => None,
    }
}

/// Stand-alone numbers in `s`: digits with optional thousands groups
/// ("1,234,567", "1.234.567", "1 234 567", "1'234'567"); a digit run glued to
/// a word ("linuxarm64", "v2") is not a number.
fn numbers(s: &str) -> Vec<u64> {
    const SEPS: &[char] = &[',', '.', '\'', '’', ' ', '\u{a0}', '\u{202f}', '\u{2009}'];
    let chars: Vec<char> = s.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let glued = i > 0 && {
            let p = chars[i - 1];
            p.is_ascii_alphanumeric() || matches!(p, '_' | '.' | ',' | '/' | '\\' | '-' | ':')
        };
        if !c.is_ascii_digit() || glued {
            i += 1;
            continue;
        }
        let mut value: Option<u64> = Some(0);
        let push =
            |v: Option<u64>, d: char| v?.checked_mul(10)?.checked_add(d.to_digit(10)? as u64);
        while i < chars.len() && chars[i].is_ascii_digit() {
            value = push(value, chars[i]);
            i += 1;
        }
        // Thousands groups: separator + exactly three digits.
        while i < chars.len() && SEPS.contains(&chars[i]) {
            let g = &chars[i + 1..(i + 4).min(chars.len())];
            let next_is_digit = chars.get(i + 4).is_some_and(char::is_ascii_digit);
            if g.len() == 3 && g.iter().all(char::is_ascii_digit) && !next_is_digit {
                for &d in g {
                    value = push(value, d);
                }
                i += 4;
            } else {
                break;
            }
        }
        if let Some(v) = value {
            out.push(v);
        }
    }
    out
}

/// HKCU/Software/Valve/Steam/language of ~/.steam/registry.vdf.
fn registry_language(text: &str) -> Option<String> {
    let mut lang = None;
    kv_for_each(text, |path, key, value| {
        let n = path.len();
        if key.eq_ignore_ascii_case("language")
            && n >= 2
            && path[n - 2].eq_ignore_ascii_case("Valve")
            && path[n - 1].eq_ignore_ascii_case("Steam")
            && !value.is_empty()
        {
            lang = Some(value.to_ascii_lowercase());
        }
    });
    lang
}

/// Calls `f(enclosing block names, key, value)` for every key/value pair of a
/// Valve KeyValues text (quoted or bare tokens, `{ }` blocks, `//` comments,
/// `[$PLATFORM]` conditionals ignored).
fn kv_for_each(text: &str, mut f: impl FnMut(&[String], &str, &str)) {
    let mut path: Vec<String> = Vec::new();
    let mut key: Option<String> = None;
    let mut it = text.trim_start_matches('\u{feff}').chars().peekable();
    while let Some(c) = it.next() {
        match c {
            c if c.is_whitespace() => {}
            '/' if it.peek() == Some(&'/') => {
                for c in it.by_ref() {
                    if c == '\n' {
                        break;
                    }
                }
            }
            '[' => {
                for c in it.by_ref() {
                    if c == ']' || c == '\n' {
                        break;
                    }
                }
            }
            '{' => path.push(key.take().unwrap_or_default()),
            '}' => {
                path.pop();
                key = None;
            }
            _ => {
                let mut tok = String::new();
                if c == '"' {
                    while let Some(c) = it.next() {
                        match c {
                            '"' => break,
                            '\\' => match it.next() {
                                Some('n') => tok.push('\n'),
                                Some('t') => tok.push('\t'),
                                Some(o) => tok.push(o),
                                None => {}
                            },
                            o => tok.push(o),
                        }
                    }
                } else {
                    tok.push(c);
                    while let Some(&c) = it.peek() {
                        if c.is_whitespace() || matches!(c, '"' | '{' | '}') {
                            break;
                        }
                        tok.push(c);
                        it.next();
                    }
                }
                match key.take() {
                    None => key = Some(tok),
                    Some(k) => f(&path, &k, &tok),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Real localization files (public/steambootstrapper_<language>.txt of the
    /// Steam Deck ARM64 client 1788652215), reduced to the keys used here plus
    /// a few others, with their original layout (CRLF, bare English keys).
    const ENGLISH: &str = include_str!("../testdata/steambootstrapper_english.txt");
    const RUSSIAN: &str = include_str!("../testdata/steambootstrapper_russian.txt");
    const GERMAN: &str = include_str!("../testdata/steambootstrapper_german.txt");
    const JAPANESE: &str = include_str!("../testdata/steambootstrapper_japanese.txt");
    const SCHINESE: &str = include_str!("../testdata/steambootstrapper_schinese.txt");

    fn table(files: &[&str]) -> Vec<Template> {
        files.iter().flat_map(|f| parse_strings(f)).collect()
    }

    #[test]
    fn every_language_file_has_every_key() {
        for f in [ENGLISH, RUSSIAN, GERMAN, JAPANESE, SCHINESE] {
            let t = parse_strings(f);
            for &(key, msg, _) in KEYS {
                assert!(
                    t.iter().any(|t| t.msg == msg),
                    "{key} missing in {:?}",
                    f.lines().next()
                );
            }
        }
    }

    #[test]
    fn russian_lines_from_the_report() {
        // bootstrap_log.txt of Sentry feedback STEAMAC-W (Steam UI language Russian).
        let t = table(&[RUSSIAN]);
        let c = |s: &str| lookup(&t, s);
        assert_eq!(c("Проверка установки..."), Some(Msg::Verifying));
        assert_eq!(c("Загрузка обновления..."), Some(Msg::DownloadStarting));
        assert_eq!(c("Проверка на наличие обновлений..."), Some(Msg::Checking));
        assert_eq!(
            c("Загрузка обновления (493,215 из 564,334 КБ)..."),
            Some(Msg::Downloading(493215, 564334))
        );
        assert_eq!(c("Загрузка выполнена."), Some(Msg::Downloaded));
        assert_eq!(c("Разархивирование пакета..."), Some(Msg::Extracting));
        assert_eq!(c("Установка обновления..."), Some(Msg::Installing));
        assert_eq!(c("Очистка..."), Some(Msg::CleaningUp));
        assert_eq!(
            c("Обновление завершено, запуск Steam..."),
            Some(Msg::UpdateComplete)
        );
        // Plain log lines are not bootstrapper messages.
        assert_eq!(c("Verification complete"), None);
        assert_eq!(c("Manifest download: send request"), None);
    }

    #[test]
    fn german_lines() {
        let t = table(&[GERMAN]);
        let c = |s: &str| lookup(&t, s);
        assert_eq!(c("Installation wird überprüft …"), Some(Msg::Verifying));
        assert_eq!(c("Suche nach verfügbaren Updates …"), Some(Msg::Checking));
        assert_eq!(
            c("Update wird heruntergeladen (12.514 von 662.547 KB) …"),
            Some(Msg::Downloading(12514, 662547))
        );
        assert_eq!(c("Download ist abgeschlossen."), Some(Msg::Downloaded));
        assert_eq!(c("Paket wird extrahiert …"), Some(Msg::Extracting));
        assert_eq!(c("Update wird installiert …"), Some(Msg::Installing));
        assert_eq!(c("Bereinigen …"), Some(Msg::CleaningUp));
        assert_eq!(
            c("Aktualisierung abgeschlossen, Steam wird geladen …"),
            Some(Msg::UpdateComplete)
        );
    }

    #[test]
    fn japanese_and_chinese_lines() {
        let t = table(&[JAPANESE, SCHINESE]);
        let c = |s: &str| lookup(&t, s);
        assert_eq!(c("インストール状況を確認中..."), Some(Msg::Verifying));
        assert_eq!(c("更新を確認中..."), Some(Msg::Checking));
        assert_eq!(
            c("更新をダウンロード中（12,514 / 662,547 KB）..."),
            Some(Msg::Downloading(12514, 662547))
        );
        assert_eq!(c("ダウンロードが終了しました。"), Some(Msg::Downloaded));
        assert_eq!(
            c("更新が完了しました。Steam を起動します..."),
            Some(Msg::UpdateComplete)
        );
        assert_eq!(c("正在验证安装..."), Some(Msg::Verifying));
        assert_eq!(
            c("正在下载更新 (已下载 12,514，共 662,547 KB)..."),
            Some(Msg::Downloading(12514, 662547))
        );
        assert_eq!(c("正在展开安装包..."), Some(Msg::Extracting));
        assert_eq!(c("更新完成，正在启动 Steam..."), Some(Msg::UpdateComplete));
    }

    #[test]
    fn english_builtin() {
        let t = builtin();
        assert_eq!(
            lookup(&t, "Downloading update (12,514 of 662,547 KB)..."),
            Some(Msg::Downloading(12514, 662547))
        );
        assert_eq!(
            lookup(&t, "Downloading update..."),
            Some(Msg::DownloadStarting)
        );
        assert_eq!(
            lookup(&t, "Update complete, launching Steam..."),
            Some(Msg::UpdateComplete)
        );
        assert_eq!(
            lookup(&t, "Verifying installation..."),
            Some(Msg::Verifying)
        );
        assert_eq!(lookup(&t, "Verifying file sizes only"), None);
    }

    #[test]
    fn download_shape_fallback() {
        let d = parse_download_any;
        // Languages without a table, any digit grouping.
        assert_eq!(
            d("Загрузка обновления (493,215 из 564,334 КБ)..."),
            Some((493215, 564334))
        );
        assert_eq!(
            d("Téléchargement de la mise à jour (12 514 sur 662 547 Ko)…"),
            Some((12514, 662547))
        );
        assert_eq!(
            d("Mise à jour (12\u{202f}514 sur 662\u{202f}547 Ko)..."),
            Some((12514, 662547))
        );
        assert_eq!(
            d("更新をダウンロード中（12,514 / 662,547 KB）..."),
            Some((12514, 662547))
        );
        assert_eq!(d("Pobieranie (0 z 564334 KB)..."), Some((0, 564334)));
        // Size first in some language: still (done, total).
        assert_eq!(
            d("Download (564,334 KB: 493,215)..."),
            Some((493215, 564334))
        );
        // Not download lines.
        assert_eq!(d("uninstalled manifest found in /home/steamos/.local/share/Steam/package/steam_client_steamdeck_stable_linuxarm64 (1)."), None);
        assert_eq!(d("Saving metrics to disk (/home/steamos/.local/share/Steam/package/steam_client_metrics.bin)"), None);
        assert_eq!(d("1. https://client-update.fastly.steamstatic.com, /, Realm 'steamglobal', weight was 900, source = 'update_hosts_cached.vdf'"), None);
        assert_eq!(d("Startup - updater built Sep  1 2026 19:03:26"), None);
        assert_eq!(d("Downloading update..."), None);
    }

    #[test]
    fn current_language_and_files() {
        let dir = std::env::temp_dir().join(format!("fx-steamstrings-{}", std::process::id()));
        let public = dir.join("public");
        std::fs::create_dir_all(&public).unwrap();
        let registry = dir.join("registry.vdf");
        let mut m = Messages::new(&dir, &registry);
        // No files yet: built-in English and the download shape.
        assert_eq!(m.classify("Cleaning up..."), Some(Msg::CleaningUp));
        assert_eq!(m.classify("Очистка..."), None);
        assert_eq!(
            m.classify("Загрузка обновления (1,000 из 2,000 КБ)..."),
            Some(Msg::Downloading(1000, 2000))
        );

        std::fs::write(public.join("steambootstrapper_english.txt"), ENGLISH).unwrap();
        std::fs::write(public.join("steambootstrapper_russian.txt"), RUSSIAN).unwrap();
        std::fs::write(public.join("steambootstrapper_german.txt"), GERMAN).unwrap();
        std::fs::write(
            &registry,
            "\"Registry\"\n{\n\t\"HKCU\"\n\t{\n\t\t\"Software\"\n\t\t{\n\t\t\t\"Valve\"\n\t\t\t{\n\t\t\t\t\"Steam\"\n\t\t\t\t{\n\t\t\t\t\t\"language\"\t\t\"russian\"\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n",
        )
        .unwrap();
        m.next_try = Instant::now();
        assert_eq!(m.classify("Очистка..."), Some(Msg::CleaningUp));
        assert_eq!(m.classify("Bereinigen …"), Some(Msg::CleaningUp));
        assert_eq!(m.classify("Cleaning up..."), Some(Msg::CleaningUp));
        assert!(m.loaded);
        // Current language first in the table.
        assert!(matches!(&m.table[0].parts[0], Part::Lit(s) if !s.is_ascii()));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn registry() {
        let r = "\"Registry\"\n{\n\"HKLM\" { \"Software\" { \"Valve\" { \"Steam\" { \"SteamPID\" \"0\" } } } }\n\"HKCU\"\n{\n\"Software\"\n{\n\"Valve\"\n{\n\"Steamsteamglobal\" { \"language\" \"german\" }\n\"Steam\"\n{\n\"language\"\t\t\"Russian\"\n\"SourceModInstallPath\"\t\t\"/home/steamos/.local/share/Steam/steamapps\\\\sourcemods\"\n}\n}\n}\n}\n}\n";
        assert_eq!(registry_language(r).as_deref(), Some("russian"));
        assert_eq!(registry_language("\"Registry\" { }"), None);
    }

    #[test]
    fn templates() {
        assert_eq!(
            compile("%percent%%% complete"),
            Some(vec![
                Part::Var("percent".into()),
                Part::Lit("% complete".into())
            ])
        );
        // Two adjacent variables cannot be split: not used.
        assert!(compile("%a%%b%").is_none());
        assert_eq!(
            compile("100% done"),
            Some(vec![Part::Lit("100% done".into())])
        );
    }
}
