#!/usr/bin/env bash
# Run the full supergfx-gpu-dockswitch regression suite. No root needed.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for s in "$ROOT"/bin/*.sh "$ROOT"/lib/common.sh "$ROOT"/tests/*.sh \
         "$ROOT"/install.sh "$ROOT"/uninstall.sh; do
    bash -n "$s"
done
echo "syntax: OK"
"$ROOT/tests/test-runtime.sh"
"$ROOT/tests/test-pre.sh"
"$ROOT/tests/test-boot.sh"
echo "ALL TESTS PASS"
