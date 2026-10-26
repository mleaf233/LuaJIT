#!/usr/bin/env bash
#
# Verifies the Dobby submodule is either:
#   - unpatched at $BASE_REF and the patches in this directory apply cleanly, or
#   - already has every patch applied (reverse apply succeeds), or
#   - has divergent state and reports what's wrong.
#
# Exits 0 only when at least one of the first two conditions is true.
# Designed for CI to catch a stale submodule pointer or a forgotten patch.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUBMODULE_DIR="$(cd "$HERE/../dobby" && pwd)"

if [ ! -d "$SUBMODULE_DIR/.git" ]; then
  echo "verify.sh: $SUBMODULE_DIR is not a git checkout." >&2
  exit 1
fi

cd "$SUBMODULE_DIR"

apply_check() {
  local patch_file="$1"
  # Detect the patch's commit subject from the mbox header and check whether
  # that commit exists in the submodule's history. This sidesteps the
  # file-mode / inter-patch conflicts that pure `git apply --reverse` runs
  # into once the patches have been squashed into subsequent commits.
  local subject
  subject="$(awk '
    /^Subject: / {
      sub(/^Subject: \[PATCH [0-9]+\/[0-9]+\] /, "")
      print
      exit
    }
  ' "$patch_file")"
  if [ -z "$subject" ]; then
    echo "no-subject"
    return 1
  fi
  if git log --oneline --grep="$subject" --regexp-ignore-case 2>/dev/null \
     | grep -q .; then
    echo "applied"
    return 0
  fi
  # Subject not in history -> the patches have not been carried over. Try
  # the forward apply to confirm the upstream pin still matches; this
  # requires the working tree to be at the unpatched base.
  if git apply --check -3 --ignore-whitespace --ignore-space-change \
        "$patch_file" >/dev/null 2>&1; then
    echo "clean"
    return 0
  fi
  echo "drift"
  return 1
}

all_ok=true
for p in "$HERE/0001-fix-MSVC-14.44-compatibility.patch" \
         "$HERE/0002-fix-MSVC-build-errors-round-2.patch"; do
  status="$(apply_check "$p")" || true
  echo "$(basename "$p"): $status"
  case "$status" in
    applied|clean) ;;
    *) all_ok=false ;;
  esac
done

if $all_ok; then
  exit 0
fi
echo
echo "verify.sh: at least one patch is in a 'drift' state," >&2
echo "  meaning the upstream Dobby pin has moved and the patches no longer match." >&2
echo "  Regenerate against the new pin:" >&2
echo "    cd $SUBMODULE_DIR" >&2
echo "    git format-patch <new-base>..HEAD -o $HERE" >&2
echo "  Then re-run bash $HERE/apply.sh." >&2
exit 1