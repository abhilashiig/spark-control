#!/bin/bash
# Compiles the core sources with the self-check and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
S=Sources/SparkControl
swiftc -swift-version 5 -o .build/selfcheck Tests/main.swift $S/Transform.swift $S/Models.swift $S/Remote.swift
.build/selfcheck
