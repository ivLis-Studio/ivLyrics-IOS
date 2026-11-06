#!/usr/bin/env python3
"""Run the production native v6 codec and applier against shared JS golden vectors."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'ivLyrics-IOS'
with tempfile.TemporaryDirectory(prefix='ivlyrics-swift-sync-v6-') as directory:
    work = Path(directory)
    models = (SRC / 'Models.swift').read_text()
    main = work / 'Checks.swift'
    main.write_text(models[:models.index('enum AppStatus:')] + (ROOT / 'scripts/SyncV6Checks.swift').read_text())
    sources = [SRC / name for name in ['Utilities.swift', 'TinySegmenter.swift', 'LrcParser.swift', 'SyncDataV6Codec.swift', 'SyncDataApplier.swift']]
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', *map(str, sources), str(main), '-o', str(work / 'checks')], check=True)
    subprocess.run([str(work / 'checks'), str(ROOT / 'scripts/fixtures/sync-v6-golden.json')], check=True)
