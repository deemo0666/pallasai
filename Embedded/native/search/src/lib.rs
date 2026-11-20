//! The engine's glob and grep tools on the phone, in the app's own process.
//!
//! The tools build a ripgrep command line and read ripgrep's output. iOS cannot start programs,
//! so this runs the two command shapes they use with ripgrep's own libraries: the same file
//! walk, ignore rules, glob overrides, regex engine and JSON printer.
//!
//!   --no-config --files [--glob=G]... --sort=modified --no-ignore --hidden [-- PATH]
//!   --no-config --json --regexp=PATTERN [--glob=G] [-- PATH]
//!
//! Any other flag is refused, so a change in the tools shows as an error instead of a
//! search that quietly means something else.

use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Duration, Instant, SystemTime};

/// A folder from Files can be a whole iCloud Drive (hundreds of thousands of files behind a file
/// provider). A walk stops after this many entries or this long and says so, instead of holding
/// the tool past its timeout and the app's memory with every path.
const WALK_ENTRIES: usize = 50_000;
const WALK_TIME: Duration = Duration::from_secs(20);
/// Content search over what the walk found stops after this long, too.
const SEARCH_TIME: Duration = Duration::from_secs(40);

/// An iCloud file whose content is not on the phone. Reading it would download it, so content
/// search passes over it; it is still listed by name.
fn dataless(path: &Path) -> bool {
    #[cfg(target_os = "ios")]
    use std::os::ios::fs::MetadataExt;
    #[cfg(target_os = "macos")]
    use std::os::macos::fs::MetadataExt;
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    { return path.symlink_metadata().map(|data| data.st_flags() & 0x4000_0000 != 0).unwrap_or(false); }
    #[allow(unreachable_code)]
    false
}

use grep::printer::{JSONBuilder, Stats};
use grep::regex::RegexMatcherBuilder;
use grep::searcher::{BinaryDetection, SearcherBuilder};
use ignore::overrides::OverrideBuilder;
use ignore::WalkBuilder;

pub struct Outcome {
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: String,
}

struct Command {
    files: bool,
    json: bool,
    pattern: Option<String>,
    globs: Vec<String>,
    sort_modified: bool,
    no_ignore: bool,
    hidden: bool,
    path: Option<String>,
}

fn parse(argv: &[String]) -> Result<Command, String> {
    let mut command = Command { files: false, json: false, pattern: None, globs: vec![], sort_modified: false,
                                no_ignore: false, hidden: false, path: None };
    let mut rest = argv.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--no-config" => {}
            "--files" => command.files = true,
            "--json" => command.json = true,
            "--sort=modified" => command.sort_modified = true,
            "--no-ignore" => command.no_ignore = true,
            "--hidden" => command.hidden = true,
            "--" => {
                command.path = rest.next().cloned();
                if rest.next().is_some() {
                    return Err("more than one search path".into());
                }
            }
            _ => {
                if let Some(glob) = arg.strip_prefix("--glob=") {
                    command.globs.push(glob.to_string());
                } else if let Some(pattern) = arg.strip_prefix("--regexp=") {
                    if command.pattern.replace(pattern.to_string()).is_some() {
                        return Err("more than one pattern".into());
                    }
                } else {
                    return Err(format!("unrecognized flag {arg}"));
                }
            }
        }
    }
    if command.files == (command.json && command.pattern.is_some()) || (command.json && command.sort_modified) {
        return Err("unsupported combination of flags".into());
    }
    Ok(command)
}

/// The path as ripgrep would print it: what the caller named, then the part below it; without
/// a named path, relative to the working directory with no leading "./".
fn shown(found: &Path, root: &Path, named: Option<&str>) -> PathBuf {
    let below = found.strip_prefix(root).unwrap_or(found);
    match named {
        None => below.to_path_buf(),
        Some(named) if below.as_os_str().is_empty() => PathBuf::from(named),
        Some(named) => Path::new(named).join(below),
    }
}

/// Runs one command. `root` is where to search when it differs from the working directory joined
/// with the named path (the engine maps paths of earlier app installs); what is printed still
/// starts with the named path. `cancelled` is polled between files.
pub fn run(argv: &[String], cwd: &Path, root: Option<&Path>, cancelled: &dyn Fn() -> bool) -> Outcome {
    let mut out = Outcome { exit_code: 2, stdout: vec![], stderr: String::new() };
    let command = match parse(argv) {
        Ok(command) => command,
        Err(message) => {
            out.stderr = format!("rg: {message}\n");
            return out;
        }
    };
    let named = command.path.as_deref();
    let root = match root {
        Some(root) => root.to_path_buf(),
        None => cwd.join(named.unwrap_or("")),
    };
    let mut overrides = OverrideBuilder::new(cwd);
    for glob in &command.globs {
        if let Err(error) = overrides.add(glob) {
            out.stderr = format!("rg: {error}\n");
            return out;
        }
    }
    let overrides = match overrides.build() {
        Ok(overrides) => overrides,
        Err(error) => {
            out.stderr = format!("rg: {error}\n");
            return out;
        }
    };
    let matcher = match &command.pattern {
        None => None,
        Some(pattern) => match RegexMatcherBuilder::new().line_terminator(Some(b'\n')).build(pattern) {
            Ok(matcher) => Some(matcher),
            Err(error) => {
                out.stderr = format!("rg: {error}\n");
                return out;
            }
        },
    };
    if let Err(error) = root.symlink_metadata() {
        // In ripgrep's words, with the path as it was named.
        let named = named.unwrap_or("./");
        out.stderr = format!("rg: {named}: IO error for operation on {named}: {error}\n");
        return out;
    }
    let mut walk = WalkBuilder::new(&root);
    walk.overrides(overrides).hidden(!command.hidden).threads(1);
    if command.no_ignore {
        walk.ignore(false).git_ignore(false).git_global(false).git_exclude(false).parents(false);
    }
    let mut errored = false;
    let mut files = vec![];
    let walking = Instant::now();
    let mut visited = 0usize;
    for entry in walk.build() {
        if cancelled() {
            out.stderr.push_str("rg: cancelled\n");
            return out;
        }
        visited += 1;
        if visited > WALK_ENTRIES || walking.elapsed() > WALK_TIME {
            out.stderr.push_str(&format!("rg: stopped after {} entries in {:.0}s: this folder is too large to walk whole; \
                results are partial; search a narrower path or a pattern with a directory prefix\n",
                visited - 1, walking.elapsed().as_secs_f64()));
            break;
        }
        match entry {
            Err(error) => {
                errored = true;
                out.stderr.push_str(&format!("rg: {error}\n"));
            }
            Ok(entry) => {
                if let Some(error) = entry.error() {
                    // Ripgrep reports these (an unreadable ignore file) without failing the search.
                    out.stderr.push_str(&format!("rg: {error}\n"));
                }
                // A named file is searched whatever it is; below a directory, only regular files.
                let wanted = match entry.file_type() {
                    Some(kind) => kind.is_file() || (entry.depth() == 0 && !kind.is_dir()),
                    None => false,
                };
                if wanted {
                    files.push((entry.depth() == 0, entry.into_path()));
                }
            }
        }
    }
    let started = Instant::now();
    let mut found = false;
    match matcher {
        None => {
            if command.sort_modified {
                // Stable, oldest first, as ripgrep's --sort=modified; unreadable times last.
                let mut timed: Vec<(Option<SystemTime>, PathBuf)> = files
                    .into_iter()
                    .map(|(_, path)| (path.metadata().and_then(|data| data.modified()).ok(), path))
                    .collect();
                timed.sort_by(|a, b| match (a.0, b.0) {
                    (Some(a), Some(b)) => a.cmp(&b),
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    (None, None) => std::cmp::Ordering::Equal,
                });
                files = timed.into_iter().map(|(_, path)| (false, path)).collect();
            }
            for (_, path) in &files {
                found = true;
                out.stdout.extend_from_slice(shown(path, &root, named).as_os_str().as_encoded_bytes());
                out.stdout.push(b'\n');
            }
        }
        Some(matcher) => {
            let mut printer = JSONBuilder::new().build(vec![]);
            let mut total = Stats::new();
            let mut skipped = 0usize;
            for (explicit, path) in &files {
                if cancelled() {
                    out.stderr.push_str("rg: cancelled\n");
                    return out;
                }
                if started.elapsed() > SEARCH_TIME {
                    out.stderr.push_str("rg: content search stopped after 40s; results are partial; search a narrower path\n");
                    break;
                }
                if !*explicit && dataless(path) {
                    skipped += 1;
                    continue;
                }
                // Ripgrep maps a file named on its command line into memory, where a NUL byte neither
                // ends the search nor is rewritten; a file met while walking is given up at the first NUL.
                let binary = if *explicit { BinaryDetection::none() } else { BinaryDetection::quit(b'\x00') };
                let mut searcher = SearcherBuilder::new().line_number(true).binary_detection(binary).build();
                let display = shown(path, &root, named);
                let mut sink = printer.sink_with_path(&matcher, &display);
                match searcher.search_path(&matcher, path, &mut sink) {
                    Ok(()) => {
                        found |= sink.has_match();
                        total += sink.stats();
                    }
                    Err(error) => {
                        errored = true;
                        out.stderr.push_str(&format!("rg: {}: {error}\n", display.display()));
                    }
                }
            }
            if skipped > 0 {
                out.stderr.push_str(&format!("rg: {skipped} iCloud files not downloaded to this iPhone were not searched; read one to download it\n"));
            }
            out.stdout = printer.into_inner();
            let elapsed = started.elapsed();
            let summary = serde_json::json!({"type": "summary", "data": {
                "elapsed_total": {"secs": elapsed.as_secs(), "nanos": elapsed.subsec_nanos(),
                                  "human": format!("{:.6}s", elapsed.as_secs_f64())},
                "stats": total}});
            out.stdout.extend_from_slice(summary.to_string().as_bytes());
            out.stdout.push(b'\n');
        }
    }
    out.exit_code = if errored { 2 } else if found { 0 } else { 1 };
    out
}

/// C entry for the app's native module. `request` is JSON: {"argv": [...], "cwd": "...", "root": "..." or null}.
/// `cancel` points at one byte that turns non-zero when the caller gives up. Returns JSON
/// {"exitCode", "stdout", "stderr"} to be released with `dsh_search_free`; stdout that is not
/// UTF-8 (a file name) is converted lossily.
#[no_mangle]
pub unsafe extern "C" fn dsh_search(request: *const c_char, cancel: *const AtomicU8) -> *mut c_char {
    let answer = std::panic::catch_unwind(|| {
        let request: serde_json::Value = serde_json::from_slice(CStr::from_ptr(request).to_bytes()).unwrap_or_default();
        let argv: Vec<String> = request["argv"].as_array().map(|items| {
            items.iter().filter_map(|item| item.as_str().map(str::to_string)).collect()
        }).unwrap_or_default();
        let cwd = PathBuf::from(request["cwd"].as_str().unwrap_or("."));
        let root = request["root"].as_str().map(PathBuf::from);
        let cancelled = || !cancel.is_null() && (*cancel).load(Ordering::Relaxed) != 0;
        let outcome = run(&argv, &cwd, root.as_deref(), &cancelled);
        serde_json::json!({"exitCode": outcome.exit_code, "stdout": String::from_utf8_lossy(&outcome.stdout),
                           "stderr": outcome.stderr}).to_string()
    }).unwrap_or_else(|_| r#"{"exitCode":2,"stdout":"","stderr":"rg: search failed unexpectedly\n"}"#.to_string());
    CString::new(answer).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn dsh_search_free(answer: *mut c_char) {
    if !answer.is_null() {
        drop(CString::from_raw(answer));
    }
}
