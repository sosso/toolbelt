#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p "$HOME/.local/bin"
swiftc -O -o "$HOME/.local/bin/keysend" keysend.swift
echo "installed: $HOME/.local/bin/keysend"
