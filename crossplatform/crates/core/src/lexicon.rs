use regex::Regex;
use std::fs;
use std::path::Path;

/// One dictionary entry: a term to spell exactly, or a deterministic rewrite.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum LexiconEntry {
    Term(String),
    Rewrite { from: String, to: String },
}

/// The dictionary concept: get names and jargon right. Terms bias polish; rewrites are applied
/// deterministically after it. Entries are only ever added explicitly. Same file as the macOS app.
#[derive(Clone, Default, Debug)]
pub struct Lexicon {
    pub terms: Vec<String>,
    pub rewrites: Vec<(String, String)>,
}

pub const FILE_HEADER: &str = "# hearsay dictionary — one entry per line.\n\
#\n\
#   mprocs             a term: prefer this exact spelling when you say something close\n\
#   mprox -> mprocs    a rewrite: the left side always becomes the right side\n\
#\n\
# Lines starting with # are ignored. The dictionary is read fresh at every dictation.\n\
# Managed by the Dictionary pane: your own comments below this header are not kept.\n\n";

impl Lexicon {
    pub fn from_entries(entries: &[LexiconEntry]) -> Self {
        let mut lexicon = Lexicon::default();
        for entry in entries {
            match entry {
                LexiconEntry::Term(t) => lexicon.terms.push(t.clone()),
                LexiconEntry::Rewrite { from, to } => lexicon.rewrites.push((from.clone(), to.clone())),
            }
        }
        lexicon
    }

    pub fn load(path: &Path) -> Self {
        Self::from_entries(&entries(path))
    }

    /// Applies the rewrites (case-insensitive, word-bounded). None when nothing matched.
    pub fn rewrite_result(&self, text: &str) -> Option<String> {
        let mut result = text.to_string();
        for (from, to) in &self.rewrites {
            let pattern = format!(r"(?i)\b{}\b", regex::escape(from));
            if let Ok(re) = Regex::new(&pattern) {
                result = re.replace_all(&result, regex::NoExpand(to)).into_owned();
            }
        }
        if result == text { None } else { Some(result) }
    }
}

pub fn parse(content: &str) -> Vec<LexiconEntry> {
    let mut out = Vec::new();
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((from, to)) = line.split_once("->") {
            let (from, to) = (from.trim(), to.trim());
            if !from.is_empty() && !to.is_empty() {
                out.push(LexiconEntry::Rewrite { from: from.to_string(), to: to.to_string() });
            }
        } else {
            out.push(LexiconEntry::Term(line.to_string()));
        }
    }
    out
}

pub fn entries(path: &Path) -> Vec<LexiconEntry> {
    fs::read_to_string(path).map(|c| parse(&c)).unwrap_or_default()
}

pub fn save(entries: &[LexiconEntry], path: &Path) {
    let mut content = FILE_HEADER.to_string();
    for entry in entries {
        match entry {
            LexiconEntry::Term(t) => content.push_str(&format!("{t}\n")),
            LexiconEntry::Rewrite { from, to } => content.push_str(&format!("{from} -> {to}\n")),
        }
    }
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let _ = fs::write(path, content);
    crate::keystore::restrict_permissions(path);
}

pub fn ensure_file(path: &Path) {
    if !path.exists() {
        save(&[], path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_terms_and_rewrites() {
        let entries = parse("# c\nmprocs\nmprox -> mprocs\n\n read me -> Readme \n");
        assert_eq!(entries, vec![
            LexiconEntry::Term("mprocs".into()),
            LexiconEntry::Rewrite { from: "mprox".into(), to: "mprocs".into() },
            LexiconEntry::Rewrite { from: "read me".into(), to: "Readme".into() },
        ]);
    }

    #[test]
    fn rewrites_are_word_bounded_and_case_insensitive() {
        let lexicon = Lexicon::from_entries(&parse("mprox -> mprocs\nread me -> Readme"));
        assert_eq!(lexicon.rewrite_result("run Mprox and read me now").as_deref(), Some("run mprocs and Readme now"));
        assert_eq!(lexicon.rewrite_result("approximate"), None);
    }
}
