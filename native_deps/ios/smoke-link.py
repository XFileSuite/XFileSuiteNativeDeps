#!/usr/bin/env python3
"""Compile and link an independent consumer of the final XCFrameworks."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT=Path(__file__).resolve().parent
stage=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else ROOT/'dist/xfilesuite-ios'
metadata=json.loads((stage/'metadata/BUILDINFO.json').read_text())
results=[]
for target,(sdk,triple,_) in metadata['targets'].items():
    out=ROOT/'work/smoke'/target; out.mkdir(parents=True,exist_ok=True)
    args=['xcrun','--sdk',sdk,'clang','-target',triple,'-isysroot',subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip(),'-DMAGICKCORE_QUANTUM_DEPTH=16','-DMAGICKCORE_HDRI_ENABLE=1',str(ROOT/'tests/smoke.c'),'-o',str(out/'smoke'),'-framework','Foundation','-framework','Security','-liconv','-lc++','-lz']
    for bundle in sorted((stage/'Frameworks').glob('*.xcframework')):
        info=plistlib.loads((bundle/'Info.plist').read_bytes())
        entry=next(x for x in info['AvailableLibraries'] if x.get('SupportedPlatformVariant','device')==('simulator' if target=='simulator' else 'device'))
        base=bundle/entry['LibraryIdentifier']; lib=base/entry['LibraryPath']
        if lib.suffix=='.framework':
            args += ['-F'+str(base),'-framework',lib.stem]
            headers=lib/'Headers'
            args += ['-I'+str(headers),'-I'+str(headers/'ImageMagick-7')]
        else:
            args += [str(lib),'-I'+str(base/entry['HeadersPath'])]
    subprocess.run(args,check=True)
    results.append({'target':target,'result':'compile-link-passed','executed':False})
(stage/'metadata/SMOKE_LINK.json').write_text(json.dumps(results,indent=2)+'\n')
print('Standalone consumer linked for iOS device and simulator; execution requires an iOS host.')
