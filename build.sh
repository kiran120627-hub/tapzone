#!/bin/sh
# Build tapzone into build/tapzone. Tries the default SDK first, then older installed ones,
# because some Command Line Tools ship an SDK newer than their Swift compiler.
set -e
cd "$(dirname "$0")"
mkdir -p build
for sdk in "" $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
  if swiftc -O -target arm64-apple-macos14.0 ${sdk:+-sdk "$sdk"} Sources/*.swift -o build/tapzone 2>build/errors.txt; then
    echo "Built build/tapzone${sdk:+ (SDK: $(basename "$sdk"))}"
    exit 0
  fi
done
cat build/errors.txt
exit 1
