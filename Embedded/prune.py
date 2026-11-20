"""Drop what the phone never loads from the staged runtime: sources, docs and symbols.

build.py calls this on a fresh stage; run `python3 Embedded/prune.py` to apply it to an existing Embedded/Build.
"""
from pathlib import Path
import shutil
import subprocess
import sys

# Type declarations, source maps, Windows debug symbols and addon sources: nothing Node resolves at run time.
SUFFIXES = {".ts", ".mts", ".cts", ".tsx", ".map", ".pdb", ".cc", ".cpp", ".c", ".h", ".hh", ".gyp", ".gypi", ".S"}
DOCS = ("README", "CHANGELOG", "HISTORY")
FOLDERS = {"test", "tests", "__tests__", "example", "examples", "docs", "benchmark", "benchmarks"}
# NodeMobile runs with --jitless, which has no WebAssembly, so the Office converter can never start;
# the DevTools pages are only ever served to a desktop browser.
UNUSABLE = [
    "@deepseek-ai/libreoffice-kit-wasm/assets/soffice.wasm",
    "@deepseek-ai/libreoffice-kit-wasm/assets/soffice.data",
    "@deepseek-ai/libreoffice-kit-wasm/sources",
    "@deepseek-ai/dsh-experimental-inspector/lib/devtools",
    "node-pty/prebuilds",
]


def packages(modules):
    for entry in modules.iterdir():
        if entry.name.startswith("@"):
            yield from (child for child in entry.iterdir() if child.is_dir())
        elif entry.is_dir():
            yield entry


def prune_engine(engine):
    modules = engine / "node_modules"
    for name in UNUSABLE:
        target = modules / name
        if target.is_dir():
            shutil.rmtree(target)
            target.mkdir()  # static file servers still get a folder to point at
        else:
            target.unlink(missing_ok=True)
    for package in packages(modules):
        # First-party packages keep their folders: skills and templates live under such names.
        if package.parent.name != "@deepseek-ai":
            for folder in FOLDERS:
                if (package / folder).is_dir() and not (package / folder).is_symlink():
                    shutil.rmtree(package / folder)
    for path in modules.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        if path.suffix in SUFFIXES or path.name == ".DS_Store" or \
                (path.suffix in {".md", ".markdown"} and path.name.upper().startswith(DOCS)):
            path.unlink()


def strip_frameworks(frameworks):
    # UTM and NodeMobile ship with local symbols; exported ones stay so dlopen/dlsym keep working.
    # embed.sh signs every framework again when it copies it into the app.
    for name in ["qemu-aarch64-softmmu", "NodeMobile"]:
        binary = frameworks / (name + ".framework") / name
        if not binary.exists():
            continue
        subprocess.run(["xcrun", "strip", "-x", "-S", binary], check=True, stderr=subprocess.DEVNULL)


def prune(stage):
    prune_engine(stage / "DSHEngine")
    strip_frameworks(stage / "Frameworks")


if __name__ == "__main__":
    prune(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / "Build")
