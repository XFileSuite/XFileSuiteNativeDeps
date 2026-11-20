#!/usr/bin/env python3
"""Build iOS native dependencies without touching the Flutter application."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
NATIVE = ROOT.parent
WORK = ROOT / 'work'
DIST = ROOT / 'dist'
MIN_IOS = os.environ.get('MIN_IOS', '15.0')
JOBS = os.environ.get('JOBS', '8')
COMPONENTS = ('imagemagick', 'media', 'oxipng', 'resvg')
TARGETS = {'device': ('iphoneos', 'arm64-apple-ios' + MIN_IOS, 'aarch64-apple-ios'),
           'simulator': ('iphonesimulator', 'arm64-apple-ios' + MIN_IOS + '-simulator', 'aarch64-apple-ios-sim')}


def run(args, cwd=None, env=None):
    args = [str(x) for x in args]
    print('+ ' + ' '.join(args), flush=True)
    subprocess.run(args, cwd=cwd, env=env, check=True)


def output(args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def digest(p):
    with p.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def sources():
    return {x['name']: x for x in json.loads((ROOT / 'sources.lock.json').read_text())}


def recipe_digest():
    # Include inputs shared READ-ONLY with desktop builds. All generated files
    # and patched source trees stay under ios/work instead.
    paths = [ROOT/'build.py', ROOT/'sources.lock.json', ROOT/'ffmpeg-cli.mk', ROOT/'ffmpeg-cli.h']
    paths += sorted((ROOT/'patches').glob('*.patch'))
    for component in ['imagemagick', 'ffmpeg', 'media_runtime']:
        paths += sorted((NATIVE/component/'patches').glob('*.patch'))
    ffi = NATIVE/'oxipng/ffi'
    paths += [p for p in [ffi/'Cargo.toml', ffi/'Cargo.lock'] if p.is_file()]
    for directory in ['src', 'include']:
        paths += sorted(p for p in (ffi/directory).rglob('*') if p.is_file())
    state = hashlib.sha256()
    for path in paths:
        state.update(str(path.relative_to(NATIVE)).encode())
        state.update(bytes.fromhex(digest(path)))
    return state.hexdigest()


def build_config(sdkpath):
    return dict(minimumIOS=MIN_IOS, sdk=sdkpath,
                xcode=output(['xcodebuild', '-version']),
                rust=output(['rustc', '--version']),
                cmake=output(['cmake', '--version']).splitlines()[0],
                meson=output(['meson', '--version']), recipe=recipe_digest())


def validate_package_inputs(components):
    if set(components) != set(COMPONENTS):
        raise RuntimeError('A deliverable requires all component groups. Use --no-package for a targeted build.')
    # Check before deleting/replacing an existing verified deliverable.
    for target, (sdk, _, _) in TARGETS.items():
        base = WORK/target
        config_file = base/'BUILD_CONFIG.json'
        if not config_file.is_file():
            raise RuntimeError(f'Missing build record: {config_file}; build both targets first.')
        current = build_config(output(['xcrun', '--sdk', sdk, '--show-sdk-path']))
        if json.loads(config_file.read_text()) != current:
            raise RuntimeError(f'Build settings or recipe changed. Remove {base} and rebuild before packaging.')
        for name in ['imagemagick', 'mpv']:
            if not (base/('built-'+name)).is_file():
                raise RuntimeError(f'Incomplete {target} build: {name}')
        for name in ['oxipng', 'resvg', 'xfs_ffmpeg_cli']:
            if not (base/'prefix/lib'/('lib'+name+'.dylib')).is_file():
                raise RuntimeError(f'Incomplete {target} build: {name}')


def source(name, target):
    spec = sources()[name]
    downloads = WORK / 'downloads'
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / (name + '-' + spec['version'] + '.tar')
    if not archive.exists():
        cached = NATIVE / spec['cache']
        if cached.exists():
            shutil.copy2(cached, archive)
        else:
            partial = archive.with_suffix('.partial')
            run(['curl', '-fL', '--retry', '5', '--connect-timeout', '20', '--max-time', '600', spec['url'], '-o', partial])
            partial.rename(archive)
    if digest(archive) != spec['sha256']:
        raise RuntimeError('Source checksum mismatch: ' + str(archive))
    dest = WORK / target / 'sources' / name
    if not dest.exists():
        partial = dest.with_name(dest.name+'.extracting')
        if partial.exists(): shutil.rmtree(partial)
        partial.mkdir(parents=True)
        run(['tar', '-xf', archive, '-C', partial, '--strip-components=1'])
        partial.rename(dest)
    return dest


class Build:
    def __init__(self, target):
        self.target = target
        self.sdk, self.triple, self.rust_target = TARGETS[target]
        self.sdkpath = output(['xcrun', '--sdk', self.sdk, '--show-sdk-path'])
        self.base = WORK / target
        self.prefix = self.base / 'prefix'
        self.prefix.mkdir(parents=True, exist_ok=True)
        config = build_config(self.sdkpath)
        config_file = self.base/'BUILD_CONFIG.json'
        if config_file.exists() and json.loads(config_file.read_text()) != config:
            raise RuntimeError(f'Build settings changed. Remove {self.base} and rebuild (download cache may be kept).')
        config_file.write_text(json.dumps(config, indent=2)+'\n')
        self.env = os.environ.copy()
        flags = f'-target {self.triple} -isysroot {self.sdkpath} -O2 -g -fPIC'
        self.env.update(CC='clang', CXX='clang++', OBJC='clang', OBJCXX='clang++',
                        CFLAGS=flags, CXXFLAGS=flags + ' -std=c++11', OBJCFLAGS=flags,
                        CPPFLAGS=f'-I{self.prefix}/include',
                        LDFLAGS=f'-target {self.triple} -isysroot {self.sdkpath} -L{self.prefix}/lib',
                        SDKROOT=self.sdkpath, IPHONEOS_DEPLOYMENT_TARGET=MIN_IOS,
                        PKG_CONFIG_LIBDIR=f'{self.prefix}/lib/pkgconfig:{self.prefix}/share/pkgconfig',
                        PKG_CONFIG_PATH='')
        pc = self.prefix / 'lib/pkgconfig'
        pc.mkdir(parents=True, exist_ok=True)
        (pc / 'zlib.pc').write_text('Name: zlib\nDescription: iOS SDK zlib\nVersion: 1.2.12\nLibs: -lz\n')
        self.cross = self.base / 'cross.ini'
        binaries = {k: ['clang++' if k in ['cpp', 'objcpp'] else 'clang'] for k in ['c', 'cpp', 'objc', 'objcpp']}
        binaries.update(ar=['ar'], strip=['strip'], **{'pkg-config': ['pkg-config']})
        text = '[binaries]\n' + '\n'.join(f'{k} = {v!r}' for k, v in binaries.items())
        text += "\n[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'arm64'\nendian = 'little'\n[properties]\nneeds_exe_wrapper = true\n[built-in options]\n"
        for lang in ['c', 'cpp', 'objc', 'objcpp']:
            text += f"{lang}_args = {['-target', self.triple, '-isysroot', self.sdkpath, '-O2', '-g']!r}\n"
            text += f"{lang}_link_args = {['-target', self.triple, '-isysroot', self.sdkpath, '-L'+str(self.prefix/'lib')]!r}\n"
        self.cross.write_text(text)

    def done(self, name, action):
        stamp = self.base / ('built-' + name)
        if stamp.exists():
            print('Cached:', self.target, name, flush=True)
            return
        action()
        stamp.write_text('ok\n')

    def cmake(self, name, options=()):
        def action():
            src = source(name, self.target)
            if name == 'mozjpeg':
                cmakelists = src/'CMakeLists.txt'
                cmakelists.write_text(cmakelists.read_text().replace('string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} CMAKE_SYSTEM_PROCESSOR_LC)', 'string(TOLOWER "${CMAKE_OSX_ARCHITECTURES}" CMAKE_SYSTEM_PROCESSOR_LC)'))
            build = self.base / 'build' / name
            run(['cmake', '-S', src, '-B', build, '-G', 'Ninja', '-DCMAKE_SYSTEM_NAME=iOS',
                 '-DCMAKE_OSX_SYSROOT='+self.sdkpath, '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_SYSTEM_PROCESSOR=arm64',
                 '-DCMAKE_OSX_DEPLOYMENT_TARGET='+MIN_IOS, '-DCMAKE_BUILD_TYPE=RelWithDebInfo',
                 '-DCMAKE_INSTALL_PREFIX='+str(self.prefix), '-DCMAKE_PREFIX_PATH='+str(self.prefix), '-DCMAKE_FIND_ROOT_PATH='+str(self.prefix),
                 '-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY', '-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY', '-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY',
                 '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
                 '-DBUILD_SHARED_LIBS=ON', *options], env=self.env)
            run(['cmake', '--build', build, '--parallel', JOBS], env=self.env)
            run(['cmake', '--install', build], env=self.env)
        self.done(name, action)

    def auto(self, name, options=(), extra=None):
        def action():
            src = source(name, self.target)
            patch = ROOT/'patches'/(name+'-ios.patch')
            if patch.exists() and not (src/'.xfs-ios-patched').exists():
                run(['patch', '-p1', '-i', patch], cwd=src)
                (src/'.xfs-ios-patched').touch()
            if not (src / 'configure').exists():
                run(['autoreconf', '-fi'], cwd=src)
            build = self.base / 'build' / name
            build.mkdir(parents=True, exist_ok=True)
            env = dict(self.env, **(extra or {}))
            run([src/'configure', '--host=aarch64-apple-darwin', '--build='+output([src/'config.guess']) if (src/'config.guess').exists() else '--build=arm-apple-darwin',
                 '--prefix='+str(self.prefix), '--enable-shared', '--disable-static', *options], cwd=build, env=env)
            run(['make', '-j'+JOBS], cwd=build, env=env)
            run(['make', 'install'], cwd=build, env=env)
        self.done(name, action)

    def meson(self, name, options=()):
        def action():
            src = source(name, self.target)
            if name == 'libplacebo':
                for dep, subdir in [('libplacebo-glad','glad'), ('libplacebo-fast-float','fast_float'), ('libplacebo-jinja','jinja'), ('libplacebo-markupsafe','markupsafe'), ('libplacebo-vulkan-headers','Vulkan-Headers')]:
                    shutil.copytree(source(dep, self.target), src/'3rdparty'/subdir, dirs_exist_ok=True)
            patch = ROOT/'patches'/(name+'-ios.patch')
            if patch.exists() and not (src/'.xfs-ios-patched').exists():
                run(['patch', '-p1', '-i', patch], cwd=src)
                (src/'.xfs-ios-patched').touch()
            build = self.base / 'build' / name
            env = {k:v for k,v in self.env.items() if k not in ['CC','CXX','OBJC','OBJCXX','CFLAGS','CXXFLAGS','CPPFLAGS','OBJCFLAGS','LDFLAGS','SDKROOT','IPHONEOS_DEPLOYMENT_TARGET']}
            reconfigure = ['--reconfigure'] if (build/'meson-private/coredata.dat').exists() else []
            run(['meson', 'setup', *reconfigure, build, src, '--cross-file', self.cross, '--prefix', self.prefix,
                 '--libdir=lib', '--buildtype=debugoptimized', '--default-library=shared', '--wrap-mode=nodownload', *options], env=env)
            run(['meson', 'compile', '-C', build, '-j', JOBS], env=env)
            run(['meson', 'install', '-C', build], env=env)
        self.done(name, action)

    def images(self):
        self.cmake('mozjpeg', ['-DENABLE_SHARED=ON', '-DENABLE_STATIC=OFF', '-DWITH_TURBOJPEG=OFF', '-DPNG_SUPPORTED=OFF'])
        self.cmake('libpng', ['-DPNG_FRAMEWORK=OFF', '-DPNG_SHARED=ON', '-DPNG_STATIC=OFF', '-DPNG_TESTS=OFF', '-DPNG_TOOLS=OFF'])
        self.cmake('libwebp', ['-DWEBP_BUILD_ANIM_UTILS=OFF', '-DWEBP_BUILD_CWEBP=OFF', '-DWEBP_BUILD_DWEBP=OFF', '-DWEBP_BUILD_GIF2WEBP=OFF', '-DWEBP_BUILD_IMG2WEBP=OFF', '-DWEBP_BUILD_VWEBP=OFF', '-DWEBP_BUILD_WEBPINFO=OFF', '-DWEBP_BUILD_WEBPMUX=OFF', '-DWEBP_BUILD_EXTRAS=OFF'])
        self.cmake('libtiff', ['-Dtiff-framework=OFF', '-Dtiff-cxx=OFF', '-Dtiff-tools=OFF', '-Dtiff-tests=OFF', '-Dtiff-contrib=OFF', '-Dtiff-docs=OFF', '-Dlzma=OFF', '-Dzstd=OFF', '-Dwebp=ON', '-Djbig=OFF', '-Dlerc=OFF'])
        self.auto('libraw', ['--disable-examples', '--disable-lcms', '--disable-openmp', '--enable-jpeg'],
                  {'CPPFLAGS': f'-I{self.prefix}/include -DUSE_X3FTOOLS'})
        src = source('imagemagick', self.target)
        if not (src / '.xfs-patched').exists():
            for patch in sorted((NATIVE/'imagemagick/patches').glob('*.patch')):
                run(['patch', '-p1', '-i', patch], cwd=src)
            (src / '.xfs-patched').touch()
        ios_patch = ROOT/'patches/imagemagick-ios.patch'
        if not (src/'.xfs-ios-patched').exists():
            run(['patch', '-p1', '-i', ios_patch], cwd=src)
            (src/'.xfs-ios-patched').touch()
        self.auto('imagemagick', ['--without-modules', '--without-utilities', '--disable-pipes', '--disable-openmp', '--without-perl', '--without-x', '--without-fontconfig', '--without-freetype', '--without-heic', '--without-xml', '--without-openexr', '--without-lcms', '--without-lqr', '--with-raw', '--without-rsvg', '--without-gslib', '--without-djvu', '--without-fftw', '--without-pango', '--without-gvc', '--without-jxl', '--without-openjp2', '--without-zip', '--without-lzma', '--without-zstd', '--disable-docs', '--without-magick-plus-plus'], {'ac_cv_func_execvp':'no', 'ac_cv_func_popen':'no', 'ac_cv_func_fork':'no'})

    def rust(self, name):
        if name == 'oxipng':
            src = NATIVE/'oxipng/ffi'
            args = []
            lib = 'oxipng'
        else:
            src = source('resvg', 'common')/'crates/c-api'
            # The C API requires all font features; scanning remains an explicit API call.
            args = []
            lib = 'resvg'
        env = dict(self.env, CARGO_TARGET_DIR=str(WORK/'rust-target'), CARGO_PROFILE_RELEASE_DEBUG='1', CARGO_PROFILE_RELEASE_STRIP='none')
        run(['rustup', 'target', 'add', self.rust_target], env=env)
        run(['cargo', 'build', '--release', '--locked', '--manifest-path', src/'Cargo.toml', '--target', self.rust_target, *args], env=env, cwd=NATIVE.parent)
        dest = self.base/'rust'/name
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copy2(WORK/'rust-target'/self.rust_target/'release'/('lib'+lib+'.dylib'), self.prefix/'lib'/('lib'+lib+'.dylib'))
        headers = dest/'include'
        headers.mkdir(exist_ok=True)
        shutil.copy2(src/('include/oxipng.h' if name=='oxipng' else 'resvg.h'), headers)
        shutil.copy2(headers/(name+'.h'), self.prefix/'include'/(name+'.h'))

    def media(self):
        self.cmake('libwebp', ['-DWEBP_BUILD_ANIM_UTILS=OFF', '-DWEBP_BUILD_CWEBP=OFF', '-DWEBP_BUILD_DWEBP=OFF', '-DWEBP_BUILD_GIF2WEBP=OFF', '-DWEBP_BUILD_IMG2WEBP=OFF', '-DWEBP_BUILD_VWEBP=OFF', '-DWEBP_BUILD_WEBPINFO=OFF', '-DWEBP_BUILD_WEBPMUX=OFF', '-DWEBP_BUILD_EXTRAS=OFF'])
        self.cmake('libpng', ['-DPNG_FRAMEWORK=OFF', '-DPNG_SHARED=ON', '-DPNG_STATIC=OFF', '-DPNG_TESTS=OFF', '-DPNG_TOOLS=OFF'])
        self.cmake('freetype', ['-DFT_DISABLE_BZIP2=ON', '-DFT_DISABLE_BROTLI=ON', '-DFT_DISABLE_HARFBUZZ=ON'])
        self.meson('fribidi', ['-Ddocs=false', '-Dbin=false', '-Dtests=false'])
        self.meson('harfbuzz', ['-Dtests=disabled', '-Ddocs=disabled', '-Dutilities=disabled', '-Dglib=disabled', '-Dgobject=disabled', '-Dcairo=disabled', '-Dicu=disabled', '-Dcoretext=enabled', '-Dfreetype=enabled'])
        self.auto('libass', ['--disable-test', '--disable-fontconfig', '--enable-coretext'])
        self.cmake('uchardet', ['-DBUILD_BINARY=OFF'])
        self.meson('dav1d', ['-Denable_tools=false', '-Denable_tests=false'])
        self.cmake('libogg', ['-DBUILD_TESTING=OFF'])
        self.cmake('libvorbis', ['-DBUILD_TESTING=OFF'])
        self.cmake('opus', ['-DOPUS_BUILD_TESTING=OFF', '-DOPUS_BUILD_PROGRAMS=OFF'])
        self.auto('lame', ['--disable-frontend'])
        self.cmake('libxml2', ['-DLIBXML2_WITH_PYTHON=OFF', '-DLIBXML2_WITH_PROGRAMS=OFF', '-DLIBXML2_WITH_TESTS=OFF', '-DLIBXML2_WITH_LZMA=OFF', '-DLIBXML2_WITH_ICONV=OFF'])
        def vpx():
            src = source('libvpx', self.target)
            build = self.base/'build/libvpx'; build.mkdir(parents=True, exist_ok=True)
            env = dict(self.env, CC='clang '+self.env['CFLAGS'], CXX='clang++ '+self.env['CXXFLAGS'], AS='clang '+self.env['CFLAGS'])
            run([src/'configure', '--target=arm64-darwin-gcc', '--prefix='+str(self.prefix), '--enable-static', '--disable-shared', '--enable-pic', '--disable-examples', '--disable-tools', '--disable-docs', '--disable-unit-tests', '--disable-install-bins'], cwd=build, env=env)
            run(['make', '-j'+JOBS], cwd=build, env=env); run(['make', 'install'], cwd=build, env=env)
        self.done('libvpx', vpx)
        def ffmpeg():
            src = source('ffmpeg', self.target)
            patch = NATIVE/'ffmpeg/patches/ffmpeg-tls-securetransport-no-private-api.patch'
            if not (src/'.xfs-patched').exists():
                run(['patch', '-p1', '-i', patch], cwd=src)
                run(['patch', '-p1', '-i', ROOT/'patches/ffmpeg-embedded-cli.patch'], cwd=src)
                (src/'.xfs-patched').touch()
            build = self.base/'build/ffmpeg'; build.mkdir(parents=True, exist_ok=True)
            # fftools builds bin2c for the build host. Target flags already
            # carry the iOS SDK, so keep host tools out of the iOS environment.
            env = self.env.copy()
            env.pop('SDKROOT', None)
            env.pop('IPHONEOS_DEPLOYMENT_TARGET', None)
            host_sdk = output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
            host_flags = '-isysroot '+host_sdk
            run([src/'configure', '--prefix='+str(self.prefix), '--enable-cross-compile', '--target-os=darwin', '--arch=aarch64', '--cc=clang', '--cxx=clang++', '--sysroot='+self.sdkpath,
                 '--host-cflags='+host_flags, '--host-ldflags='+host_flags, '--extra-cflags='+self.env['CFLAGS']+' -I'+str(self.prefix/'include'), '--extra-ldflags='+self.env['LDFLAGS'], '--pkg-config=pkg-config', '--pkg-config-flags=--static',
                 '--enable-shared', '--disable-static', '--disable-stripping', '--enable-ffmpeg', '--disable-ffprobe', '--disable-ffplay', '--disable-doc', '--disable-autodetect', '--disable-gpl', '--disable-nonfree', '--disable-version3', '--enable-pic', '--disable-outdevs', '--disable-indevs',
                 '--enable-libmp3lame', '--enable-libvorbis', '--enable-libvpx', '--enable-libwebp', '--enable-libopus', '--enable-libxml2', '--enable-libass', '--enable-libdav1d', '--enable-videotoolbox', '--enable-audiotoolbox', '--enable-zlib', '--enable-network', '--enable-securetransport'], cwd=build, env=env)
            run(['make', '-j'+JOBS, 'install-libs', 'install-headers'], cwd=build, env=env)
            cli = self.prefix/'lib/libxfs_ffmpeg_cli.dylib'
            run(['make', '-j'+JOBS, '-f', 'Makefile', '-f', ROOT/'ffmpeg-cli.mk',
                 'XFS_CLI_OUTPUT='+str(cli), 'xfs-ffmpeg-cli'], cwd=build, env=env)
        self.done('ffmpeg', ffmpeg)
        self.meson('libplacebo', ['-Ddemos=false', '-Dtests=false', '-Dvulkan=disabled', '-Dopengl=enabled', '-Dd3d11=disabled', '-Dglslang=disabled', '-Dshaderc=disabled', '-Dlcms=disabled', '-Ddovi=disabled', '-Dlibdovi=disabled', '-Dunwind=disabled', '-Dxxhash=disabled'])
        src = source('mpv', self.target)
        if not (src/'.xfs-patched').exists():
            for name in ['libmpv-hevc-alpha-output.patch', 'libmpv-041-common-fixes.patch']:
                run(['patch', '-p1', '-i', NATIVE/'media_runtime/patches'/name], cwd=src)
            (src/'.xfs-patched').touch()
        self.meson('mpv', ['-Dauto_features=disabled', '-Dgpl=false', '-Dcplayer=false', '-Dlibmpv=true', '-Dbuild-date=false', '-Dtests=false', '-Diconv=enabled', '-Duchardet=enabled', '-Dzlib=enabled', '-Daudiounit=enabled', '-Dgl=enabled', '-Dplain-gl=enabled', '-Dios-gl=enabled', '-Dcocoa=disabled', '-Dswift-build=disabled', '-Dvulkan=disabled'])


def make_dsym(binary, dsym):
    # rustc removes temporary rlib extraction directories after linking. The
    # original archive remains in deps/; restore only these work-local paths
    # so dsymutil can recover libdeflate's C debug information as well.
    if binary.name in ['oxipng', 'resvg']:
        debug = subprocess.run(['dsymutil', '--dump-debug-map', str(binary)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               text=True, check=True)
        missing = set(re.findall(r'warning: \([^)]*\) (.+/deps/rustc[^/]+)/([^/(]+\.rlib)\(', debug.stderr))
        for directory, archive in missing:
            temp = Path(directory)
            original = temp.parent/archive
            if temp.is_relative_to(WORK/'rust-target') and original.is_file():
                temp.mkdir(exist_ok=True)
                if not (temp/archive).exists(): (temp/archive).symlink_to(original)
    if dsym.exists(): shutil.rmtree(dsym)
    run(['dsymutil', binary, '-o', dsym])


def framework_name(path):
    base = re.sub(r'(\.\d+)*\.dylib$', '', path.name)
    return re.sub(r'[^A-Za-z0-9_]', '_', base.removeprefix('lib'))


def package(components):
    validate_package_inputs(components)
    stage = DIST/'xfilesuite-ios'
    if stage.exists(): shutil.rmtree(stage)
    stage.mkdir(parents=True)
    framework_root = stage/'Frameworks'; framework_root.mkdir()
    # Dynamic libraries are shared across the image/media groups. Package exactly once.
    maps = {}
    for target in TARGETS:
        maps[target] = {p.name: framework_name(p.resolve()) for p in (WORK/target/'prefix/lib').glob('*.dylib')}
    names = set(maps['device'].values())
    if names != set(maps['simulator'].values()): raise RuntimeError('Device/simulator dynamic library mismatch')
    for name in sorted(names):
        args = ['xcodebuild', '-create-xcframework']
        for target in TARGETS:
            prefix = WORK/target/'prefix'
            libs = [p for p in (prefix/'lib').glob('*.dylib') if framework_name(p.resolve())==name and not p.is_symlink()]
            if len(libs)!=1: raise RuntimeError(f'Ambiguous dynamic library {target}/{name}: {libs}')
            framework = WORK/target/'frameworks'/(name+'.framework')
            if framework.exists(): shutil.rmtree(framework)
            framework.mkdir(parents=True)
            binary = framework/name
            shutil.copy2(libs[0], binary)
            run(['install_name_tool', '-id', f'@rpath/{name}.framework/{name}', binary])
            for dep in output(['otool', '-L', binary]).splitlines()[2:]:
                dep = dep.strip().split(' (')[0]
                base = Path(dep).name
                if base in maps[target]:
                    dest = maps[target][base]
                    run(['install_name_tool', '-change', dep, f'@rpath/{dest}.framework/{dest}', binary])
                elif not dep.startswith(('/System/Library/', '/usr/lib/')):
                    raise RuntimeError('Unpackaged dependency: '+dep)
            # Preserve include directory structure, including cross-library includes.
            if name == 'xfs_ffmpeg_cli':
                headers = framework/'Headers'
                headers.mkdir()
                shutil.copy2(ROOT/'ffmpeg-cli.h', headers)
            else:
                shutil.copytree(prefix/'include', framework/'Headers')
            plist = dict(CFBundleExecutable=name, CFBundleIdentifier='com.xfilesuite.native.'+name.replace('_','-'), CFBundleName=name, CFBundlePackageType='FMWK', CFBundleVersion='1', CFBundleShortVersionString='1.0', MinimumOSVersion=MIN_IOS, CFBundleSupportedPlatforms=['iPhoneOS' if target=='device' else 'iPhoneSimulator'])
            (framework/'Info.plist').write_bytes(plistlib.dumps(plist))
            dsym = framework.with_suffix('.framework.dSYM')
            make_dsym(binary, dsym)
            args += ['-framework', framework, '-debug-symbols', dsym]
        args += ['-output', framework_root/(name+'.xcframework')]
        run(args)
    resources = stage/'Resources'; resources.mkdir()
    configs = WORK/'device/prefix/etc/ImageMagick-7'
    if configs.exists(): shutil.copytree(configs, resources/'ImageMagick-7')
    metadata = stage/'metadata'; metadata.mkdir()
    for target in TARGETS:
        records = metadata/target
        records.mkdir()
        checks = {}
        if 'imagemagick' in components:
            checks['imagemagick'] = (WORK/target/'build/imagemagick/config/config.h',
                {**{x+'_DELEGATE':1 for x in ['JPEG','PNG','TIFF','WEBP','RAW_R']}})
        if 'media' in components:
            checks['ffmpeg'] = (WORK/target/'build/ffmpeg/config.h',
                {**{'CONFIG_'+x:1 for x in ['LIBASS','LIBDAV1D','LIBVPX','LIBMP3LAME','LIBVORBIS','LIBOPUS','LIBWEBP','LIBXML2','SECURETRANSPORT','VIDEOTOOLBOX','AUDIOTOOLBOX']}, **{'CONFIG_'+x:0 for x in ['GPL','NONFREE','VERSION3']}})
            checks['mpv'] = (WORK/target/'build/mpv/config.h',
                {'HAVE_AUDIOUNIT':1, 'HAVE_IOS_GL':1, 'HAVE_GPL':0, 'HAVE_COCOA':0})
        for name,(config,expected) in checks.items():
            text = config.read_text()
            for key,value in expected.items():
                if not re.search(r'^#define '+key+' '+str(value)+r'$', text, re.M):
                    raise RuntimeError(f'{target}/{name}: unexpected feature {key}')
            shutil.copy2(config, records/(name+'-config.h'))
        if 'imagemagick' in components:
            library = WORK/target/'prefix/lib/libMagickCore-7.Q16HDRI.dylib'
            undefined = output(['nm','-u',library])
            if re.search(r'\b_(fork|execvp|popen|system|getentropy)\b',undefined):
                raise RuntimeError('ImageMagick references an unavailable process/random API')
        if 'media' in components:
            library = WORK/target/'prefix/lib/libavformat.dylib'
            if '_SecIdentityCreate' in output(['nm','-u',library]):
                raise RuntimeError('FFmpeg references private SecIdentityCreate')
    shutil.copy2(ROOT/'sources.lock.json', metadata)
    shutil.copy2(NATIVE/'oxipng/ffi/Cargo.lock', metadata/'oxipng-Cargo.lock')
    resvg_lock = WORK/'common/sources/resvg/Cargo.lock'
    if resvg_lock.exists(): shutil.copy2(resvg_lock, metadata/'resvg-Cargo.lock')
    (metadata/'BUILDINFO.json').write_text(json.dumps(dict(minimumIOS=MIN_IOS, targets=TARGETS, components=components, recipe=recipe_digest(), xcode=output(['xcodebuild','-version']), rust=output(['rustc','--version']), meson=output(['meson','--version']), frameworks=sorted(p.name for p in framework_root.iterdir())), indent=2)+'\n')
    licenses = stage/'licenses'; licenses.mkdir()
    for name in sources():
        for target in ['device','common']:
            src = WORK/target/'sources'/name
            if not src.exists(): continue
            dest = licenses/name; dest.mkdir(exist_ok=True)
            for p in src.rglob('*'):
                if p.is_file() and (p.name.upper().startswith(('LICENSE','COPYING','COPYRIGHT','NOTICE','FTL','GPL','LGPL'))):
                    out = dest/p.relative_to(src); out.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(p,out)
            break
    shutil.copy2(NATIVE/'oxipng/LICENSE', licenses/'OXIPNG-LICENSE.txt')
    native_licenses = {'imagemagick':'ImageMagick', 'libraw':'LGPL-2.1-only OR CDDL-1.0', 'mozjpeg':'BSD-style/IJG', 'libpng':'Libpng', 'libwebp':'BSD-3-Clause', 'libtiff':'libtiff', 'ffmpeg':'LGPL-2.1-or-later', 'mpv':'LGPL-2.1-or-later', 'libplacebo':'LGPL-2.1-or-later', 'libass':'ISC', 'freetype':'FTL OR GPL-2.0-only', 'fribidi':'LGPL-2.1-or-later', 'harfbuzz':'MIT', 'uchardet':'MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later', 'dav1d':'BSD-2-Clause', 'libogg':'BSD-3-Clause', 'libvorbis':'BSD-3-Clause', 'opus':'BSD-3-Clause', 'lame':'LGPL-2.0-or-later', 'libvpx':'BSD-3-Clause', 'libxml2':'MIT', 'resvg':'MIT OR Apache-2.0', 'libplacebo-vulkan-headers':'Apache-2.0', 'libplacebo-jinja':'BSD-3-Clause', 'libplacebo-markupsafe':'BSD-3-Clause', 'libplacebo-glad':'MIT', 'libplacebo-fast-float':'MIT OR Apache-2.0 OR BSL-1.0'}
    native_sources = [dict(spec, license=native_licenses[name]) for name,spec in sources().items()]
    sbom = {'schemaVersion': 1, 'platform': 'ios', 'sources': native_sources, 'rustPackages': []}
    for name in ['oxipng', 'resvg']:
        if name not in components: continue
        manifest = NATIVE/'oxipng/ffi/Cargo.toml' if name=='oxipng' else WORK/'common/sources/resvg/crates/c-api/Cargo.toml'
        env = os.environ.copy()
        data = json.loads(subprocess.check_output(['cargo','metadata','--locked','--format-version=1','--manifest-path',str(manifest),'--filter-platform','aarch64-apple-ios'],env=env,cwd=NATIVE.parent,text=True))
        for crate in data['packages']:
            sbom['rustPackages'].append({key:crate.get(key) for key in ['name','version','license','source']})
            src = Path(crate['manifest_path']).parent
            dest = licenses/'rust'/(crate['name']+'-'+crate['version'])
            for file in src.iterdir():
                if file.is_file() and file.name.upper().startswith(('LICENSE','COPYING','COPYRIGHT','NOTICE')):
                    dest.mkdir(parents=True,exist_ok=True); shutil.copy2(file,dest/file.name)
    (metadata/'SBOM.json').write_text(json.dumps(sbom,indent=2)+'\n')
    run([sys.executable, ROOT/'verify.py', stage])
    if set(components)=={'imagemagick','media','oxipng','resvg'}:
        run([sys.executable, ROOT/'smoke-link.py', stage])
    (metadata/'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.relative_to(stage)}\n' for p in sorted(stage.rglob('*')) if p.is_file() and p.name!='SHA256SUMS'))
    archive = DIST/'xfilesuite-ios.tar.gz'
    run(['tar','-czf',archive,'-C',stage,'.'])
    archive.with_name(archive.name+'.sha256').write_text(digest(archive)+'  '+archive.name+'\n')
    print('Prepared:', stage, flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--components', nargs='+', choices=['imagemagick','media','oxipng','resvg'], default=['imagemagick','media','oxipng','resvg'])
    parser.add_argument('--targets', nargs='+', choices=list(TARGETS), default=list(TARGETS))
    parser.add_argument('--package-only', action='store_true')
    parser.add_argument('--no-package', action='store_true')
    args=parser.parse_args()
    if args.package_only and args.no_package:
        parser.error('--package-only cannot be combined with --no-package')
    if not args.no_package and (set(args.components)!=set(COMPONENTS) or set(args.targets)!=set(TARGETS)):
        parser.error('Packaging requires all components and both targets; use --no-package for targeted builds')
    WORK.mkdir(parents=True, exist_ok=True); DIST.mkdir(parents=True, exist_ok=True)
    if not args.package_only:
        for target in args.targets:
            build=Build(target)
            for component in args.components:
                if component=='imagemagick': build.images()
                elif component=='media': build.media()
                else: build.rust(component)
    if not args.no_package:
        if set(args.targets)!=set(TARGETS): parser.error('Packaging requires both device and simulator slices; use --no-package for one target')
        package(args.components)


if __name__=='__main__': main()
