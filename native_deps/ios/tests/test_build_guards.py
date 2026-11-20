"""Regression checks for preserving verified artifacts and rejecting stale caches."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ios_build', ROOT/'build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class BuildGuardsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.native = Path(self.temp.name)/'native_deps'
        self.root = self.native/'ios'
        self.root.mkdir(parents=True)
        (self.root/'patches').mkdir()
        (self.root/'build.py').write_text('recipe version one\n')
        (self.root/'sources.lock.json').write_text('[]\n')
        for name in ('ffmpeg-cli.mk', 'ffmpeg-cli.h', 'ktx-preview.c', 'ktx-preview.h', 'ktx-blocks.cpp', 'bcdec.h'):
            (self.root/name).write_text('fixture')

        self.work = self.root/'work'
        self.dist = self.root/'dist'
        self.patches = [patch.object(build, key, value) for key,value in
                        [('ROOT', self.root), ('NATIVE', self.native),
                         ('WORK', self.work), ('DIST', self.dist),
                         ('output', lambda args: '/sdk' if '--show-sdk-path' in args else 'test-tool-version')]]
        for mock in self.patches:
            mock.start()
            self.addCleanup(mock.stop)

    def complete_target(self, target):
        base = self.work/target
        (base/'prefix/lib').mkdir(parents=True)
        (base/'BUILD_CONFIG.json').write_text(json.dumps(build.build_config('/sdk')))
        for name in ['imagemagick', 'mpv']:
            (base/('built-'+name)).write_text('ok\n')
        for name in ['oxipng', 'resvg', 'xfs_ffmpeg_cli', 'xfs_ktx']:
            (base/'prefix/lib'/('lib'+name+'.dylib')).write_bytes(b'fixture')

    def test_changed_patch_cannot_reuse_completed_component(self):
        first = build.Build('device')
        first.done('example', lambda: None)
        (self.root/'patches/ios-fix.patch').write_text('updated native patch\n')
        with self.assertRaisesRegex(RuntimeError, 'Build settings changed'):
            build.Build('device')

    def test_shared_oxipng_change_cannot_reuse_completed_component(self):
        ffi = self.native/'oxipng/ffi/src'
        ffi.mkdir(parents=True)
        (ffi/'lib.rs').write_text('version one')
        build.Build('device')
        (ffi/'lib.rs').write_text('version two')
        with self.assertRaisesRegex(RuntimeError, 'Build settings changed'):
            build.Build('device')

    def test_package_only_rejects_changed_minimum_without_destroying_old_package(self):
        for target in build.TARGETS:
            self.complete_target(target)
        stage = self.dist/'xfilesuite-ios'
        stage.mkdir(parents=True)
        sentinel = stage/'verified-artifact'
        sentinel.write_text('keep me')
        with patch.object(build, 'MIN_IOS', '16.0'):
            with self.assertRaisesRegex(RuntimeError, 'Build settings or recipe changed'):
                build.package(build.COMPONENTS)
        self.assertEqual(sentinel.read_text(), 'keep me')

    def test_missing_target_refuses_delivery(self):
        self.complete_target('device')
        with self.assertRaisesRegex(RuntimeError, 'Missing build record'):
            build.validate_package_inputs(build.COMPONENTS)

    def test_partial_delivery_is_rejected_before_building(self):
        with patch('sys.argv', ['build.py', '--components', 'oxipng']):
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as result:
                    build.main()
        self.assertEqual(result.exception.code, 2)
        self.assertFalse(self.work.exists())

    def test_preflight_accepts_both_matching_targets(self):
        for target in build.TARGETS:
            self.complete_target(target)
        build.validate_package_inputs(build.COMPONENTS)


class ToolchainPathTest(unittest.TestCase):
    def test_build_config_uses_rust_from_ci_path(self):
        # CI can install Rust outside ~/.cargo/bin. Exercise actual process
        # lookup with an isolated PATH instead of mocking command output.
        with tempfile.TemporaryDirectory() as directory:
            bindir = Path(directory)
            for tool, version in [('rustc', 'rustc-ci-fixture'),
                                  ('xcodebuild', 'xcode-fixture'),
                                  ('cmake', 'cmake-fixture'),
                                  ('meson', 'meson-fixture')]:
                command = bindir/tool
                command.write_text('#!/bin/sh\necho '+version+'\n')
                command.chmod(0o755)
            with patch.dict(os.environ, {'PATH': directory}), patch.object(build, 'recipe_digest', return_value='fixture'):
                config = build.build_config('/sdk')
            self.assertEqual(config['rust'], 'rustc-ci-fixture')


if __name__ == '__main__':
    unittest.main()
