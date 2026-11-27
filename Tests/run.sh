#!/bin/bash
# Builds the app sources (without the app bootstrap) together with Tests/SelfTest.swift and runs them.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# Everything except the app entry point and the menu bar UI
for f in Sources/*.swift; do
  case "$(basename "$f")" in main.swift|AppDelegate*.swift) ;; *) cp "$f" "$T/" ;; esac
done
cp Tests/SelfTest.swift "$T/main.swift"
swiftc -o "$T/selftest" "$T"/*.swift
"$T/selftest"
