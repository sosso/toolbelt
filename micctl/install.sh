#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p "$HOME/.local/bin"
swiftc -O -o "$HOME/.local/bin/micctl" micctl.swift
echo "installed: $HOME/.local/bin/micctl"
