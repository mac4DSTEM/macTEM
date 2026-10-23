#!/bin/sh
# PROVENANCE: mac4DSTEM df1e6c994ea5b49c7ec08737628631b204736974 tools/lib/developer-dir.sh adapted
# The function is renamed (resolve_mactem_developer_dir); the resolution order and the refusal are unchanged; the
# history below is mac4DSTEM's and says so.
# END PROVENANCE

# Resolve a full Xcode toolchain without baking one developer's Xcode choice
# into every harness or gate.
#
# Why (mac4DSTEM's history, not macTEM's): in mac4DSTEM every harness used to
# default to /Applications/Xcode-beta.app, a statement about one machine rather
# than about the project, and on a checkout where Xcode is installed normally
# all 35 of them failed before running a line of test code. Set
# DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer to override.
#
# The Command Line Tools directory is rejected on purpose. It is what
# `xcode-select -p` reports on a machine that has never pointed at a full
# Xcode, it ships no xcodebuild, and this project cannot be built without one —
# so accepting it would trade a clear failure here for an obscure one later.
resolve_mactem_developer_dir() {
  if [ -n "${DEVELOPER_DIR:-}" ] \
    && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    export DEVELOPER_DIR
    return 0
  fi

  for candidate in \
    "$(xcode-select -p 2>/dev/null || true)" \
    /Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode-beta.app/Contents/Developer
  do
    if [ -n "$candidate" ] && [ -x "$candidate/usr/bin/xcodebuild" ]; then
      DEVELOPER_DIR=$candidate
      export DEVELOPER_DIR
      return 0
    fi
  done

  echo "No full Xcode toolchain found (Command Line Tools alone cannot build" >&2
  echo "this project). Install Xcode, point xcode-select at it, or set" >&2
  echo "DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer." >&2
  return 1
}
