#!/bin/bash
# Runs the HackCodeKit test suite with Swift Testing from the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
EXTRA=()
if [ -d "$F" ]; then
  EXTRA=(-Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L")
fi
swift test "${EXTRA[@]}" "$@"
