"""Publication checks use small fixtures, without compiling native dependencies."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_metadata', Path(__file__).resolve().parents[1]/'release-metadata.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseMetadataTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)/'native_deps/ios'
        self.metadata = self.root/'dist/xfilesuite-ios/metadata'
        self.metadata.mkdir(parents=True)
        (self.metadata/'BUILDINFO.json').write_text(json.dumps(dict(minimumIOS='15.0', recipe='recipe')))
        (self.metadata/'SBOM.json').write_text('{"platform":"ios"}\n')
        self.archive('xfilesuite-ios.tar.gz', b'runtime')
        self.archive('xfilesuite-ios-source.tar.gz', b'source')

    def archive(self, name, data):
        archive = self.root/'dist'/name
        archive.write_bytes(data)
        archive.with_name(name+'.sha256').write_text(hashlib.sha256(data).hexdigest()+'  '+name+'\n')

    def test_manifest_identifies_exact_runtime_and_source(self):
        result = release.prepare(self.root)
        item = result['components']['iosRuntime']
        self.assertEqual(item['bundleSha256'], hashlib.sha256(b'runtime').hexdigest())
        self.assertIn(item['bundleSha256'], item['r2Key'])
        self.assertEqual(json.loads((self.root.parent/'manifests/ios.json').read_text()), result)
        self.assertEqual((self.root.parent/'sbom-ios.json').read_bytes(), (self.metadata/'SBOM.json').read_bytes())
        self.archive('xfilesuite-ios-source.tar.gz', b'new source')
        updated = release.prepare(self.root)['components']['iosRuntime']
        self.assertEqual(item['r2Key'], updated['r2Key'])
        self.assertNotEqual(item['sourceRelease'], updated['sourceRelease'])

    def test_corrupt_package_cannot_write_manifest(self):
        (self.root/'dist/xfilesuite-ios.tar.gz').write_bytes(b'corrupt')
        with self.assertRaisesRegex(RuntimeError, 'Checksum mismatch'):
            release.prepare(self.root)
        self.assertFalse((self.root.parent/'manifests/ios.json').exists())


if __name__ == '__main__':
    unittest.main()
