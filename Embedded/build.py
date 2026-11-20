"""Build the device runtime from locked npm packages and verified upstream releases."""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

from prune import prune

src = Path(__file__).resolve().parent
cache = Path(os.environ.get("DSH_LOCAL_CACHE", Path.home() / "Library/Caches/dsh-local-runtime")).resolve()
cache.mkdir(parents=True, exist_ok=True)

def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)

def fetch(name, url, digest):
    path = cache / name
    if not path.exists():
        part = path.with_suffix(".partial")
        run("curl", "-fLsS", "--retry", "2", url, "-o", part)
        part.replace(path)
    with path.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != digest:
            raise ValueError(f"Checksum mismatch for {name}")
    return path

def dependencies(folder, lock):
    folder.mkdir()
    for name in ["package.json", "package-lock.json"]:
        shutil.copy(lock / name, folder)
    run("npm", "ci", "--ignore-scripts", "--os=linux", "--cpu=arm64", "--libc=glibc",
        "--no-fund", "--no-audit", cwd=folder)
    return folder / "node_modules"


def prepare(temp, stage):
    engine = stage / "DSHEngine"
    frameworks = stage / "Frameworks"
    frameworks.mkdir(parents=True)
    mobile = "nodejs-mobile-ios-24.22.1-0.zip"
    archive = fetch(mobile, "https://github.com/fogtape/nodejs-mobile/releases/download/v24.22.1-0/" + mobile,
                    "3fa1b8fb0720768b01c2e0dae3a17e788476e8c1613a1d9a54e206793b45326e")
    run("unzip", "-oq", archive, "-d", temp)
    shutil.copytree(temp / "NodeMobile.xcframework/ios-arm64/NodeMobile.framework", frameworks / "NodeMobile.framework")
    (frameworks / "NodeMobile.framework/NodeMobile").chmod(0o755)
    system = frameworks / "DshSystem.framework"
    system.mkdir()
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    # The glob and grep tools' search, from ripgrep's libraries, linked into the same module.
    search = src.parent / ".build/search"
    run("cargo", "build", "--locked", "--release", "--lib", "--target", "aarch64-apple-ios", cwd=src / "native/search",
        env={**os.environ, "CARGO_TARGET_DIR": str(search), "IPHONEOS_DEPLOYMENT_TARGET": "17.0"})
    run("xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios17.0", "-isysroot", sdk,
        "-dynamiclib", "-fobjc-arc", "-O2", "-I", temp / "include/node", "-F", frameworks, "-framework", "Foundation",
        "-framework", "ImageIO", "-framework", "CoreGraphics", "-framework", "Security", "-framework", "NodeMobile", "-install_name", "@rpath/DshSystem.framework/DshSystem",
        *sorted((src / "native").glob("*.[cm]")), search / "aarch64-apple-ios/release/libdsh_search.a", "-o", system / "DshSystem")
    (system / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="io.dshlocal.DshSystem",
        CFBundleExecutable="DshSystem", CFBundleName="DshSystem", CFBundlePackageType="FMWK",
        CFBundleShortVersionString="1.0", CFBundleVersion="1", MinimumOSVersion="17.0")))
    shutil.copytree(src / "engine", engine)
    modules = dependencies(temp / "host", src)
    for path in modules.rglob("*"):
        if not path.is_file() or path.is_symlink() or path.suffix in {".node", ".so", ".map", ".dll", ".exe", ".dylib"} or ".so." in path.name:
            continue
        with path.open("rb") as stream:
            if stream.read(4) in [b"\x7fELF", bytes.fromhex("cffaedfe"), bytes.fromhex("cafebabe")]:
                continue
        dest = engine / "node_modules" / path.relative_to(modules)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
    for patch in sorted((src / "patches").glob("*.diff")):
        run("patch", "--batch", "-p1", "-i", patch, cwd=engine)
    # Companion of patches/zz-session-deletion.diff, which imports it by this name.
    shutil.copyfile(src / "session-deletion/core.mjs",
                    engine / "node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/dsh-local-deletion.mjs")
    prune(stage)
    (stage / "ready").touch()

def replace(stage, out, temp):
    if out.exists():
        out.rename(temp / "previous")
    try:
        stage.rename(out)
    except OSError:
        if (temp / "previous").exists():
            (temp / "previous").rename(out)
        raise

if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix=".assemble-", dir=src) as work:
        temp = Path(work)
        stage = temp / "stage"
        prepare(temp, stage)
        replace(stage, src / "Build", temp)
