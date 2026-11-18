//! Opening a file of the reviewed repository's working copy in the reviewer's editor.

use std::path::Path;

/// The command that opens a file at a line: a display name and its arguments, with {file} and {line} placeholders.
#[derive(Clone, Debug, PartialEq)]
pub struct Editor {
    pub name: String,
    pub args: Vec<String>,
}

fn preset(key: &str) -> Option<Editor> {
    let (name, args): (&str, &[&str]) = match key {
        "xcode" => ("Xcode", &["xed", "--line", "{line}", "{file}"]),
        "vscode" => ("VS Code", &["code", "-g", "{file}:{line}"]),
        "cursor" => ("Cursor", &["cursor", "-g", "{file}:{line}"]),
        "zed" => ("Zed", &["zed", "{file}:{line}"]),
        "idea" => ("IntelliJ IDEA", &["idea", "--line", "{line}", "{file}"]),
        "studio" => ("Android Studio", &["studio", "--line", "{line}", "{file}"]),
        _ => return None,
    };
    Some(Editor { name: name.to_string(), args: args.iter().map(|s| s.to_string()).collect() })
}

/// The editor from a setting: a preset name, or a command with {file} and {line}, split on spaces (so no
/// argument can contain one). Unset means Xcode.
pub fn from_setting(value: Option<&str>) -> Option<Editor> {
    let v = value.map(str::trim).filter(|v| !v.is_empty());
    let Some(v) = v else { return preset("xcode") };
    if let Some(p) = preset(&v.to_lowercase()) {
        return Some(p);
    }
    if !v.contains("{file}") {
        return None;
    }
    let args: Vec<String> = v.split_whitespace().map(str::to_string).collect();
    let name = args[0].rsplit('/').next().unwrap_or(&args[0]).to_string();
    Some(Editor { name, args })
}

/// `REVIEWMAP_EDITOR`, else the app's setting, else Xcode.
pub fn current() -> Option<Editor> {
    match std::env::var("REVIEWMAP_EDITOR") {
        Ok(v) if !v.trim().is_empty() => from_setting(Some(&v)),
        _ => from_setting(crate::settings::load().editor.as_deref()),
    }
}

/// Opens a file at a line. Only files inside the repository's working copy.
pub fn open(root: &Path, file: &str, line: u32) -> Result<String, String> {
    let editor = current().ok_or_else(|| "No editor is set: REVIEWMAP_EDITOR is neither a known editor nor a command with {file}.".to_string())?;
    let full = root.join(file);
    if !full.exists() {
        return Err(format!("{file} isn't in the working copy at {}.", root.display()));
    }
    let line = line.max(1).to_string();
    let args: Vec<String> = editor.args.iter().map(|a| a.replace("{file}", &full.to_string_lossy()).replace("{line}", &line)).collect();
    // A Finder launch has no shell PATH, so the editor's command is looked up in the usual places too.
    let program = reviewmap_core::tools::find(&args[0], None).ok_or_else(|| format!("{} was not found.", args[0]))?;
    std::process::Command::new(program)
        .args(&args[1..])
        .env("PATH", reviewmap_core::tools::child_path())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("{} failed: {e}", args[0]))?;
    Ok(format!("Opened in {}", editor.name))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings() {
        assert_eq!(from_setting(None).unwrap().name, "Xcode");
        assert_eq!(from_setting(Some("VSCode")).unwrap().args[0], "code");
        let custom = from_setting(Some("/usr/local/bin/subl {file}:{line}")).unwrap();
        assert_eq!((custom.name.as_str(), custom.args.len()), ("subl", 2));
        assert!(from_setting(Some("nonsense")).is_none());
    }
}
