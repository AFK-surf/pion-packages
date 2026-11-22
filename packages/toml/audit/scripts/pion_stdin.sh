#!/bin/sh
# toml-test adapter: pion_cli only reads files, so spool stdin to a temp file.
# usage: pion_stdin.sh <pion_cli binary> <mode>
set -u
f=$(mktemp "${TMPDIR:-/tmp}/pion-toml-audit.XXXXXX")
cat > "$f"
"$1" "$2" "$f"
rc=$?
rm -f "$f"
exit $rc
