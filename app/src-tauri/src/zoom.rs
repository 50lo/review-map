//! The window's zoom: View → Zoom In (⌘=), Zoom Out (⌘-) and Actual Size (⌘0) scale everything in the
//! window, text and map alike, so the app reads comfortably on any display. The zoom is kept in the settings
//! (`"zoom": 1.25`) and applied again when the app starts.

use tauri::{AppHandle, Manager, Runtime};

/// The steps Zoom In and Zoom Out go through, as in Safari.
const LEVELS: [f64; 13] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];

/// The zoom after one step from `current`: the next level up (`dir` > 0) or down (`dir` < 0), or 1 for
/// `dir` == 0. A zoom between levels, set by hand in the settings, steps to the nearest level that way.
pub fn step(current: f64, dir: i32) -> f64 {
    const EPS: f64 = 0.001;
    match dir.signum() {
        1 => LEVELS.iter().copied().find(|&l| l > current + EPS).unwrap_or(LEVELS[LEVELS.len() - 1]),
        -1 => LEVELS.iter().rev().copied().find(|&l| l < current - EPS).unwrap_or(LEVELS[0]),
        _ => 1.0,
    }
}

/// A zoom read from the settings, kept within the levels; 1 when it is missing or not a number.
pub fn clamp(zoom: Option<f64>) -> f64 {
    match zoom {
        Some(z) if z.is_finite() => z.clamp(LEVELS[0], LEVELS[LEVELS.len() - 1]),
        _ => 1.0,
    }
}

/// Applies a zoom to the main window.
pub fn apply<R: Runtime>(app: &AppHandle<R>, zoom: f64) {
    let Some(window) = app.get_webview_window("main") else {
        crate::log("zoom: no main window");
        return;
    };
    if let Err(e) = window.set_zoom(zoom) {
        crate::log(format!("zoom: setting {zoom} failed: {e}"));
    }
}

/// One step of View → Zoom In, Zoom Out or Actual Size: applies it and keeps it in the settings.
pub fn change<R: Runtime>(app: &AppHandle<R>, dir: i32) {
    let zoom = step(clamp(crate::settings::load().zoom), dir);
    apply(app, zoom);
    crate::settings::set_zoom(zoom);
    crate::log(format!("ui: zoom {:.0}%", zoom * 100.0));
}
