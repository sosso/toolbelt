#!/bin/bash
# Copies the srs runner and its line-editing helper into ~/.local/bin. Progress
# lives in ~/.local/share/srs and is never touched by a reinstall.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p "$HOME/.local/bin"
for f in bin/*; do
  dest="$HOME/.local/bin/$(basename "$f")"
  rm -f "$dest"
  install -m 0755 "$f" "$dest"
done

echo "srs deployed: $(ls bin | tr '\n' ' ')→ ~/.local/bin"
command -v duckdb >/dev/null || [ -x /opt/homebrew/bin/duckdb ] ||
  echo "  lateral-join cards need DuckDB: brew install duckdb"
shortcuts list 2>/dev/null | grep -qx "SRS Focus" ||
  echo "  popups stay held until the \"SRS Focus\" Shortcut exists — see srs/README.md"
