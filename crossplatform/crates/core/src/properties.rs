use crate::engine::Engine;
use crate::lexicon::{parse, Lexicon};
use crate::polish::{
    PolishContext, PolishGuard, PolishIntensity, PolishRejection, PolishVerdict, Polisher,
    WritingStyle,
};
use crate::scorer::{diff, edit_distance, normalize, number_words, wer, DiffVerdict};
use crate::session::{deliver, InsertableText, PolishMode, RawTranscript, SessionRules};
use proptest::prelude::*;

fn words() -> impl Strategy<Value = Vec<String>> {
    let token = prop_oneof![
        "[a-zA-Z]{1,12}",
        (0u64..10000).prop_map(|n| n.to_string()),
        prop::sample::select(vec![
            "won't",
            "we’re",
            "90's",
            "HTTP2",
            "p99",
            "5ms",
            "23%",
            "1,250,000",
            "14th",
            "...",
            "'",
            "🙂",
            "åäö",
            "ação",
            "你好",
            "e\u{301}",
            "um",
            "uh",
            "",
        ])
        .prop_map(String::from),
    ];
    prop::collection::vec(token, 0..13)
}

#[test]
fn canonical_unicode_spellings_preserve_content() {
    assert!(matches!(
        PolishGuard::verdict("é ação", "e\u{301} ac\u{327}a\u{303}o"),
        PolishVerdict::Accept(_)
    ));
}

#[test]
fn numeric_normalization_uses_unsigned_64_bit_range() {
    assert_eq!(
        normalize("0009223372036854775808th"),
        vec!["9223372036854775808th"]
    );
    assert_eq!(
        normalize("00018446744073709551615ms"),
        vec!["18446744073709551615", "milliseconds"]
    );
    assert_eq!(
        normalize("18446744073709551616"),
        vec!["18446744073709551616"]
    );
}

fn rewrite(lexicon: &Lexicon, text: &str) -> String {
    lexicon
        .rewrite_result(text)
        .unwrap_or_else(|| text.to_owned())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(300))]

    #[test]
    fn normalization_is_idempotent(tokens in words()) {
        let normal = normalize(&tokens.join(" \t"));
        prop_assert_eq!(normalize(&normal.join(" ")), normal);
    }

    #[test]
    fn normalization_is_a_whitespace_concatenation_homomorphism(a in words(), b in words()) {
        let left = a.join(" ");
        let right = b.join(" ");
        let mut expected = normalize(&left);
        expected.extend(normalize(&right));
        prop_assert_eq!(normalize(&format!("{left}\n\t{right}")), expected);
    }

    #[test]
    fn diff_reconstructs_hypothesis_and_normalized_equivalence_is_free(tokens in words()) {
        let spoken = format!("\n {} \r\n", tokens.join("\t\n"));
        let normal = normalize(&spoken).join(" ");
        let segments = diff(&normal, &spoken);
        prop_assert_eq!(segments.iter().map(|s| s.text.as_str()).collect::<String>(), spoken.as_str());
        prop_assert!(segments.iter().all(|s| s.verdict == DiffVerdict::Match));
        prop_assert_eq!(wer(&normal, &spoken), 0.0);
    }

    #[test]
    fn edit_distance_obeys_metric_and_length_bounds(a in words(), b in words(), c in words()) {
        let ab = edit_distance(&a, &b);
        prop_assert_eq!(edit_distance(&a, &a), 0);
        prop_assert_eq!(ab, edit_distance(&b, &a));
        prop_assert!(ab >= a.len().abs_diff(b.len()));
        prop_assert!(ab <= a.len().max(b.len()));
        prop_assert!(edit_distance(&a, &c) <= ab + edit_distance(&b, &c));
    }

    #[test]
    fn number_rendering_normalizes_to_the_same_value(n in 0u64..10000) {
        prop_assert_eq!(normalize(&n.to_string()), normalize(&number_words(n)));
    }

    #[test]
    fn empty_dictionary_is_identity(tokens in words()) {
        prop_assert_eq!(Lexicon::default().rewrite_result(&tokens.join(" ")), None);
    }

    #[test]
    fn independent_rewrites_commute_and_are_idempotent(
        tokens in prop::collection::vec(prop::sample::select(vec!["Mprox", "key cloak", "invoice", "amprox", "key cloaks", "Keycloak"]), 0..16)
    ) {
        let forward = Lexicon::from_entries(&parse("mprox -> mprocs\nkey cloak -> Keycloak"));
        let reverse = Lexicon::from_entries(&parse("key cloak -> Keycloak\nmprox -> mprocs"));
        let text = tokens.join(" ");
        let result = rewrite(&forward, &text);
        prop_assert_eq!(&result, &rewrite(&reverse, &text));
        prop_assert_eq!(&result, &rewrite(&forward, &result));
    }

    #[test]
    fn rewriting_preserves_provenance_at_every_depth(layers in words()) {
        let raw = RawTranscript::from_engine(layers.join(" "));
        let mut text = InsertableText::Raw(raw.clone());
        for layer in layers {
            text = InsertableText::Rewritten { text: layer.clone(), over: Box::new(text) };
            prop_assert_eq!(text.spoken(), raw.text());
            prop_assert_eq!(text.text(), layer);
        }
    }

    #[test]
    fn meaningful_identity_and_filler_insertion_are_accepted(tokens in words()) {
        let spoken = format!("invoice {}", tokens.join(" ")).trim().to_owned();
        for input in [&spoken, &format!("um uh {spoken}")] {
            match PolishGuard::verdict(input, &format!("\n\t{spoken}\n")) {
                PolishVerdict::Accept(text) => prop_assert_eq!(text.text(), &spoken),
                verdict => prop_assert!(false, "identity rejected: {verdict:?}"),
            }
        }
    }

    #[test]
    fn disabled_polish_is_identity_with_dictionary_provenance(tokens in words()) {
        struct MustNotRun;
        impl Polisher for MustNotRun {
            fn polish(&self, _: &str, _: WritingStyle, _: PolishIntensity, _: &PolishContext) -> PolishVerdict {
                panic!("disabled polish invoked its model")
            }
        }
        let raw = RawTranscript::from_engine(format!("mprox {}", tokens.join(" ")));
        let rules = SessionRules {
            engine: Engine::default_engine(), style: WritingStyle::Plain, polish: PolishMode::Off,
            lexicon: Lexicon::from_entries(&parse("mprox -> mprocs")),
        };
        let expected = rewrite(&rules.lexicon, raw.text());
        let (text, rejection) = deliver(&rules, raw.clone(), &MustNotRun, &PolishContext::default());
        prop_assert_eq!(text.text(), expected);
        prop_assert_eq!(text.spoken(), raw.text());
        prop_assert!(rejection.is_none());
    }
}

#[test]
fn content_free_inputs_cannot_bypass_polish_guard() {
    for (spoken, candidate) in [
        ("um uh", "Buy a new laptop tomorrow."),
        ("send the invoice by friday", "..."),
        ("send the invoice by friday", "um uh"),
    ] {
        assert_eq!(
            PolishGuard::verdict(spoken, candidate),
            PolishVerdict::KeepRaw(PolishRejection::MeaningDrift)
        );
    }
}

#[test]
fn word_error_rate_is_directional_and_can_exceed_one() {
    assert_eq!(wer("invoice", "invoice cache friday"), 2.0);
    assert_eq!(wer("invoice cache friday", "invoice"), 2.0 / 3.0);
    assert_eq!(wer("", "invoice"), 1.0);
    assert_eq!(wer("", "..."), 0.0);
    assert!(wer("send the invoice", "send invoice") > 0.0);
    assert!(diff("send the invoice", "send invoice")
        .iter()
        .all(|s| s.verdict == DiffVerdict::Match));
}

#[test]
fn chained_rewrites_are_ordered_and_replacements_are_literal() {
    let forward = Lexicon::from_entries(&parse("a -> b\nb -> c"));
    let reverse = Lexicon::from_entries(&parse("b -> c\na -> b"));
    assert_eq!(rewrite(&forward, "a"), "c");
    assert_eq!(rewrite(&reverse, "a"), "b");
    assert_eq!(rewrite(&reverse, &rewrite(&reverse, "a")), "c");
    let literal = Lexicon::from_entries(&parse("a.b -> $1\\name"));
    assert_eq!(
        rewrite(&literal, "a.b axb za.b a.bz"),
        "$1\\name axb za.b a.bz"
    );
}
