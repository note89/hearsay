//! Word error rate and word-level diff over normalized tokens: numeral style ("700" vs "seven hundred"),
//! ordinals, units ("5ms"), contractions, typographic apostrophes and letter/digit boundaries ("HTTP2")
//! never count as errors. Port of the macOS `Scorer`; the two must agree so runs are comparable.

use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DiffVerdict {
    Match,
    Wrong,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct DiffSegment {
    pub text: String,
    pub verdict: DiffVerdict,
}

pub fn wer(reference: &str, hypothesis: &str) -> f64 {
    let r = normalize(reference);
    let h = normalize(hypothesis);
    if r.is_empty() {
        return if h.is_empty() { 0.0 } else { 1.0 };
    }
    edit_distance(&r, &h) as f64 / r.len() as f64
}

/// The hypothesis split into whitespace-preserving segments, wrong words marked.
pub fn diff(reference: &str, hypothesis: &str) -> Vec<DiffSegment> {
    let ref_tokens = normalize(reference);
    let parts = chunks(hypothesis);
    let mut hyp_tokens = Vec::new();
    let mut source = Vec::new();
    for (index, part) in parts.iter().enumerate() {
        if part.chars().all(char::is_whitespace) {
            continue;
        }
        for token in normalize_token(part) {
            hyp_tokens.push(token);
            source.push(index);
        }
    }
    let bad = bad_hypothesis_tokens(&ref_tokens, &hyp_tokens, &source);
    parts
        .into_iter()
        .enumerate()
        .map(|(index, text)| DiffSegment {
            verdict: if bad.contains(&index) { DiffVerdict::Wrong } else { DiffVerdict::Match },
            text,
        })
        .collect()
}

pub fn normalize(text: &str) -> Vec<String> {
    text.split_whitespace().flat_map(normalize_token).collect()
}

static DIGIT_COMMA: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(\d),(\d)").unwrap());
static PUNCT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^\p{L}\p{N}\s']").unwrap());
static ORDINAL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\d+)(st|nd|rd|th)$").unwrap());
static DIGIT_UNIT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\d+)([a-z]+)$").unwrap());

fn normalize_token(raw: &str) -> Vec<String> {
    let mut token = raw.to_lowercase().replace(['\u{2019}', '\u{02BC}'], "'").replace('%', " percent ");
    // "1,250" → "1250" (the regex crate has no lookahead; loop handles "1,250,000")
    loop {
        let next = DIGIT_COMMA.replace_all(&token, "$1$2").into_owned();
        if next == token {
            break;
        }
        token = next;
    }
    let token = PUNCT.replace_all(&token, " ").into_owned();
    let pieces: Vec<&str> = token.split_whitespace().collect();
    if pieces.len() != 1 {
        return pieces.into_iter().flat_map(normalize_token).collect();
    }
    let t = pieces[0].trim_matches('\'');
    if t.is_empty() {
        return Vec::new();
    }
    if let Some(expansion) = CONTRACTIONS.get(t) {
        return expansion.split(' ').map(String::from).collect();
    }
    if t.chars().all(|c| c.is_ascii_digit()) {
        if let Ok(n) = t.parse::<u64>() {
            return number_words(n).split(' ').map(String::from).collect();
        }
    }
    if let Some(caps) = ORDINAL.captures(t) {
        if let Ok(n) = caps[1].parse::<u64>() {
            return ordinal_words(n).split(' ').map(String::from).collect();
        }
    }
    if let Some(caps) = DIGIT_UNIT.captures(t) {
        if let (Ok(n), Some(unit)) = (caps[1].parse::<u64>(), UNITS.get(&caps[2])) {
            let mut words: Vec<String> = number_words(n).split(' ').map(String::from).collect();
            words.push((*unit).to_string());
            return words;
        }
    }
    if let Some(unit) = UNITS.get(t) {
        return vec![(*unit).to_string()];
    }
    if t.chars().any(char::is_alphabetic) && t.chars().any(char::is_numeric) {
        let parts = split_letter_digit_boundaries(t);
        if parts.len() > 1 {
            return parts.iter().flat_map(|p| normalize_token(p)).collect();
        }
    }
    vec![t.to_string()]
}

pub fn number_words(n: u64) -> String {
    if n >= 1000 {
        return n.to_string();
    }
    let n = n as usize;
    if n <= 20 {
        return ONES[n].to_string();
    }
    if n < 100 {
        let tens = TENS[n / 10];
        let rest = n % 10;
        return if rest == 0 { tens.to_string() } else { format!("{tens} {}", ONES[rest]) };
    }
    let hundreds = format!("{} hundred", ONES[n / 100]);
    let rest = n % 100;
    if rest == 0 { hundreds } else { format!("{hundreds} {}", number_words(rest as u64)) }
}

pub fn ordinal_words(n: u64) -> String {
    let words = number_words(n);
    let mut parts: Vec<&str> = words.split(' ').collect();
    let Some(last) = parts.pop() else { return n.to_string() };
    let ordinal = match ORDINALS.get(last) {
        Some(special) => (*special).to_string(),
        None if last.ends_with('y') => format!("{}ieth", &last[..last.len() - 1]),
        None => format!("{last}th"),
    };
    let mut out: Vec<String> = parts.iter().map(|p| p.to_string()).collect();
    out.push(ordinal);
    out.join(" ")
}

fn edit_distance(a: &[String], b: &[String]) -> usize {
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut current = vec![i];
        for j in 1..=b.len() {
            let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 };
            current.push((previous[j] + 1).min(current[j - 1] + 1).min(previous[j - 1] + cost));
        }
        previous = current;
    }
    previous[b.len()]
}

fn bad_hypothesis_tokens(reference: &[String], hypothesis: &[String], source: &[usize]) -> HashSet<usize> {
    let n = reference.len();
    let m = hypothesis.len();
    let mut dp = vec![vec![0usize; m + 1]; n + 1];
    for (i, row) in dp.iter_mut().enumerate() {
        row[0] = i;
    }
    for j in 0..=m {
        dp[0][j] = j;
    }
    for i in 1..=n {
        for j in 1..=m {
            let cost = if reference[i - 1] == hypothesis[j - 1] { 0 } else { 1 };
            dp[i][j] = (dp[i - 1][j] + 1).min(dp[i][j - 1] + 1).min(dp[i - 1][j - 1] + cost);
        }
    }
    let mut bad = HashSet::new();
    let (mut i, mut j) = (n, m);
    while i > 0 || j > 0 {
        if i > 0 && j > 0 {
            let cost = if reference[i - 1] == hypothesis[j - 1] { 0 } else { 1 };
            if dp[i][j] == dp[i - 1][j - 1] + cost {
                if cost == 1 {
                    bad.insert(source[j - 1]);
                }
                i -= 1;
                j -= 1;
                continue;
            }
        }
        if j > 0 && dp[i][j] == dp[i][j - 1] + 1 {
            bad.insert(source[j - 1]);
            j -= 1;
        } else {
            i -= 1;
        }
    }
    bad
}

fn chunks(text: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let mut current_is_space: Option<bool> = None;
    for c in text.chars() {
        let is_space = c.is_whitespace();
        match current_is_space {
            Some(prev) if prev != is_space => {
                result.push(std::mem::take(&mut current));
                current.push(c);
            }
            _ => current.push(c),
        }
        current_is_space = Some(is_space);
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

fn split_letter_digit_boundaries(token: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut last_is_digit: Option<bool> = None;
    for c in token.chars() {
        let is_digit = c.is_numeric();
        match last_is_digit {
            Some(prev) if prev != is_digit && (c.is_alphabetic() || c.is_numeric()) => {
                parts.push(std::mem::take(&mut current));
                current.push(c);
            }
            _ => current.push(c),
        }
        if c.is_alphabetic() || c.is_numeric() {
            last_is_digit = Some(is_digit); // punctuation must not mask a boundary
        }
    }
    if !current.is_empty() {
        parts.push(current);
    }
    parts
}

const ONES: [&str; 21] = ["zero","one","two","three","four","five","six","seven","eight","nine","ten","eleven","twelve","thirteen","fourteen","fifteen","sixteen","seventeen","eighteen","nineteen","twenty"];
const TENS: [&str; 10] = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];
static ORDINALS: LazyLock<HashMap<&'static str, &'static str>> = LazyLock::new(|| HashMap::from([("one","first"),("two","second"),("three","third"),("five","fifth"),("eight","eighth"),("nine","ninth"),("twelve","twelfth"),("twenty","twentieth")]));
static UNITS: LazyLock<HashMap<&'static str, &'static str>> = LazyLock::new(|| HashMap::from([("ms","milliseconds"),("s","seconds"),("min","minutes"),("h","hours"),("km","kilometers"),("kg","kilograms"),("gb","gigabytes"),("mb","megabytes"),("kb","kilobytes"),("hz","hertz"),("khz","kilohertz"),("mhz","megahertz"),("ghz","gigahertz"),("pm","pm"),("am","am")]));
static CONTRACTIONS: LazyLock<HashMap<&'static str, &'static str>> = LazyLock::new(|| HashMap::from([("won't","will not"),("can't","can not"),("don't","do not"),("doesn't","does not"),("didn't","did not"),("isn't","is not"),("aren't","are not"),("wasn't","was not"),("weren't","were not"),("haven't","have not"),("hasn't","has not"),("hadn't","had not"),("wouldn't","would not"),("shouldn't","should not"),("couldn't","could not"),("i'm","i am"),("i've","i have"),("i'll","i will"),("i'd","i would"),("you're","you are"),("you've","you have"),("you'll","you will"),("they're","they are"),("they've","they have"),("they'll","they will"),("we're","we are"),("we've","we have"),("we'll","we will"),("it's","it is"),("that's","that is"),("there's","there is"),("let's","let us"),("what's","what is"),("who's","who is"),("he's","he is"),("she's","she is"),("here's","here is")]));

#[cfg(test)]
mod tests {
    use super::*;

    fn zero(r: &str, h: &str) {
        assert_eq!(wer(r, h), 0.0, "{r} vs {h}");
    }

    #[test]
    fn style_variants_are_free() {
        zero("their deployment won't work there", "their deployment will not work there");
        zero("we enabled HTTP/2 today", "we enabled HTTP2 today");
        zero("the p99 latency spiked", "the p 99 latency spiked");
        zero("totals €1,250 plus 23% VAT", "totals 1250 plus 23 percent VAT");
        zero("plus 23% VAT", "plus twenty three percent VAT");
        zero("bring 29 items", "bring twenty nine items");
        zero("wait 5ms then retry", "wait five milliseconds then retry");
        zero("spiked to 250ms after", "spiked to two hundred fifty milliseconds after");
        zero("the 2nd option on the 14th", "the second option on the fourteenth");
        zero("music from the 90's era", "music from the 90's era");
        zero("their deployment won't work there", "their deployment won\u{2019}t work there");
        zero("before Thursday's demo", "before Thursday\u{2019}s demo");
        zero("say hello now", "say 'hello' now");
        zero("hello", "' hello");
    }

    #[test]
    fn real_errors_count() {
        assert!(wer("the cache is stale", "the cash is stale") > 0.0);
        assert!(wer("refactor the parseTranscript function", "refactor the parse transcript function") > 0.0);
        assert!(wer("the cache is stale", "the cache stale") > 0.0);
    }

    #[test]
    fn diff_agrees_with_wer() {
        for (r, h) in [("wait 5ms for HTTP/2", "wait five milliseconds for HTTP2"), ("plus 23% VAT", "plus twenty three percent VAT"), ("the 2nd option", "the second option"), ("the 90's", "the 90's")] {
            assert_eq!(wer(r, h), 0.0);
            assert!(diff(r, h).iter().all(|s| s.verdict == DiffVerdict::Match), "{r}");
        }
        let marked: Vec<String> = diff("the cache is stale", "the cash is stale").into_iter().filter(|s| s.verdict == DiffVerdict::Wrong).map(|s| s.text).collect();
        assert_eq!(marked, vec!["cash".to_string()]);
        let pct: Vec<String> = diff("fifty", "50%").into_iter().filter(|s| s.verdict == DiffVerdict::Wrong).map(|s| s.text).collect();
        assert_eq!(pct, vec!["50%".to_string()]);
        let joined: String = diff("a list: one two", "a list:\n- one\n- two").into_iter().map(|s| s.text).collect();
        assert_eq!(joined, "a list:\n- one\n- two");
    }

    #[test]
    fn number_tables() {
        assert_eq!(number_words(23), "twenty three");
        assert_eq!(number_words(250), "two hundred fifty");
        assert_eq!(number_words(1250), "1250");
        assert_eq!(ordinal_words(14), "fourteenth");
        assert_eq!(ordinal_words(20), "twentieth");
    }
}
