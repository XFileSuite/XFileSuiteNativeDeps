#!/usr/bin/env python3
"""Archive the exact inputs, patches and vendored Rust closure for an iOS build."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parent
NATIVE=ROOT.parent
sys.path.insert(0,str(ROOT))
from build import digest, sources, source, WORK, DIST, run, validate_package_inputs, COMPONENTS, recipe_digest

validate_package_inputs(COMPONENTS)
built_metadata=DIST/'xfilesuite-ios/metadata'
if not (built_metadata/'BUILDINFO.json').is_file():
    raise RuntimeError('Build and package the runtime before packaging its corresponding source.')
if json.loads((built_metadata/'BUILDINFO.json').read_text()).get('recipe') != recipe_digest():
    raise RuntimeError('Runtime package predates the current recipe; rebuild/repackage it first.')

stage=WORK/'corresponding-source'
if stage.exists(): shutil.rmtree(stage)
repo=stage/'XFileSuiteNativeDeps'
ios=repo/'native_deps/ios'
ios.mkdir(parents=True)
shutil.copy2(NATIVE.parent/'LICENSE',repo/'LICENSE')
workflow = repo/'.github/workflows/build-ios-deps.yml'
workflow.parent.mkdir(parents=True)
shutil.copy2(NATIVE.parent/'.github/workflows/build-ios-deps.yml',workflow)
for file in ROOT.iterdir():
    if file.is_file(): shutil.copy2(file,ios/file.name)
shutil.copytree(ROOT/'patches',ios/'patches')
shutil.copytree(ROOT/'tests',ios/'tests',ignore=shutil.ignore_patterns('__pycache__'))
for component in ['imagemagick','ffmpeg','media_runtime']:
    shutil.copytree(NATIVE/component/'patches',repo/'native_deps'/component/'patches')
shutil.copytree(NATIVE/'oxipng/ffi',repo/'native_deps/oxipng/ffi',ignore=shutil.ignore_patterns('target'))
shutil.copy2(NATIVE/'oxipng/LICENSE',repo/'native_deps/oxipng/LICENSE')
archives=ios/'work/downloads'; archives.mkdir(parents=True)
for name,spec in sources().items():
    source(name,'source-package')
    archive=WORK/'downloads'/(name+'-'+spec['version']+'.tar')
    shutil.copy2(archive,archives/archive.name)
# Pin and vendor both Rust dependency graphs. Config is relative to the source
# package root; build.py runs cargo from that root so offline rebuilds find it.
resvg=source('resvg','common')/'crates/c-api/Cargo.toml'
env=os.environ.copy()
vendor=repo/'vendor'
result=subprocess.check_output(['cargo','vendor','--locked','--versioned-dirs','--manifest-path',str(NATIVE/'oxipng/ffi/Cargo.toml'),'--sync',str(resvg),str(vendor)],env=env,text=True)
config=repo/'.cargo/config.toml'; config.parent.mkdir()
config.write_text(result.replace(str(vendor),'vendor'))
metadata=ios/'build-metadata'; metadata.mkdir()
built_metadata=DIST/'xfilesuite-ios/metadata'
if built_metadata.exists(): shutil.copytree(built_metadata,metadata,dirs_exist_ok=True)
(repo/'REBUILD.md').write_text('Rebuild on macOS with Xcode, Rust (>=1.88), CMake, Ninja, Meson, pkg-config, Autoconf, Automake and Libtool installed.\n\nFrom this directory run:\n\n    CARGO_NET_OFFLINE=true python3 native_deps/ios/build.py\n\nRust iOS standard-library targets must already be installed. All third-party source archives and Cargo packages are included. macOS/Xcode SDKs and system build tools are not redistributed.\n')
DIST.mkdir(exist_ok=True)
archive=DIST/'xfilesuite-ios-source.tar.gz'
run(['tar','-czf',archive,'-C',stage,'.'])
archive.with_suffix(archive.suffix+'.sha256').write_text(digest(archive)+'  '+archive.name+'\n')
print(archive)
