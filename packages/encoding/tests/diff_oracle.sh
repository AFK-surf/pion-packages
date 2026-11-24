#!/bin/sh
# Run the differential parity harness against Mozilla Rust encoding_rs 0.8.44.
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$DIR/../audit/run_audit.sh" diff
