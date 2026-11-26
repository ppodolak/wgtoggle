#!/bin/bash
# Builds the app sources (without the app bootstrap) together with Tests/SelfTest.swift and runs them.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# main.swift without its top-level bootstrap (everything from the --diagnose block on)
sed '/^\/\/ `WGToggle --diagnose`/,$d' Sources/main.swift > "$T/AppCore.swift"
cp Sources/Helper.swift Sources/Stats.swift Sources/Features.swift Sources/Notify.swift Sources/LogExplorer.swift "$T/"
cp Tests/SelfTest.swift "$T/main.swift"
swiftc -o "$T/selftest" "$T"/*.swift
"$T/selftest"
