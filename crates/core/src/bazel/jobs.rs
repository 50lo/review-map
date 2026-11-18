//! How many Bazel commands of one review run at once.
//!
//! Each workspace has an output base, and so a Bazel server, of its own at each side
//! (`Workspaces::output_base`). A server runs one command at a time, but commands of different output bases
//! can run together: the graph queries of a review that touches several workspaces, and the index builds of
//! workspaces that don't contain one another. `Session::refine` runs them on a pool of `jobs()` threads.
//!
//! Each server that starts takes memory (0.3–0.7 GB measured cold, more while it analyses a large scope),
//! so the bound is small: half the cores, at most 4, and lower when the machine has little memory free.
//! `REVIEWMAP_BAZEL_JOBS` sets it; `REVIEWMAP_BAZEL_JOBS=1` runs every command after the previous one.

use anyhow::{Context, Result};

/// Memory set aside for each Bazel command that runs at once.
const PER_JOB: u64 = 1 << 30;
/// Memory left to everything else on the machine before any Bazel command counts.
const RESERVE: u64 = 2 << 30;

/// The bound for this machine now: `REVIEWMAP_BAZEL_JOBS`, or `bound` of its cores and free memory.
pub fn jobs() -> usize {
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    bound(std::env::var("REVIEWMAP_BAZEL_JOBS").ok().as_deref(), cores, available_memory())
}

/// The bound: `setting` when it is a number (at least 1); otherwise half the cores, at most 4, and no more
/// than the free memory allows at `PER_JOB` each after `RESERVE`. Unknown free memory doesn't lower it.
pub fn bound(setting: Option<&str>, cores: usize, available: Option<u64>) -> usize {
    if let Some(n) = setting.and_then(|v| v.trim().parse::<usize>().ok()) {
        return n.max(1);
    }
    let by_cores = (cores / 2).clamp(1, 4);
    let by_memory = available.map(|a| (a.saturating_sub(RESERVE) / PER_JOB) as usize).unwrap_or(usize::MAX);
    by_cores.min(by_memory).max(1)
}

/// A pool of `jobs()` threads for one step of a review.
pub fn pool() -> Result<rayon::ThreadPool> {
    rayon::ThreadPoolBuilder::new()
        .num_threads(jobs())
        .thread_name(|i| format!("reviewmap-bazel-{i}"))
        .build()
        .context("could not start the Bazel job threads")
}

/// Memory the system could give to new processes now, in bytes: on macOS the share of physical memory that
/// the kernel's memory-pressure level reports as available, on Linux `MemAvailable`.
fn available_memory() -> Option<u64> {
    #[cfg(target_os = "macos")]
    {
        let total = sysctl_u64("hw.memsize")?;
        let level = sysctl_u64("kern.memorystatus_level")?;
        Some(total / 100 * level.min(100))
    }
    #[cfg(target_os = "linux")]
    {
        let text = std::fs::read_to_string("/proc/meminfo").ok()?;
        let line = text.lines().find(|l| l.starts_with("MemAvailable:"))?;
        let kb: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
        Some(kb * 1024)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
fn sysctl_u64(name: &str) -> Option<u64> {
    let name = std::ffi::CString::new(name).ok()?;
    let mut buf = [0u8; 8];
    let mut len: libc::size_t = buf.len();
    let status = unsafe { libc::sysctlbyname(name.as_ptr(), buf.as_mut_ptr().cast(), &mut len, std::ptr::null_mut(), 0) };
    match (status, len) {
        (0, 8) => Some(u64::from_ne_bytes(buf)),
        (0, 4) => Some(u32::from_ne_bytes([buf[0], buf[1], buf[2], buf[3]]) as u64),
        _ => None,
    }
}

/// Splits units (repo-relative directories, in their order) into batches that run one after another. Units
/// in one batch may run at the same time, because none contains another: an index step changes files in its
/// unit's directory (the `node_modules` links of TypeScript, the aspects of Swift and Kotlin), which a unit
/// around it would see. A unit goes into the last batch when it is disjoint from every unit there, so a
/// unit still runs after every unit before it that contains it or that it contains.
pub fn batches(units: &[String]) -> Vec<Vec<String>> {
    let nests = |a: &str, b: &str| crate::paths::is_under(a, b) || crate::paths::is_under(b, a);
    let mut out: Vec<Vec<String>> = Vec::new();
    for u in units {
        match out.last_mut() {
            Some(last) if !last.iter().any(|v| nests(u, v)) => last.push(u.clone()),
            _ => out.push(vec![u.clone()]),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const GB: u64 = 1 << 30;

    #[test]
    fn the_bound_is_half_the_cores_at_most_four_and_lower_when_memory_is_short() {
        assert_eq!(bound(None, 8, Some(12 * GB)), 4);
        assert_eq!(bound(None, 16, Some(64 * GB)), 4);
        assert_eq!(bound(None, 4, Some(12 * GB)), 2);
        assert_eq!(bound(None, 1, Some(12 * GB)), 1);
        assert_eq!(bound(None, 8, None), 4, "unknown free memory doesn't lower it");
        assert_eq!(bound(None, 8, Some(5 * GB)), 3);
        assert_eq!(bound(None, 8, Some(3 * GB)), 1);
        assert_eq!(bound(None, 8, Some(GB)), 1, "never below one");
    }

    #[test]
    fn the_environment_variable_sets_the_bound() {
        assert_eq!(bound(Some("1"), 8, Some(12 * GB)), 1);
        assert_eq!(bound(Some("6"), 8, Some(GB)), 6, "the setting wins over free memory");
        assert_eq!(bound(Some("0"), 8, None), 1);
        assert_eq!(bound(Some("many"), 8, None), 4, "a setting that is no number is ignored");
    }

    #[test]
    fn units_that_contain_one_another_go_into_later_batches() {
        let units = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let fixtures = "crates/core/tests/fixtures";
        assert_eq!(
            batches(&units(&["", &format!("{fixtures}/ts-bazel/base"), &format!("{fixtures}/ts-bazel/head")])),
            vec![units(&[""]), units(&[&format!("{fixtures}/ts-bazel/base"), &format!("{fixtures}/ts-bazel/head")])]
        );
        assert_eq!(batches(&units(&["a", "b", "c"])), vec![units(&["a", "b", "c"])]);
        assert_eq!(batches(&units(&["a", "a/x", "b"])), vec![units(&["a"]), units(&["a/x", "b"])]);
        assert_eq!(batches(&units(&["ab", "a"])), vec![units(&["ab", "a"])], "a/b is not under a when the name only starts with it");
        assert!(batches(&[]).is_empty());
    }
}
