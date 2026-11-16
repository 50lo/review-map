//! The app's menu bar: Tauri's default menu, plus File → New Review…, File → Export Notes…, Edit → Copy
//! Notes as Markdown and View → Show Name-Matched Comparison. The UI decides what these items do and when
//! they are enabled: a click is sent to it as the `menu` event, and it reports its state back with
//! `set_menu_state`.
//!
//! The rest is the default menu item for item, so the app menu (About, Hide, Quit) and the Edit menu (copy
//! and paste in the web view) behave as before. Quit stays the predefined item, which ends the app through
//! `RunEvent::Exit`, where the review's processes and the Bazel servers are stopped.

use serde::{Deserialize, Serialize};
use tauri::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu, HELP_SUBMENU_ID, WINDOW_SUBMENU_ID};
use tauri::{AppHandle, Emitter, Manager, Runtime};

pub const NEW_REVIEW: &str = "new-review";
pub const COMPARE_NAME_BASED: &str = "compare-name-based";
pub const EXPORT_NOTES: &str = "export-notes";
pub const COPY_NOTES: &str = "copy-notes";
/// The items whose clicks go to the UI.
const OWN: [&str; 4] = [NEW_REVIEW, COMPARE_NAME_BASED, EXPORT_NOTES, COPY_NOTES];
const EVENT: &str = "menu";

#[derive(Clone, Serialize)]
struct Clicked {
    id: String,
}

/// What the UI reports: which items can be used now, and whether the comparison report is on screen.
/// `has_notes` is true when a review is open and it has at least one note: the two notes items need both.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MenuState {
    pub can_start_new: bool,
    pub can_compare: bool,
    pub name_based: bool,
    pub has_notes: bool,
}

/// The items whose state the UI sets.
pub struct AppMenu<R: Runtime> {
    new_review: MenuItem<R>,
    compare: CheckMenuItem<R>,
    export_notes: MenuItem<R>,
    copy_notes: MenuItem<R>,
}

impl<R: Runtime> AppMenu<R> {
    pub fn apply(&self, state: MenuState) -> tauri::Result<()> {
        self.new_review.set_enabled(state.can_start_new)?;
        self.compare.set_enabled(state.can_compare)?;
        self.export_notes.set_enabled(state.has_notes)?;
        self.copy_notes.set_enabled(state.has_notes)?;
        // macOS flips a check item's mark when it is clicked; the UI's state is what counts.
        self.compare.set_checked(state.name_based)
    }
}

/// Builds the menu bar, sets it on the app and keeps its own items in the app's state. They start disabled,
/// until the UI says otherwise.
pub fn install<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    let pkg = app.package_info();
    let config = app.config();
    let about = tauri::menu::AboutMetadata {
        name: Some(pkg.name.clone()),
        version: Some(pkg.version.to_string()),
        copyright: config.bundle.copyright.clone(),
        authors: config.bundle.publisher.clone().map(|p| vec![p]),
        ..Default::default()
    };
    let new_review = MenuItem::with_id(app, NEW_REVIEW, "New Review…", false, Some("CmdOrCtrl+N"))?;
    let compare = CheckMenuItem::with_id(app, COMPARE_NAME_BASED, "Show Name-Matched Comparison", false, false, None::<&str>)?;
    let export_notes = MenuItem::with_id(app, EXPORT_NOTES, "Export Notes…", false, Some("CmdOrCtrl+E"))?;
    let copy_notes = MenuItem::with_id(app, COPY_NOTES, "Copy Notes as Markdown", false, Some("CmdOrCtrl+Shift+C"))?;
    let menu = Menu::with_items(
        app,
        &[
            #[cfg(target_os = "macos")]
            &Submenu::with_items(
                app,
                pkg.name.clone(),
                true,
                &[
                    &PredefinedMenuItem::about(app, None, Some(about))?,
                    &PredefinedMenuItem::separator(app)?,
                    &PredefinedMenuItem::services(app, None)?,
                    &PredefinedMenuItem::separator(app)?,
                    &PredefinedMenuItem::hide(app, None)?,
                    &PredefinedMenuItem::hide_others(app, None)?,
                    &PredefinedMenuItem::separator(app)?,
                    &PredefinedMenuItem::quit(app, None)?,
                ],
            )?,
            &Submenu::with_items(
                app,
                "File",
                true,
                &[
                    &new_review,
                    &PredefinedMenuItem::separator(app)?,
                    &export_notes,
                    &PredefinedMenuItem::separator(app)?,
                    &PredefinedMenuItem::close_window(app, None)?,
                    #[cfg(not(target_os = "macos"))]
                    &PredefinedMenuItem::quit(app, None)?,
                ],
            )?,
            &Submenu::with_items(
                app,
                "Edit",
                true,
                &[
                    &PredefinedMenuItem::undo(app, None)?,
                    &PredefinedMenuItem::redo(app, None)?,
                    &PredefinedMenuItem::separator(app)?,
                    &PredefinedMenuItem::cut(app, None)?,
                    &PredefinedMenuItem::copy(app, None)?,
                    &PredefinedMenuItem::paste(app, None)?,
                    &PredefinedMenuItem::select_all(app, None)?,
                    &PredefinedMenuItem::separator(app)?,
                    &copy_notes,
                ],
            )?,
            &Submenu::with_items(
                app,
                "View",
                true,
                &[
                    &compare,
                    #[cfg(target_os = "macos")]
                    &PredefinedMenuItem::separator(app)?,
                    #[cfg(target_os = "macos")]
                    &PredefinedMenuItem::fullscreen(app, None)?,
                ],
            )?,
            &Submenu::with_id_and_items(
                app,
                WINDOW_SUBMENU_ID,
                "Window",
                true,
                &[
                    &PredefinedMenuItem::minimize(app, None)?,
                    &PredefinedMenuItem::maximize(app, None)?,
                    #[cfg(target_os = "macos")]
                    &PredefinedMenuItem::separator(app)?,
                    &PredefinedMenuItem::close_window(app, None)?,
                ],
            )?,
            &Submenu::with_id_and_items(app, HELP_SUBMENU_ID, "Help", true, &[])?,
        ],
    )?;
    app.set_menu(menu)?;
    app.manage(AppMenu { new_review, compare, export_notes, copy_notes });
    Ok(())
}

/// Sends a click on one of the app's own items to the UI. Other items (the predefined ones) act by themselves.
pub fn on_event<R: Runtime>(app: &AppHandle<R>, event: MenuEvent) {
    let id = event.id().as_ref();
    if OWN.contains(&id) {
        let _ = app.emit(EVENT, Clicked { id: id.to_string() });
    }
}
