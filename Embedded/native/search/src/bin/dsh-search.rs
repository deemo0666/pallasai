//! The same search as a command, for comparing with ripgrep on a computer: dsh-search <rg arguments>
use std::io::Write;

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let cwd = std::env::current_dir().unwrap();
    let outcome = dsh_search::run(&argv, &cwd, None, &|| false);
    std::io::stdout().write_all(&outcome.stdout).unwrap();
    eprint!("{}", outcome.stderr);
    std::process::exit(outcome.exit_code);
}
