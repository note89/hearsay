use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// API keys for the optional cloud engines: process environment first, then `keys.env` in the
/// support directory, then the shell profiles. Values are never logged.
pub struct KeyStore {
    file: PathBuf,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum KeySource {
    Environment,
    KeysFile,
    ShellProfile(PathBuf),
}

impl KeySource {
    pub fn label(&self) -> String {
        match self {
            KeySource::Environment => "found in the environment".into(),
            KeySource::KeysFile => "saved in keys.env".into(),
            KeySource::ShellProfile(path) => format!("found in {}", path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()),
        }
    }
}

/// The files people `export` keys in. None on Windows, where user variables are already in the environment.
fn shell_profiles() -> Vec<PathBuf> {
    if cfg!(windows) {
        return Vec::new();
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else { return Vec::new() };
    [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"].iter().map(|name| home.join(name)).collect()
}

impl KeyStore {
    pub fn new(dir: &Path) -> Self {
        Self { file: dir.join("keys.env") }
    }

    pub fn file_path(&self) -> &Path {
        &self.file
    }

    pub fn value(&self, name: &str) -> Option<String> {
        self.lookup(name).map(|(value, _)| value)
    }

    /// Where a key was found, for the pane. Never the value.
    pub fn source(&self, name: &str) -> Option<KeySource> {
        self.lookup(name).map(|(_, source)| source)
    }

    /// Process environment, then `keys.env`, then the shell profiles most people export keys in.
    fn lookup(&self, name: &str) -> Option<(String, KeySource)> {
        if let Ok(env) = std::env::var(name) {
            if !env.is_empty() {
                return Some((env, KeySource::Environment));
            }
        }
        if let Some(value) = fs::read_to_string(&self.file).ok().and_then(|c| parse_env(&c).remove(name)) {
            return Some((value, KeySource::KeysFile));
        }
        for profile in shell_profiles() {
            if let Some(value) = fs::read_to_string(&profile).ok().and_then(|c| parse_env(&c).remove(name)) {
                return Some((value, KeySource::ShellProfile(profile)));
            }
        }
        None
    }

    /// Writes `NAME=value` into `keys.env` (0600), replacing an existing line for that name.
    pub fn set(&self, name: &str, value: &str) -> std::io::Result<()> {
        if let Some(dir) = self.file.parent() {
            fs::create_dir_all(dir)?;
        }
        let existing = fs::read_to_string(&self.file).unwrap_or_else(|_| TEMPLATE.to_string());
        let mut lines: Vec<String> = existing.lines().map(str::to_string).collect();
        let is_this_key = |line: &str| {
            let line = line.trim();
            let line = line.strip_prefix("export ").unwrap_or(line);
            line.split('=').next().map(str::trim) == Some(name)
        };
        match lines.iter().position(|l| is_this_key(l)) {
            Some(index) => lines[index] = format!("{name}={value}"),
            None => lines.push(format!("{name}={value}")),
        }
        fs::write(&self.file, lines.join("\n") + "\n")?;
        restrict_permissions(&self.file);
        Ok(())
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
# https://openrouter.ai/keys — unlocks Gemini 3.7 Flash and cloud cleanup:\n\
OPENROUTER_API_KEY=\n\
\n\
# https://aistudio.google.com/apikey — unlocks Gemini 3.5 Transcribe Live:\n\
GEMINI_API_KEY=\n\
\n\
# https://elevenlabs.io — unlocks ElevenLabs Scribe v2:\n\
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
