#!/bin/sh
# Copies the device engine (built by `python3 Embedded/build.py`) into the app. The simulator has
# no device engine: there the app works with remote hosts only.
set -eu
[ "$PLATFORM_NAME" = iphoneos ] || exit 0
app="$TARGET_BUILD_DIR/$WRAPPER_NAME"
stage="$PROJECT_DIR/Embedded/Build"
[ -f "$stage/ready" ] || { echo "warning: no device engine; run python3 Embedded/build.py for 本机"; exit 0; }
/usr/bin/rsync -a --delete "$stage/DSHEngine/" "$app/DSHEngine/"
/usr/bin/rsync -a "$PROJECT_DIR/Embedded/engine/" "$app/DSHEngine/"
mkdir -p "$app/Frameworks"
for framework in "$stage"/Frameworks/*.framework; do
    target="$app/Frameworks/${framework##*/}"
    /usr/bin/rsync -a --delete --exclude=Headers --exclude=Modules "$framework/" "$target/"
    if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$target"
    fi
done
