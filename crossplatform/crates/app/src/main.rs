//! hearsay for Linux & Windows. `hearsay-rs` opens the app; `hearsay-rs transcribe file.wav`
//! runs an engine on a file; `hearsay-rs insert TEXT` pastes the way a dictation would.

mod app;
mod cli;
mod panes;
mod settings;

fn main() {
    env_logger::init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("transcribe") => cli::transcribe(args.get(1).map(String::as_str), args.get(2).map(String::as_str)),
        Some("engines") => cli::engines(),
        Some("insert") => cli::insert(args.get(1).map(String::as_str)),
        _ => {
            let options = eframe::NativeOptions {
                viewport: egui::ViewportBuilder::default().with_title("hearsay").with_inner_size([920.0, 640.0]).with_min_inner_size([760.0, 520.0]),
                ..Default::default()
            };
            if let Err(e) = eframe::run_native("hearsay", options, Box::new(|cc| Ok(Box::new(app::App::new(cc))))) {
                eprintln!("hearsay-rs: {e}");
                std::process::exit(1);
            }
        }
    }
}
