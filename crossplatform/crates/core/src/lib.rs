//! The concepts of hearsay with no platform dependency. Mechanisms (audio, hotkeys, insertion,
//! inference) live in other crates and reach these concepts only through the traits defined here.

pub mod bakeoff;
pub mod engine;
pub mod history;
pub mod keystore;
pub mod lexicon;
pub mod paths;
pub mod polish;
pub mod scorer;
pub mod session;
pub mod wav;
