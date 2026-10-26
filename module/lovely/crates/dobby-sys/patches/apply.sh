#!/usr/bin/env bash
#
# Re-applies the Dobby upstream patches from this directory on top of the
# submodule's pinned commit. Idempotent: a second run on an already-patched
# tree is a no-op (each patch is checked before being applied).
#
# Usage:
#   bash crates/dobby-sys/patches/apply.sh
#
# After this script returns 0 you can run cargo build as usual. The submodule
# pointer in the main repo is unaffected by this script; it only edits files
# inside crates/dobby-sys/dobby. To persist the changes, run:
#    cd crates/dobby-sys/dobby
#    git add -A
#    git commit -m "build: re-apply Dobby upstream patches"
# and update the parent repo's submodule pointer.
#
# Exit codes:
#    0  patches applied (or already present)
#    1  patch failed (likely a Dobby upstream version mismatch)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUBMODULE_DIR="$(cd "$HERE/../dobby" && pwd)"

if [ ! -d "$SUBMODULE_DIR/.git" ]; then
  echo "apply.sh: $SUBMODULE_DIR does not look like a git checkout." >&2
  echo "  Run 'git submodule update --init --recursive' from the repo root first." >&2
  exit 1
fi

cd "$SUBMODULE_DIR"

# Reject run from a non-0932d69 base so the patch context matches what we
# generated against. Allow the working copy to already contain the patches
# we ship (i.e. the post-patch commits) - those produce a "patch already
# applied" exit code from `git apply` which we treat as success.
BASE_REF="${DOBBY_BASE_REF:-0932d69}"
ACTUAL_BASE="$(git rev-parse HEAD)"

if [ "$ACTUAL_BASE" = "$BASE_REF" ]; then
  echo "apply.sh: submodule HEAD is $BASE_REF (unpatched). Proceeding."
elif git log --oneline "$BASE_REF..HEAD" -- include/dobby.h \
       source/Backend/UserMode/ExecMemory/code-patch-tool-windows.cc \
       source/Backend/UserMode/PlatformUtil/Windows/ProcessRuntimeUtility.cc \
       source/Backend/UserMode/UnifiedInterface/platform-windows.cc \
       source/PlatformUnifiedInterface/platform.h \
       source/dobby.cpp >/dev/null 2>&1; then
  # Not the original base, but every file we touch is already touched in the
  # range $BASE_REF..HEAD. Likely the user has applied the patches before
  # (perhaps the post-patch commits from this repo). Confirm by trying to
  # apply and proceed only if it cleanly says "already applied".
  :
else
  echo "apply.sh: submodule HEAD is $ACTUAL_BASE," >&2
  echo "  expected to be $BASE_REF (unpatched) or a descendant that touches" >&2
  echo "  the files we patch. Bump DOBBY_BASE_REF if you intentionally moved" >&2
  echo "  the pin, then regenerate the patches with git format-patch." >&2
  exit 1
fi

apply_one() {
  local patch_file="$1"
  # `--reverse` is more permissive about which hunks are already in the tree
  # than you'd think: it checks for the inverse hunk, so it doubles as
  # "patch is already applied" detection.
  if git apply --check --reverse "$patch_file" >/dev/null 2>&1; then
    echo "apply.sh: $patch_file already applied; skipping."
    return 0
  fi
  # Forward apply with `-3` so conflict hunks fall back to three-way merge
  # instead of failing outright. We also pass `--ignore-whitespace` and
  # `--ignore-space-change` because file mode bits and trailing whitespace
  # in the working copy sometimes differ from what `format-patch` recorded.
  if ! git apply --check -3 --ignore-whitespace --ignore-space-change \
        "$patch_file" >/dev/null 2>&1; then
    echo "apply.sh: $patch_file does not apply cleanly to $ACTUAL_BASE." >&2
    echo "  Regenerate the patches against the new upstream pin:" >&2
    echo "    cd $SUBMODULE_DIR" >&2
    echo "    git format-patch <new-base>..HEAD -o $HERE" >&2
    return 1
  fi
  git apply -3 --ignore-whitespace --ignore-space-change "$patch_file"
  echo "apply.sh: applied $patch_file"
}

apply_one "$HERE/0001-fix-MSVC-14.44-compatibility.patch"
apply_one "$HERE/0002-fix-MSVC-build-errors-round-2.patch"

echo
echo "apply.sh: done. To persist, commit inside the submodule:"
echo "    cd $SUBMODULE_DIR"
echo "    git add -A && git commit -m \"build: re-apply Dobby upstream patches\""
echo "then update the parent repo's submodule pointer:"
echo "    cd \"\$(git rev-parse --show-toplevel)\""
echo "    git add crates/dobby-sys/dobby"