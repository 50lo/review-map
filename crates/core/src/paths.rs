//! Small repo-relative path helpers shared by the analyzer.

/// "a/b/c.swift" -> "a/b"; "c.swift" -> "".
pub fn parent(path: &str) -> &str {
    match path.rfind('/') {
        Some(i) => &path[..i],
        None => "",
    }
}

/// The last component of a path.
pub fn file_name(path: &str) -> &str {
    match path.rfind('/') {
        Some(i) => &path[i + 1..],
        None => path,
    }
}

/// Joins two repo-relative parts; "" and "." are the root.
pub fn join(a: &str, b: &str) -> String {
    if a.is_empty() || a == "." {
        return b.to_string();
    }
    if b.is_empty() {
        return a.to_string();
    }
    format!("{a}/{b}")
}

/// Whether `path` is `dir` or inside it. An empty `dir` is the root and contains everything.
pub fn is_under(path: &str, dir: &str) -> bool {
    dir.is_empty() || dir == "." || path == dir || (path.len() > dir.len() && path.starts_with(dir) && path.as_bytes()[dir.len()] == b'/')
}

/// `path` relative to `dir`, when it is inside it.
pub fn strip_dir<'a>(path: &'a str, dir: &str) -> Option<&'a str> {
    if dir.is_empty() || dir == "." {
        return Some(path);
    }
    if path.len() > dir.len() && path.starts_with(dir) && path.as_bytes()[dir.len()] == b'/' {
        Some(&path[dir.len() + 1..])
    } else {
        None
    }
}

/// Test folders (`Tests`, `FooTests`, `__tests__`, `test`, `e2e`) and test files (`cart.test.ts`, `cart.spec.ts`).
pub fn is_test_path(p: &str) -> bool {
    let parts: Vec<&str> = p.split('/').filter(|s| !s.is_empty()).collect();
    if parts.iter().any(|s| matches!(*s, "test" | "tests" | "__tests__" | "__mocks__" | "e2e")) {
        return true;
    }
    if let Some(name) = parts.last() {
        if name.contains(".test.") || name.contains(".spec.") {
            return true;
        }
    }
    parts.iter().any(|s| s.ends_with("Tests") || s.ends_with("Test"))
}

/// The smallest set of directories that holds every file.
pub fn minimal_dirs(files: &[String]) -> Vec<String> {
    let mut dirs: Vec<&str> = files.iter().map(|f| parent(f)).collect();
    dirs.sort();
    dirs.dedup();
    let mut result: Vec<String> = Vec::new();
    for d in dirs {
        if !result.iter().any(|r| !r.is_empty() && r != "." && (d == r || (d.starts_with(r.as_str()) && d.as_bytes().get(r.len()) == Some(&b'/')))) {
            result.push(if d.is_empty() { ".".to_string() } else { d.to_string() });
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_paths() {
        assert!(is_test_path("Tests/FeaturesTests/CheckoutTests.swift"));
        assert!(is_test_path("app/src/test/kotlin/PageTest.kt"));
        assert!(!is_test_path("Sources/Core/Cart.swift"));
        assert!(!is_test_path("Sources/Contest/Latest.swift"));
    }

    #[test]
    fn dirs() {
        assert_eq!(minimal_dirs(&["a/b/c.swift".into(), "a/b/d/e.swift".into(), "x.swift".into()]), vec![".".to_string(), "a/b".to_string()]);
        assert!(is_under("a/b/c", "a/b"));
        assert!(!is_under("a/bc", "a/b"));
        assert_eq!(strip_dir("ios/App/A.swift", "ios"), Some("App/A.swift"));
    }
}
