#!/usr/bin/env python3
"""Verify complete catalogs and real Foundation language selection without AppKit."""
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

if not __debug__:
    raise SystemExit("Localization checks require assertions; run Python without -O")

ROOT = Path(__file__).resolve().parents[1]
catalog = json.loads((ROOT / 'Localization/Localizable.xcstrings').read_text())
assert catalog['sourceLanguage'] == 'en'
for path in (ROOT / 'Sources').glob('*.swift'):
    for match in re.finditer(r'L10n\.text\(("(?:[^"\\]|\\.)*")', path.read_text()):
        assert json.loads(match[1]) in catalog['strings'], (path, match[1])
for key, entry in catalog['strings'].items():
    assert set(entry['localizations']) == {'en', 'ko'}, key
    values = [entry['localizations'][lang]['stringUnit']['value'] for lang in ('en', 'ko')]
    assert all(values), key
    assert values[0].count('%@') == values[1].count('%@'), key
    assert re.findall(r'%(?!@)[a-z]', values[0]) == re.findall(r'%(?!@)[a-z]', values[1]), key

with tempfile.TemporaryDirectory(prefix='deskveil-languages-') as raw:
    root = Path(raw)
    app = root / 'LanguageProbe.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'Resources').mkdir()
    for language in ('en', 'ko'):
        shutil.copytree(ROOT / 'Sources/Resources' / (language + '.lproj'), app / 'Resources' / (language + '.lproj'))
    (app / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='dev.local.softlock.language-probe', CFBundleExecutable='probe', CFBundleDevelopmentRegion='en', CFBundleLocalizations=['en','ko'])))
    main = root / 'main.swift'
    main.write_text('''import Foundation
let values = [L10n.text("설정"), L10n.text("배터리 %@%", "42"), L10n.text("%@  다시 시도\\n%@  긴급 해제", "⌘L", "⌘U"), L10n.text("%@ 화면 %@", "Monitor %@", "Dim")]
let data = try JSONSerialization.data(withJSONObject: values)
print(String(decoding: data, as: UTF8.self))
''')
    binary = app / 'MacOS/probe'
    subprocess.run(['swiftc', '-module-cache-path', str(root / 'cache'), str(ROOT / 'Sources/Localization.swift'), str(main), '-o', str(binary)], check=True)
    for language in ('en', 'ko', 'fr'):
        result = subprocess.run([str(binary), '-AppleLanguages', '(' + language + ')'], check=True, capture_output=True, text=True)
        values = json.loads(result.stdout)
        assert values[0] == ('설정' if language == 'ko' else 'Settings'), (language, values)
        assert values[1] == ('배터리 42%' if language == 'ko' else 'Battery 42%'), values
        assert '\n' in values[2] and '⌘L' in values[2] and '⌘U' in values[2], values
        assert values[3].count('Monitor %@') == 1, values
        print(language + ': native bundle selection, fallback, percent, newline, and arguments verified')
    for system, override, expected in [('ko', 'en', 'Settings'), ('en', 'ko', '설정'), ('ko', 'system', '설정'), ('en', 'invalid', 'Settings')]:
        result = subprocess.run([str(binary), '-AppleLanguages', '(' + system + ')', '-interfaceLanguage', override], check=True, capture_output=True, text=True)
        assert json.loads(result.stdout)[0] == expected, (system, override, result.stdout)
    print('In-app override and return to macOS language verified.')
print(str(len(catalog['strings'])) + ' entries have complete English and Korean translations.')
