#!/usr/bin/env python3
"""Prepare content-addressed publication metadata from verified iOS packages."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent


def prepare(root=ROOT):
    dist = root/'dist'
    metadata = dist/'xfilesuite-ios/metadata'
    runtime = dist/'xfilesuite-ios.tar.gz'
    source = dist/'xfilesuite-ios-source.tar.gz'
    hashes = []
    for archive in (runtime, source):
        with archive.open('rb') as stream:
            checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
        if archive.with_name(archive.name+'.sha256').read_text().split() != [checksum, archive.name]:
            raise RuntimeError(f'Checksum mismatch: {archive}')
        hashes.append(checksum)
    info = json.loads((metadata/'BUILDINFO.json').read_text())
    release = 'ios-native-deps-'+hashlib.sha256(''.join(hashes).encode()).hexdigest()[:24]
    key = f'deps/ios-native-deps-{hashes[0]}.tar.gz'
    manifest = dict(schemaVersion=1, platform='ios', minimumIOS=info['minimumIOS'],
                    components={'iosRuntime': dict(bundleSha256=hashes[0], r2Key=key,
                        sourceRelease=release, sourceSha256=hashes[1],
                        sourceArchive=source.name, recipe=info['recipe'])})
    native = root.parent
    (native/'manifests').mkdir(exist_ok=True)
    (native/'manifests/ios.json').write_text(json.dumps(manifest, indent=2)+'\n')
    shutil.copy2(metadata/'SBOM.json', native/'sbom-ios.json')
    return manifest


if __name__ == '__main__':
    prepare()
