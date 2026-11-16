//! Where a target's build setting is written, so that its review item shows the setting's line and not
//! the first line of the target's manifest. TypeScript settings are JSON keys ("package.json <field>" is a
//! top-level field, "tsconfig <option>" a key of `compilerOptions`); every other key is an attribute of a
//! Bazel rule.

/// The 1-based lines of `key` in `text`, the file that sets it: from the key to the end of its value, which
/// may span lines (a list of `copts`, an `exports` map). `rule_line` is the line of the Bazel rule that
/// declares the target, when known.
pub fn setting_lines(text: &str, key: &str, rule_line: Option<u32>) -> Option<(u32, u32)> {
    if let Some(field) = key.strip_prefix("package.json ") {
        return json_key_lines(text, &[field]);
    }
    if let Some(option) = key.strip_prefix("tsconfig ") {
        return json_key_lines(text, &["compilerOptions", option]);
    }
    rule_attribute_lines(text, key, rule_line?)
}

/// Skips whitespace and comments from `i`, counting lines. Returns the next index.
fn skip_space(b: &[u8], mut i: usize, line: &mut u32) -> usize {
    while i < b.len() {
        match b[i] {
            b'\n' => {
                *line += 1;
                i += 1;
            }
            b' ' | b'\t' | b'\r' => i += 1,
            b'/' if b.get(i + 1) == Some(&b'/') => {
                while i < b.len() && b[i] != b'\n' {
                    i += 1;
                }
            }
            b'/' if b.get(i + 1) == Some(&b'*') => {
                i += 2;
                while i < b.len() && !(b[i] == b'*' && b.get(i + 1) == Some(&b'/')) {
                    if b[i] == b'\n' {
                        *line += 1;
                    }
                    i += 1;
                }
                i += 2;
            }
            _ => break,
        }
    }
    i
}

/// The last line of the JSON value that starts at or after `i` (after a key's colon).
fn value_end_line(b: &[u8], i: usize, mut line: u32) -> u32 {
    let mut i = skip_space(b, i, &mut line);
    if b.get(i) == Some(&b':') {
        i = skip_space(b, i + 1, &mut line);
    }
    let mut depth = 0usize;
    while i < b.len() {
        match b[i] {
            // A number, `true`, `false` or `null` ends at the first space.
            b'\n' | b' ' | b'\t' | b'\r' if depth == 0 => return line,
            b'\n' => line += 1,
            b'"' => {
                i += 1;
                while i < b.len() && b[i] != b'"' {
                    if b[i] == b'\\' {
                        i += 1;
                    }
                    i += 1;
                }
                if depth == 0 {
                    return line;
                }
            }
            b'/' if b.get(i + 1) == Some(&b'/') || b.get(i + 1) == Some(&b'*') => {
                i = skip_space(b, i, &mut line);
                continue;
            }
            b'{' | b'[' => depth += 1,
            b'}' | b']' => {
                if depth <= 1 {
                    return line;
                }
                depth -= 1;
            }
            b',' if depth == 0 => return line,
            _ => {}
        }
        i += 1;
    }
    line
}

/// The lines of the object key at `path` (from the top-level object) and its value, in JSON with comments,
/// as tsconfig allows. A key of the same name at another depth, or inside an array, is not it.
pub fn json_key_lines(text: &str, path: &[&str]) -> Option<(u32, u32)> {
    if path.is_empty() {
        return None;
    }
    let b = text.as_bytes();
    let mut line = 1u32;
    let mut i = 0;
    // Each open container: whether it is an object, and whether it lies on `path` (an object reached
    // through path[..depth]).
    let mut stack: Vec<(bool, bool)> = Vec::new();
    // The key whose value comes next in the innermost object, when it is on `path`.
    let mut on_path_key = false;
    let mut expect_key = false;
    while i < b.len() {
        let c = b[i];
        match c {
            b'\n' => line += 1,
            b'/' if b.get(i + 1) == Some(&b'/') => {
                while i < b.len() && b[i] != b'\n' {
                    i += 1;
                }
                continue;
            }
            b'/' if b.get(i + 1) == Some(&b'*') => {
                i += 2;
                while i < b.len() && !(b[i] == b'*' && b.get(i + 1) == Some(&b'/')) {
                    if b[i] == b'\n' {
                        line += 1;
                    }
                    i += 1;
                }
                i += 2;
                continue;
            }
            b'"' => {
                let start = i + 1;
                i += 1;
                while i < b.len() && b[i] != b'"' {
                    if b[i] == b'\\' {
                        i += 1;
                    } else if b[i] == b'\n' {
                        line += 1;
                    }
                    i += 1;
                }
                let s = &text[start..i.min(b.len())];
                let in_object = stack.last().map(|(o, _)| *o).unwrap_or(false);
                if in_object && expect_key {
                    let depth = stack.len();
                    let parent_on_path = stack.last().map(|(_, p)| *p).unwrap_or(false);
                    on_path_key = parent_on_path && depth <= path.len() && s == path[depth - 1];
                    if on_path_key && depth == path.len() {
                        return Some((line, value_end_line(b, i + 1, line)));
                    }
                    expect_key = false;
                }
            }
            b'{' | b'[' => {
                let is_object = c == b'{';
                // The top-level object is on the path; a nested one only through the path's key.
                let on_path = is_object && (stack.is_empty() || on_path_key);
                stack.push((is_object, on_path));
                on_path_key = false;
                expect_key = is_object;
            }
            b'}' | b']' => {
                stack.pop();
                on_path_key = false;
                expect_key = false;
            }
            b',' => {
                on_path_key = false;
                expect_key = stack.last().map(|(o, _)| *o).unwrap_or(false);
            }
            b':' => expect_key = false,
            _ => {}
        }
        i += 1;
    }
    None
}

/// The lines of attribute `attr` and its value in the rule call that starts on `rule_line` of a BUILD file.
pub fn rule_attribute_lines(text: &str, attr: &str, rule_line: u32) -> Option<(u32, u32)> {
    let lines: Vec<&str> = text.lines().collect();
    let first = (rule_line as usize).checked_sub(1)?;
    let mut depth = 0i32;
    let mut opened = false;
    let mut found: Option<u32> = None;
    for (n, l) in lines.iter().enumerate().skip(first) {
        if opened && depth == 1 && found.is_none() {
            let t = l.trim_start();
            if let Some(rest) = t.strip_prefix(attr) {
                let rest = rest.trim_start();
                if rest.starts_with('=') && !rest.starts_with("==") {
                    found = Some(n as u32 + 1);
                }
            }
        }
        let mut quote: Option<char> = None;
        let mut escaped = false;
        for ch in l.chars() {
            if let Some(q) = quote {
                if escaped {
                    escaped = false;
                } else if ch == '\\' {
                    escaped = true;
                } else if ch == q {
                    quote = None;
                }
                continue;
            }
            match ch {
                '#' => break,
                '"' | '\'' => quote = Some(ch),
                '(' | '[' | '{' => {
                    depth += 1;
                    opened = true;
                }
                ')' | ']' | '}' => depth -= 1,
                _ => {}
            }
        }
        // The attribute's value ends on the line that brings the call back to its own level.
        if let Some(start) = found {
            if depth <= 1 {
                return Some((start, n as u32 + 1));
            }
        }
        if opened && depth <= 0 {
            return None;
        }
    }
    found.map(|start| (start, lines.len() as u32))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PACKAGE: &str = r#"{
  "name": "@shop/core",
  "exports": {
    ".": { "types": "./dist/index.d.ts" }
  },
  "files": ["types"],
  "types": "./dist/index.d.ts"
}"#;

    #[test]
    fn a_package_field_is_the_top_level_key() {
        assert_eq!(setting_lines(PACKAGE, "package.json types", None), Some((7, 7)));
        assert_eq!(setting_lines(PACKAGE, "package.json exports", None), Some((3, 5)));
        assert_eq!(setting_lines(PACKAGE, "package.json files", None), Some((6, 6)));
        assert_eq!(setting_lines(PACKAGE, "package.json main", None), None);
    }

    #[test]
    fn a_tsconfig_option_is_a_key_of_compiler_options() {
        let tsconfig = r#"{
  // "noEmit": false, in a comment
  /* "compilerOptions": { "noEmit": 1 } */
  "extends": "./base.json",
  "noEmit": "not an option here",
  "compilerOptions": {
    "paths": { "noEmit": ["x"] },
    "strict": true,
    "lib": [
      "ES2022", // "noEmit"
      "DOM"
    ],
    "noEmit": true
  }
}"#;
        assert_eq!(setting_lines(tsconfig, "tsconfig noEmit", None), Some((13, 13)));
        assert_eq!(setting_lines(tsconfig, "tsconfig strict", None), Some((8, 8)));
        assert_eq!(setting_lines(tsconfig, "tsconfig paths", None), Some((7, 7)));
        assert_eq!(setting_lines(tsconfig, "tsconfig lib", None), Some((9, 12)));
    }

    #[test]
    fn a_bazel_attribute_is_found_in_its_rule() {
        let build = r#"load("@rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "Other",
    copts = ["-O"],
)

swift_library(
    name = "Core",
    srcs = glob(["Sources/**/*.swift"]),  # copts = ["x"]
    deps = [
        ":Other",
    ],
    copts = [
        "-strict-concurrency=complete",
    ],
)
"#;
        assert_eq!(setting_lines(build, "copts", Some(8)), Some((14, 16)));
        assert_eq!(setting_lines(build, "copts", Some(3)), Some((5, 5)));
        assert_eq!(setting_lines(build, "defines", Some(8)), None);
        assert_eq!(setting_lines(build, "copts", None), None);
    }
}
