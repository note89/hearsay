use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// API keys for the optional cloud engines: process environment first, then `keys.env` in the
/// support directory. Values are never logged.
pub struct KeyStore {
    file: PathBuf,
}

impl KeyStore {
    pub fn new(dir: &Path) -> Self {
        Self { file: dir.join("keys.env") }
    }

    pub fn file_path(&self) -> &Path {
        &self.file
    }

    pub fn value(&self, name: &str) -> Option<String> {
        if let Ok(env) = std::env::var(name) {
            if !env.is_empty() {
                return Some(env);
            }
        }
        let content = fs::read_to_string(&self.file).ok()?;
        parse_env(&content).remove(name)
    }

    /// Creates the file with a commented template when missing, so "API Keys…" always opens something editable.
    pub fn ensure_file(&self) -> PathBuf {
        if !self.file.exists() {
            if let Some(dir) = self.file.parent() {
                let _ = fs::create_dir_all(dir);
            }
            let _ = fs::write(&self.file, TEMPLATE);
            restrict_permissions(&self.file);
        }
        self.file.clone()
    }
}

const TEMPLATE: &str = "# hearsay API keys — needed only for the optional cloud engines.\n\
# The default engine runs on this machine and uses no key and no network.\n\
\n\
# https://openrouter.ai/keys — unlocks the Gemini engines and cloud polish:\n\
OPENROUTER_API_KEY=\n\
\n\
# https://elevenlabs.io — unlocks ElevenLabs Scribe:\n\
ELEVEN_LABS_API_KEY=\n";

/// `NAME=value` lines; `export` prefix, quotes and trailing comments tolerated; exact-name match only.
pub fn parse_env(content: &str) -> HashMap<String, String> {
    let mut values = HashMap::new();
    for raw in content.lines() {
        let mut line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("export ") {
            line = rest.trim_start();
        }
        let Some((name, value)) = line.split_once('=') else { continue };
        let value = value.split('#').next().unwrap_or("").trim().trim_matches(|c| c == '"' || c == '\'');
        if !value.is_empty() {
            values.insert(name.trim().to_string(), value.to_string());
        }
    }
    values
}

pub fn restrict_permissions(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
}

#[cfg(test)]
mod tests {
    use super::parse_env;

    #[test]
    fn exact_name_only() {
        let env = parse_env("LEGACY_OPENROUTER_API_KEY=old\nexport OPENROUTER_API_KEY=\"real\" # note\n");
        assert_eq!(env.get("OPENROUTER_API_KEY").map(String::as_str), Some("real"));
        assert_eq!(env.get("LEGACY_OPENROUTER_API_KEY").map(String::as_str), Some("old"));
    }

    #[test]
    fn empty_and_comments_ignored() {
        let env = parse_env("# comment\nEMPTY=\n\nX=1\n");
        assert!(!env.contains_key("EMPTY"));
        assert_eq!(env.get("X").map(String::as_str), Some("1"));
    }
}
