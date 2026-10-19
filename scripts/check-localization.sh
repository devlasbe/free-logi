#!/bin/bash
# Check Korean UI keys against the English table (Python 3 and plutil required).
set -euo pipefail
cd "$(dirname "$0")/.."
plutil -lint Resources/{en,ko}.lproj/Localizable.strings
python3 - <<'PY'
import json
from pathlib import Path
import re
import subprocess

translation_path = 'Resources/en.lproj/Localizable.strings'
translations = json.loads(subprocess.check_output(
    ['plutil', '-convert', 'json', '-o', '-', translation_path], text=True))
# These files only emit diagnostic CLI output; all other Sources are checked.
cli_files = {'CaptureCommand.swift', 'HIDAccessCheck.swift', 'HIDPPDump.swift',
             'InjectCommand.swift', 'main.swift'}
string_literal = re.compile(r'"(?:\\.|[^"\\])*"')
korean = re.compile(r'[가-힣]')
missing = []
checked = set()
for path in sorted(Path('Sources').rglob('*.swift')):
    if path.name in cli_files:
        continue
    source = re.sub(r'/\*.*?\*/', '', path.read_text(), flags=re.S)
    for line_number, line in enumerate(source.splitlines(), 1):
        if line.lstrip().startswith('//'):
            continue
        # Logging calls and their sole intermediate status value are not UI.
        if re.search(r'\b(print|printToStandardError|log)\(', line):
            continue
        if path.name == 'ButtonCapture.swift' and 'let tapState =' in line:
            continue
        for match in string_literal.finditer(line):
            literal = match.group()[1:-1]
            if not korean.search(literal):
                continue
            # Current interpolated UI keys use String values or Int button numbers.
            key = re.sub(r'\\\(([^()]*)\)',
                         lambda value: '%lld' if value[1] == 'number' else '%@', literal)
            key = key.replace(r'\n', '\n').replace(r'\"', '"').replace(r'\\', '\\')
            checked.add(key)
            translation = translations.get(key, '')
            if not translation.strip() or korean.search(translation):
                missing.append(f'{path}:{line_number}: missing English translation: {key}')
if missing:
    raise SystemExit('\n'.join(missing))
print(f'OK: {len(checked)} Korean UI keys have English translations; missing=0')
PY
