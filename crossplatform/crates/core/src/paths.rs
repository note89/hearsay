use std::path::PathBuf;

/// Where hearsay keeps its files: the platform data directory, named plainly `hearsay` so it is the
/// same folder the macOS app uses (`~/Library/Application Support/hearsay`) — history, dictionary,
/// keys and bake-off runs are portable between the two apps.
pub fn support_dir() -> PathBuf {
    if let Some(dirs) = directories::ProjectDirs::from("", "", "hearsay") {
        dirs.data_dir().to_path_buf()
    } else {
        PathBuf::from(".hearsay")
    }
}
