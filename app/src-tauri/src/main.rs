// The Review Map app. `reviewmap` starts it with the review as arguments; see `reviewmap_app::run`.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    reviewmap_app::run();
}
