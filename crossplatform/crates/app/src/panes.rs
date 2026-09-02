//! The settings window's panes: sections are concepts (Dictation · Dictionary · Style · Bake-off · History).

use crate::app::{App, EngineStatus, Phase};
use hearsay_core::bakeoff::{RivalOutcome, RunSummary, ScoredOutcome, SCRIPT};
use hearsay_core::engine::{Engine, PrivacyClass};
use hearsay_core::lexicon::{self, LexiconEntry};
use hearsay_core::scorer::{self, DiffVerdict};
use hearsay_core::session::PolishMode;

fn header(ui: &mut egui::Ui, title: &str, subtitle: &str) {
    ui.add_space(6.0);
    ui.heading(egui::RichText::new(title).size(24.0));
    ui.label(egui::RichText::new(subtitle).weak());
    ui.add_space(10.0);
}

fn card(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui)) {
    egui::Frame::group(ui.style()).corner_radius(10.0).inner_margin(12.0).show(ui, add);
}

pub fn dictation(app: &mut App, ui: &mut egui::Ui) {
    header(ui, "Dictation", "Hold Ctrl+Alt+Space anywhere. Release, and the words land at your cursor.");
    let keys_file = app.keys.file_path().display().to_string();
    let engines = Engine::all();
    let chosen = app.settings.engine;
    let mut newly_selected: Option<Engine> = None;
    for engine in engines {
        let available = engine.is_available(&app.keys);
        card(ui, |ui| {
            ui.horizontal(|ui| {
                ui.add_enabled_ui(available, |ui| {
                    if ui.radio(chosen == engine, engine.label()).clicked() && chosen != engine {
                        newly_selected = Some(engine);
                    }
                });
                match engine.privacy_class() {
                    PrivacyClass::OnDevice => { ui.label(egui::RichText::new("private").small().color(egui::Color32::LIGHT_GREEN)); }
                    PrivacyClass::Cloud => { ui.label(egui::RichText::new("cloud").small().color(egui::Color32::from_rgb(255, 166, 87))); }
                }
                if !available {
                    ui.label(egui::RichText::new("needs key").small().weak());
                }
            });
            ui.label(egui::RichText::new(engine.detail()).small().weak());
        });
    }
    if let Some(engine) = newly_selected {
        app.select_engine(engine);
    }
    ui.add_space(8.0);
    match app.engine_status {
        EngineStatus::MissingModel => {
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("This model is not downloaded yet.").color(egui::Color32::from_rgb(255, 166, 87)));
                if ui.button("Download model").clicked() {
                    app.download_model();
                }
            });
        }
        EngineStatus::Downloading => { ui.label("downloading model… (one-time, hundreds of MB)"); }
        EngineStatus::Loading => { ui.label("loading engine…"); }
        EngineStatus::Failed => { ui.label(egui::RichText::new(format!("engine failed: {}", app.engine_error)).color(egui::Color32::from_rgb(255, 123, 114))); }
        EngineStatus::Ready => { ui.label(egui::RichText::new("engine ready").color(egui::Color32::LIGHT_GREEN)); }
    }
    ui.add_space(12.0);
    ui.label(egui::RichText::new("API KEYS").small().strong());
    ui.label(egui::RichText::new(format!("Cloud engines read OPENROUTER_API_KEY / ELEVEN_LABS_API_KEY / GEMINI_API_KEY from the environment or from {keys_file}")).small().weak());
    if ui.button("Create keys file").clicked() {
        app.keys.ensure_file();
    }
    if let Some(error) = &app.gesture_error {
        ui.add_space(12.0);
        ui.label(egui::RichText::new(format!("Hotkey could not be registered: {error}")).color(egui::Color32::from_rgb(255, 123, 114)));
    }
    if let Some((ready, insert)) = app.last_timing {
        ui.add_space(12.0);
        ui.label(egui::RichText::new(format!("last: {ready} ms to text ready · {insert} ms insert")).small().weak());
    }
}

pub fn dictionary(app: &mut App, ui: &mut egui::Ui) {
    header(ui, "Dictionary", "Names and jargon, spelled your way. Terms guide cleanup (Style Light or Full); rewrites always apply.");
    let path = app.dictionary_path.clone();
    let mut entries = lexicon::entries(&path);
    let mut changed = false;
    let id = ui.id().with("dict-add");
    let mut from = ui.memory(|m| m.data.get_temp::<String>(id.with("from")).unwrap_or_default());
    let mut to = ui.memory(|m| m.data.get_temp::<String>(id.with("to")).unwrap_or_default());
    ui.horizontal(|ui| {
        ui.add(egui::TextEdit::singleline(&mut from).hint_text("word or phrase").desired_width(220.0));
        ui.label("→");
        ui.add(egui::TextEdit::singleline(&mut to).hint_text("rewrite to (optional)").desired_width(220.0));
        if ui.button("Add").clicked() && !from.trim().is_empty() {
            entries.push(if to.trim().is_empty() { LexiconEntry::Term(from.trim().into()) } else { LexiconEntry::Rewrite { from: from.trim().into(), to: to.trim().into() } });
            from.clear();
            to.clear();
            changed = true;
        }
    });
    ui.memory_mut(|m| { m.data.insert_temp(id.with("from"), from); m.data.insert_temp(id.with("to"), to); });
    ui.add_space(8.0);
    let mut remove: Option<usize> = None;
    for (index, entry) in entries.iter().enumerate() {
        ui.horizontal(|ui| {
            match entry {
                LexiconEntry::Term(t) => { ui.label(t); }
                LexiconEntry::Rewrite { from, to } => { ui.label(format!("{from} → {to}")); }
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.small_button("🗑").clicked() {
                    remove = Some(index);
                }
            });
        });
    }
    if let Some(index) = remove {
        entries.remove(index);
        changed = true;
    }
    if changed {
        lexicon::save(&entries, &path);
    }
    if entries.is_empty() {
        ui.label(egui::RichText::new("No entries yet.").weak());
    }
    ui.add_space(8.0);
    ui.label(egui::RichText::new(format!("Plain text file: {}", path.display())).small().weak());
}

pub fn style(app: &mut App, ui: &mut egui::Ui) {
    header(ui, "Style", "How much cleanup every dictation gets.");
    let has_polisher = app.keys.value("OPENROUTER_API_KEY").is_some();
    if !has_polisher {
        ui.label(egui::RichText::new("Cleanup on this platform uses an OpenRouter model (cloud, opt-in) until a local model ships — add OPENROUTER_API_KEY to enable Light/Full. Off keeps everything on this machine.").color(egui::Color32::from_rgb(255, 166, 87)));
        ui.add_space(6.0);
    }
    let sample = "hey um so send the, send the invoice by friday and uh maybe cc sara";
    let mut chosen = app.settings.polish;
    ui.horizontal_top(|ui| {
        for (mode, title, blurb, example) in [
            (PolishMode::Off, "Off", "Exactly what the engine heard, mistakes included.", sample.to_string()),
            (PolishMode::Light, "Light", "Punctuation, capitals, fillers gone. Your wording kept.", "Hey, so send the invoice by Friday and maybe cc Sara.".to_string()),
            (PolishMode::Full, "Full", "What you meant, dense: corrections applied, tightened, structured.", "Send the invoice by Friday; cc Sara.".to_string()),
        ] {
            let selected = chosen == mode;
            let enabled = mode == PolishMode::Off || has_polisher;
            ui.add_enabled_ui(enabled, |ui| {
                let frame = egui::Frame::group(ui.style()).corner_radius(10.0).inner_margin(12.0).stroke(if selected { egui::Stroke::new(1.5_f32, egui::Color32::LIGHT_BLUE) } else { ui.style().visuals.widgets.noninteractive.bg_stroke });
                let response = frame.show(ui, |ui| {
                    ui.set_width(200.0);
                    ui.label(egui::RichText::new(title).strong());
                    ui.label(egui::RichText::new(blurb).small().weak());
                    ui.add_space(8.0);
                    ui.label(egui::RichText::new(example).small().italics());
                });
                if response.response.interact(egui::Sense::click()).clicked() {
                    chosen = mode;
                }
            });
        }
    });
    if chosen != app.settings.polish {
        app.settings.polish = chosen;
        app.settings.save();
    }
    ui.add_space(12.0);
    ui.label(egui::RichText::new("Tone follows the app on macOS; on this platform the frontmost app is not detectable portably, so every dictation uses neutral prose.").small().weak());
}

pub fn bakeoff(app: &mut App, ui: &mut egui::Ui) {
    header(ui, "Bake-off", "Same audio, same key-up, one clock, every engine at once. Run a rival alongside. While this pane is front and the window focused, dictations score instead of inserting. Engines are scored on their raw text — Style is a separate concept.");
    let idle = matches!(app.phase, Phase::Idle | Phase::Settled(..));
    ui.horizontal_wrapped(|ui| {
        for engine in Engine::all() {
            let runnable = app.engine_is_runnable(engine);
            let racing = app.settings.is_racing(engine) && runnable;
            let label = if runnable { engine.short_label() } else { format!("{} · needs {}", engine.short_label(), if matches!(engine, Engine::Whisper(_)) { "model" } else { "key" }) };
            ui.add_enabled_ui(runnable && idle, |ui| {
                if ui.selectable_label(racing, label).clicked() {
                    app.settings.toggle_racing(engine);
                }
            });
        }
    });
    ui.horizontal(|ui| {
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui.add_enabled(idle && (!app.bakeoff.takes.is_empty() || app.bakeoff.archived_run_count() > 0), egui::Button::new("Delete all runs")).clicked() {
                app.bakeoff.delete_all_runs();
            }
            if ui.add_enabled(idle && !app.bakeoff.takes.is_empty(), egui::Button::new("Archive & reset run")).clicked() {
                app.bakeoff.reset_run();
            }
            if ui.add_enabled(idle && !app.bakeoff.takes.is_empty(), egui::Button::new("Retake last")).clicked() {
                app.bakeoff.delete_last();
            }
        });
    });
    ui.add_space(8.0);
    let position = app.bakeoff.takes.len();
    card(ui, |ui| {
        if let Some(sentence) = SCRIPT.get(position) {
            ui.label(egui::RichText::new(format!("sentence {} of {} · {}", position + 1, SCRIPT.len(), sentence.language)).small().weak());
            ui.label(egui::RichText::new(sentence.text).size(18.0).strong());
        } else {
            ui.label(egui::RichText::new(format!("🏁 run complete — {} sentences", SCRIPT.len())).size(18.0).strong());
        }
    });
    ui.add_space(8.0);
    ui.add(egui::TextEdit::multiline(&mut app.bakeoff_text).hint_text("click here, hold Ctrl+Alt+Space, read the sentence, release").desired_rows(4).desired_width(f32::INFINITY));
    ui.add_space(8.0);
    let summary = RunSummary::from_takes(&app.bakeoff.takes);
    ui.horizontal_wrapped(|ui| {
        for engine in &summary.leaderboard {
            card(ui, |ui| {
                let failed = if engine.failed > 0 { format!(" · {} failed", engine.failed) } else { String::new() };
                ui.label(egui::RichText::new(format!("{} — {} scored{failed}", name(&engine.engine_key).to_uppercase(), engine.scored)).small().weak());
                if engine.scored > 0 {
                    ui.label(egui::RichText::new(format!("{} · {} ms to text ready", percent(engine.mean_ours_wer), engine.mean_ours_ms)).strong().color(egui::Color32::LIGHT_GREEN));
                } else {
                    ui.label(egui::RichText::new("no text yet").strong().weak());
                }
                if engine.decided() > 0 {
                    let ties = if engine.ties > 0 { format!(" ({} tied)", engine.ties) } else { String::new() };
                    ui.label(egui::RichText::new(format!("vs rival {}–{}{ties} · rival {} · {} ms", engine.wins, engine.losses, percent(engine.mean_rival_wer), engine.mean_rival_ms)).small().color(egui::Color32::from_rgb(255, 166, 87)));
                }
            });
        }
    });
    if let Some(leader) = summary.leader().filter(|l| l.decided() >= 3) {
        let verdict = if leader.wins >= leader.losses {
            format!("🏆 {} leads at {} · {} ms, and beats the rival {}–{} — by WER only", name(&leader.engine_key), percent(leader.mean_ours_wer), leader.mean_ours_ms, leader.wins, leader.losses)
        } else {
            format!("{} leads our side at {}, but the rival wins {}–{} — by WER only", name(&leader.engine_key), percent(leader.mean_ours_wer), leader.losses, leader.wins)
        };
        ui.label(egui::RichText::new(verdict).strong());
    }
    ui.add_space(8.0);
    for (index, take) in summary.takes.iter().enumerate().rev() {
        card(ui, |ui| {
            ui.label(egui::RichText::new(format!("{}  {}", index + 1, take.expected)).strong());
            for result in &take.results {
                ui.horizontal_top(|ui| {
                    ui.label(egui::RichText::new(name(&result.engine)).small().color(egui::Color32::LIGHT_GREEN));
                    ui.vertical(|ui| match &result.outcome {
                        ScoredOutcome::Scored { ours, ms, wer } => {
                            ui.label(egui::RichText::new(format!("{} · {ms} ms", percent(*wer))).strong().color(egui::Color32::LIGHT_GREEN));
                            diff_text(ui, &take.expected, ours);
                        }
                        ScoredOutcome::Failed { reason } => {
                            ui.label(egui::RichText::new(reason).italics().weak());
                        }
                    });
                });
            }
            ui.horizontal_top(|ui| {
                ui.label(egui::RichText::new("rival").small().color(egui::Color32::from_rgb(255, 166, 87)));
                ui.vertical(|ui| match (&take.take.rival, take.rival_wer) {
                    (RivalOutcome::Landed { text, ms }, Some(wer)) => {
                        ui.label(egui::RichText::new(format!("{} · {ms} ms", percent(wer))).strong().color(egui::Color32::from_rgb(255, 166, 87)));
                        diff_text(ui, &take.expected, text);
                    }
                    (rival, _) => {
                        ui.label(egui::RichText::new(rival.status()).italics().weak());
                    }
                });
            });
        });
    }
}

fn name(engine_key: &str) -> String {
    Engine::parse(engine_key).map(|e| e.short_label()).unwrap_or_else(|| engine_key.to_string())
}

fn diff_text(ui: &mut egui::Ui, reference: &str, hypothesis: &str) {
    let mut job = egui::text::LayoutJob::default();
    for segment in scorer::diff(reference, hypothesis) {
        let color = if segment.verdict == DiffVerdict::Wrong { egui::Color32::from_rgb(255, 123, 114) } else { ui.style().visuals.weak_text_color() };
        job.append(&segment.text, 0.0, egui::TextFormat { font_id: egui::FontId::proportional(12.0), color, underline: if segment.verdict == DiffVerdict::Wrong { egui::Stroke::new(1.0_f32, color) } else { egui::Stroke::NONE }, ..Default::default() });
    }
    ui.label(job);
}

fn percent(value: f64) -> String {
    format!("{}%", (value * 100.0).round() as i64)
}

pub fn history(app: &mut App, ui: &mut egui::Ui) {
    header(ui, "History", "The trash of dictation — whatever didn't land is still here. Plain file, local, yours.");
    ui.horizontal(|ui| {
        if ui.checkbox(&mut app.settings.history_enabled, "Keep history").changed() {
            app.settings.save();
        }
        if ui.add_enabled(!app.history.records.is_empty(), egui::Button::new("Clear all")).clicked() {
            app.history.clear();
        }
    });
    ui.add_space(8.0);
    let mut delete: Option<String> = None;
    let mut copy: Option<String> = None;
    for record in &app.history.records {
        card(ui, |ui| {
            ui.label(&record.delivered);
            if record.spoken != record.delivered {
                ui.label(egui::RichText::new(format!("heard: {}", record.spoken)).small().weak());
            }
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new(format!("{} · {:?}", timestamp(record.at), record.outcome)).small().weak());
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.small_button("🗑").clicked() { delete = Some(record.id.clone()); }
                    if ui.small_button("copy").clicked() { copy = Some(record.delivered.clone()); }
                });
            });
        });
    }
    if app.history.records.is_empty() {
        ui.label(egui::RichText::new("Nothing yet.").weak());
    }
    if let Some(id) = delete { app.history.delete(&id); }
    if let Some(text) = copy { app.copy_text(&text); }
}

fn timestamp(secs: f64) -> String {
    let s = secs as u64;
    let (h, m) = ((s / 3600) % 24, (s / 60) % 60);
    let days = s / 86400;
    format!("day {days} {h:02}:{m:02} UTC")
}
