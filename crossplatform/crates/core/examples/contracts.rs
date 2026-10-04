//! A JSONL adapter over production code for cross-port verification, never a network client.
use hearsay_core::{
    lexicon::{Lexicon, LexiconEntry},
    polish::{PolishGuard, PolishVerdict},
};
use serde::Deserialize;
use serde_json::json;
use std::io::{self, BufRead};

// Include the production source to reach its crate-private token-distance function without
// publishing an API solely for this test adapter.
#[allow(dead_code)]
#[path = "../src/scorer.rs"]
mod scorer;

#[derive(Deserialize)]
struct Rule {
    from: String,
    to: String,
}

#[derive(Deserialize)]
struct Case {
    reference: String,
    hypothesis: String,
    rewrites: Vec<Rule>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    for line in io::stdin().lock().lines() {
        let input: Case = serde_json::from_str(&line?)?;
        let reference = scorer::normalize(&input.reference);
        let hypothesis = scorer::normalize(&input.hypothesis);
        let dictionary = Lexicon::from_entries(
            &input
                .rewrites
                .into_iter()
                .map(|rule| LexiconEntry::Rewrite {
                    from: rule.from,
                    to: rule.to,
                })
                .collect::<Vec<_>>(),
        );
        let verdict = match PolishGuard::verdict(&input.reference, &input.hypothesis) {
            PolishVerdict::Accept(text) => format!("accept:{}", text.text()),
            PolishVerdict::KeepRaw(reason) => format!("reject:{}", reason.label()),
        };
        println!(
            "{}",
            json!({
                "referenceTokens": reference,
                "hypothesisTokens": hypothesis,
                "distance": scorer::edit_distance(&reference, &hypothesis),
                "wer": scorer::wer(&input.reference, &input.hypothesis),
                "diff": scorer::diff(&input.reference, &input.hypothesis).into_iter().map(|segment| {
                    json!({"text": segment.text, "wrong": segment.verdict == scorer::DiffVerdict::Wrong})
                }).collect::<Vec<_>>(),
                "rewrite": dictionary.rewrite_result(&input.hypothesis),
                "polish": verdict,
            })
        );
    }
    Ok(())
}
