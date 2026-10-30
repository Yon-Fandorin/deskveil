#!/usr/bin/env python3
"""Compile the String Catalog, or check the committed SwiftPM resources match it."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='deskveil-localize-') as raw:
        output = Path(raw)
        subprocess.run(['xcrun', 'xcstringstool', 'compile',
                        str(ROOT / 'Localization/Localizable.xcstrings'),
                        '--output-directory', str(output)], check=True)
        expected = {p.relative_to(output) for p in output.rglob('*') if p.is_file()}
        destination = ROOT / 'Sources/Resources'
        actual = {p.relative_to(destination) for p in destination.rglob('*') if p.is_file()}
        if args.check:
            if expected != actual or any((destination / p).read_bytes() != (output / p).read_bytes() for p in expected):
                raise SystemExit('Localization resources are stale. Run python3 Tools/localize.py.')
            print('Localization resources match the String Catalog.')
        else:
            for path in expected:
                target = destination / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((output / path).read_bytes())

if __name__ == '__main__':
    main()
