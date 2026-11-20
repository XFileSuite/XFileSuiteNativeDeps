#!/usr/bin/env python3
"""Validate platform slices, public symbols and the packaged dependency closure."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys


def out(args):
    return subprocess.check_output([str(x) for x in args], text=True)


def verify(root):
    frameworks = root/'Frameworks'
    bundles = sorted(frameworks.glob('*.xcframework'))
    if not bundles: raise RuntimeError('No XCFrameworks')
    dynamic = {}
    symbols = {'xfs_ffmpeg_cli': ['xfs_ffmpeg_run'],
               'oxipng': ['oxipng_optimize_file', 'oxipng_optimize_memory'],
               'resvg': ['resvg_render', 'resvg_parse_tree_from_data'],
               'mpv': ['mpv_create','mpv_render_context_create'],
               'avcodec': ['avcodec_version'], 'MagickWand_7_Q16HDRI': ['NewMagickWand']}
    for bundle in bundles:
        info=plistlib.loads((bundle/'Info.plist').read_bytes())
        slices=info['AvailableLibraries']
        if len(slices)!=2: raise RuntimeError(f'{bundle.name}: expected two slices')
        variants=set()
        for entry in slices:
            if entry['SupportedPlatform']!='ios': raise RuntimeError('Non-iOS slice')
            if entry['SupportedArchitectures']!=['arm64']: raise RuntimeError('Unexpected architecture')
            variant=entry.get('SupportedPlatformVariant','device')
            variants.add(variant)
            base=bundle/entry['LibraryIdentifier']
            library=base/entry['LibraryPath']
            binary=library/library.stem if library.suffix=='.framework' else library
            # vtool checks the actual Mach-O platform, not only the XCFramework plist.
            if library.suffix=='.framework':
                load=out(['xcrun','vtool','-show-build',binary])
                expected='IOSSIMULATOR' if variant=='simulator' else 'IOS'
                if not any(line.strip()=='platform '+expected for line in load.splitlines()):
                    raise RuntimeError(f'Wrong Mach-O platform: {binary}\n{load}')
                dependencies=[]
                for line in out(['otool','-L',binary]).splitlines()[2:]:
                    dep=line.strip().split(' (')[0]
                    if not dep.startswith(('/usr/lib/','/System/Library/','@rpath/')):
                        raise RuntimeError('Non-relocatable dependency: '+dep)
                    dependencies.append(dep)
                dynamic[(variant,library.name)]=dependencies
                debug = list(base.glob('dSYMs/*.dSYM'))
                if len(debug)!=1: raise RuntimeError('Missing or ambiguous dSYM: '+str(base))
                if out(['dwarfdump','--uuid',binary]).split()[1] != out(['dwarfdump','--uuid',debug[0]]).split()[1]:
                    raise RuntimeError('dSYM UUID mismatch: '+str(binary))
            exported=out(['nm','-gU',binary])
            for symbol in symbols.get(bundle.stem,[]):
                if '_'+symbol not in exported: raise RuntimeError('Missing symbol: '+symbol)
            headers=library/'Headers' if library.suffix=='.framework' else base/entry['HeadersPath']
            if not list(headers.rglob('*.h')): raise RuntimeError('Missing public headers')
        if variants!={'device','simulator'}: raise RuntimeError('Missing platform variant')
    for (variant,name),deps in dynamic.items():
        for dep in deps:
            if dep.startswith('@rpath/'):
                other=dep.split('/')[1]
                if (variant,other) not in dynamic: raise RuntimeError(f'{name}: missing {other}')
    print(f'Verified {len(bundles)} XCFrameworks: device + simulator, headers, symbols, dynamic dependency closure.')


if __name__=='__main__': verify(Path(sys.argv[1]).resolve())
