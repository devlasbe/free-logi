#!/bin/bash
# Check inline Markdown links and images in both READMEs without network access.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path.cwd().resolve()
LINK_PATTERN = re.compile(r'!?\[[^\]\n]*\]\(([^)\n]+)\)')
failures = []

for filename in ("README.md", "README.ko.md"):
    readme = ROOT / filename
    checked = 0
    for match in LINK_PATTERN.finditer(readme.read_text()):
        destination = match.group(1).strip()
        url = urlsplit(destination)
        if url.scheme or url.netloc or not url.path:
            continue
        target = (readme.parent / unquote(url.path)).resolve()
        checked += 1
        if not target.is_relative_to(ROOT) or not target.is_file():
            failures.append(f"{filename}: missing file or outside repository: {destination}")
    print(f"{filename}: checked {checked} relative links/images")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
print("PASS: all relative links/images point to repository files")
PY
