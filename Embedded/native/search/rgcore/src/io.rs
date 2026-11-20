/*!
Where this copy of ripgrep reads its surroundings from and writes its output to, in place of the
process's own (it runs inside the app for a command typed in the Linux guest): the working
directory, standard output and error, whether standard input could be searched, and how paths
on the phone are shown with the names the guest command used.
*/

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};

pub struct Context {
    pub cwd: PathBuf,
    pub stdin_readable: bool,
    /// Phone path → the text the guest command named it with ("" for the implicit `./`).
    pub shown: Mutex<Vec<(PathBuf, String)>>,
    /// A path as the guest command named it → the phone's path, or why it cannot be run here.
    pub resolve: Box<dyn Fn(&str) -> Result<PathBuf, String> + Send + Sync>,
    /// Set when the command line asks for something not reproduced here.
    pub declined: Mutex<Option<String>>,
    /// A file not to search: where the guest command's standard output goes.
    pub skip: Option<PathBuf>,
    /// Whether a walked entry is one the guest would search (not a link or node it made).
    pub keep: Box<dyn Fn(&Path) -> bool + Send + Sync>,
    pub limit: usize,
    pub cancel: Box<dyn Fn() -> bool + Send + Sync>,
    pub out: Mutex<Vec<u8>>,
    pub err: Mutex<Vec<u8>>,
}

static CURRENT: RwLock<Option<Arc<Context>>> = RwLock::new(None);
/// One run at a time: ripgrep keeps some of its state in statics.
pub static RUN: Mutex<()> = Mutex::new(());

pub fn set(context: Option<Arc<Context>>) {
    *CURRENT.write().unwrap() = context;
}

pub fn current() -> Arc<Context> {
    CURRENT.read().unwrap().clone().expect("ripgrep run without a context")
}

/// The path as the guest command would show it.
pub fn shown(path: &Path) -> PathBuf {
    let context = current();
    let shown = context.shown.lock().unwrap();
    let mut best: Option<(&PathBuf, &String)> = None;
    for (phone, text) in shown.iter() {
        if path.starts_with(phone) && best.is_none_or(|(b, _)| phone.as_os_str().len() > b.as_os_str().len()) {
            best = Some((phone, text));
        }
    }
    match best {
        Some((phone, text)) => {
            let rest = path.strip_prefix(phone).unwrap();
            if rest.as_os_str().is_empty() {
                PathBuf::from(text)
            } else if text.is_empty() {
                rest.to_path_buf()
            } else {
                PathBuf::from(text).join(rest)
            }
        }
        None => path.to_path_buf(),
    }
}

/// Standard output. Past the limit, or once the caller gave up, writes fail like a closed pipe,
/// which ripgrep takes as the end.
pub struct Out;

impl Write for Out {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let context = current();
        if (context.cancel)() {
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        let mut out = context.out.lock().unwrap();
        if out.len() + buf.len() > context.limit {
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        out.extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub fn stdout() -> termcolor::NoColor<Out> {
    termcolor::NoColor::new(Out)
}

pub fn eprint(text: &str) {
    current().err.lock().unwrap().extend_from_slice(text.as_bytes());
}

/// termcolor::BufferWriter for the parallel search, writing to `Out`.
pub struct BufferWriter {
    separator: Option<Vec<u8>>,
    printed: std::sync::atomic::AtomicBool,
    lock: Mutex<()>,
}

impl BufferWriter {
    pub fn new() -> BufferWriter {
        BufferWriter { separator: None, printed: false.into(), lock: Mutex::new(()) }
    }
    pub fn separator(&mut self, sep: Option<Vec<u8>>) {
        self.separator = sep;
    }
    pub fn buffer(&self) -> termcolor::Buffer {
        termcolor::Buffer::no_color()
    }
    pub fn print(&self, buf: &termcolor::Buffer) -> io::Result<()> {
        use std::sync::atomic::Ordering;
        if buf.is_empty() {
            return Ok(());
        }
        let _guard = self.lock.lock().unwrap();
        let mut out = Out;
        if let Some(ref sep) = self.separator {
            if self.printed.load(Ordering::Relaxed) {
                out.write_all(sep)?;
                out.write_all(b"\n")?;
            }
        }
        out.write_all(buf.as_slice())?;
        self.printed.store(true, Ordering::Relaxed);
        Ok(())
    }
}

/// Records why this command line is not run here; ripgrep is then stopped with an error.
pub fn decline(why: impl Into<String>) -> anyhow::Error {
    let why = why.into();
    let context = current();
    let mut declined = context.declined.lock().unwrap();
    if declined.is_none() {
        *declined = Some(why.clone());
    }
    anyhow::anyhow!("declined: {why}")
}

/// A path operand: the phone's path for it, remembered with its text for showing.
pub fn operand(text: &std::ffi::OsStr) -> anyhow::Result<PathBuf> {
    let Some(text) = text.to_str() else { return Err(decline("path is not UTF-8")) };
    if text == "-" {
        return Err(decline("reads standard input"));
    }
    let context = current();
    let phone = (context.resolve)(text).map_err(decline)?;
    let mut shown = context.shown.lock().unwrap();
    // Shown by the longest prefix: overlapping operands would be ambiguous.
    if shown.iter().any(|(p, _)| p.starts_with(&phone) || phone.starts_with(p)) {
        drop(shown);
        return Err(decline("overlapping paths"));
    }
    shown.push((phone.clone(), text.to_string()));
    Ok(phone)
}

/// ripgrep's implicit `./`: the working directory, shown without a prefix.
pub fn implicit() -> PathBuf {
    let context = current();
    context.shown.lock().unwrap().push((context.cwd.clone(), String::new()));
    context.cwd.clone()
}
