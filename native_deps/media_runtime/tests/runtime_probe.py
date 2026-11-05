#!/usr/bin/env python3
"""Exercise the packaged libmpv ABI, local TLS policy and playback lifecycle."""
import argparse
import ctypes as c
import functools
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import struct
import zlib
import tempfile
import threading
import time


class Event(c.Structure):
    _fields_ = [('id', c.c_int), ('error', c.c_int),
                ('userdata', c.c_uint64), ('data', c.c_void_p)]


class EndFile(c.Structure):
    _fields_ = [('reason', c.c_int), ('error', c.c_int)]


class Log(c.Structure):
    _fields_ = [('prefix', c.c_char_p), ('level', c.c_char_p),
                ('text', c.c_char_p), ('log_level', c.c_int)]


class Player:
    def __init__(self, lib, options=None):
        self.lib = lib
        self.errors = []
        self.handle = lib.mpv_create()
        if not self.handle:
            raise RuntimeError('mpv_create failed')
        for key, value in {'vo': 'null', 'ao': 'null', 'keep-open': 'yes',
                           'pause': 'no', 'network-timeout': '4', **(options or {})}.items():
            self.check(lib.mpv_set_option_string(self.handle, key.encode(), value.encode()), key)
        self.check(lib.mpv_request_log_messages(self.handle, b'warn'), 'log subscription')
        self.check(lib.mpv_initialize(self.handle), 'initialize')

    @staticmethod
    def check(result, name):
        if result < 0:
            raise RuntimeError(f'{name}: mpv error {result}')

    def get(self, key):
        pointer = self.lib.mpv_get_property_string(self.handle, key.encode())
        if not pointer:
            return None
        try:
            return c.string_at(pointer).decode()
        finally:
            self.lib.mpv_free(pointer)

    def command(self, *args):
        values = (c.c_char_p * (len(args) + 1))(*[str(v).encode() for v in args], None)
        self.check(self.lib.mpv_command(self.handle, values), str(args[0]))

    def load(self, url, timeout=10):
        # Drain old completion events before starting the next source.
        while self.lib.mpv_wait_event(self.handle, 0).contents.id:
            pass
        self.command('loadfile', url)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            event = self.lib.mpv_wait_event(self.handle, .05).contents
            if event.id == 2 and event.data:
                entry = c.cast(event.data, c.POINTER(Log)).contents
                self.errors.append(entry.prefix.decode() + ': ' + entry.text.decode().strip())
            if event.id == 8:  # MPV_EVENT_FILE_LOADED
                return True
            if event.id == 7 and event.data:
                end = c.cast(event.data, c.POINTER(EndFile)).contents
                if end.reason == 4 or end.error < 0:
                    return False
        raise AssertionError('Timed out loading source')

    def close(self):
        self.lib.mpv_terminate_destroy(self.handle)
        self.handle = None


def library(path):
    if os.name == 'nt':
        # Keep this directory handle alive while the library is loaded.
        library.dll_directory = os.add_dll_directory(str(path.resolve().parent))
    lib = c.CDLL(str(path.resolve()))
    lib.mpv_create.restype = c.c_void_p
    for name in ['mpv_initialize', 'mpv_terminate_destroy']:
        getattr(lib, name).argtypes = [c.c_void_p]
    lib.mpv_request_log_messages.argtypes = [c.c_void_p, c.c_char_p]
    lib.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
    lib.mpv_get_property_string.argtypes = [c.c_void_p, c.c_char_p]
    lib.mpv_get_property_string.restype = c.c_void_p
    lib.mpv_free.argtypes = [c.c_void_p]
    lib.mpv_command.argtypes = [c.c_void_p, c.POINTER(c.c_char_p)]
    lib.mpv_wait_event.argtypes = [c.c_void_p, c.c_double]
    lib.mpv_wait_event.restype = c.POINTER(Event)
    return lib


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def server(directory, certificate=None):
    handler = functools.partial(QuietHandler, directory=str(directory))
    httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    httpd.daemon_threads = True
    if certificate:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(certificate) + '.crt', str(certificate) + '.key')
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd


def certificates(directory):
    def openssl(*args):
        env = {**os.environ, 'MSYS2_ARG_CONV_EXCL': '*'}
        subprocess.run(['openssl', *args], cwd=directory, env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
            '-keyout', 'ca.key', '-out', 'ca.crt', '-subj', '/CN=XFileSuite runtime test CA')
    for name, host, days in [('valid', 'localhost', '2'), ('wrong-host', 'wrong.local', '2'),
                             ('expired', 'localhost', '-1')]:
        openssl('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', name + '.key',
                '-out', name + '.csr', '-subj', '/CN=' + host)
        ip = ',IP:127.0.0.1' if host == 'localhost' else ''
        (directory / 'extensions.cnf').write_text(
            'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n'
            'subjectAltName=DNS:' + host + ip + '\n')
        if name == 'expired':
            (directory / 'index.txt').write_text('')
            (directory / 'serial').write_text('1000\n')
            (directory / 'ca.cnf').write_text(
                '[ca]\ndefault_ca=issuer\n[issuer]\ndatabase=index.txt\n'
                'serial=serial\nnew_certs_dir=.\ncertificate=ca.crt\n'
                'private_key=ca.key\ndefault_md=sha256\npolicy=names\n'
                '[names]\ncommonName=supplied\n[server_cert]\n' +
                (directory / 'extensions.cnf').read_text())
            openssl('ca', '-batch', '-config', 'ca.cnf', '-extensions', 'server_cert',
                    '-startdate', '20200101000000Z', '-enddate', '20200102000000Z',
                    '-in', name + '.csr', '-out', name + '.crt')
        else:
            openssl('x509', '-req', '-in', name + '.csr', '-CA', 'ca.crt', '-CAkey', 'ca.key',
                    '-CAcreateserial', '-days', days, '-out', name + '.crt',
                    '-extfile', 'extensions.cnf')


def run(args):
    lib = library(Path(args.library))
    fixture = Path(__file__).with_name('fixtures') / 'tone.wav'
    results = []
    options = {'tls-verify': 'yes'} if args.force_tls_verify else {}
    player = Player(lib, options)
    try:
        assert player.get('mpv-version').startswith('mpv v0.41.0'), 'Unexpected mpv version'
        assert player.get('tls-verify') == 'yes', 'TLS verification must be enabled'
        for _ in range(6):
            assert player.load(str(fixture.resolve()))
            player.command('seek', '.25', 'absolute')
            player.command('stop')
        results.append('local WAV playback, repeated load/seek/stop')
    finally:
        player.close()
    with tempfile.TemporaryDirectory(prefix='xfs-media-tls-') as temp:
        directory = Path(temp)
        (directory / 'tone.wav').write_bytes(fixture.read_bytes())
        # A small still frame exercises CPU subtitle blending at slice edges.
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        png = (b'\x89PNG\r\n\x1a\n' +
               chunk(b'IHDR', struct.pack('>IIBBBBB', 78, 64, 8, 2, 0, 0, 0)) +
               chunk(b'IDAT', zlib.compress((b'\0' + b'\0' * (78 * 3)) * 64)) +
               chunk(b'IEND', b''))
        (directory / 'small.png').write_bytes(png)
        (directory / 'caption.srt').write_text('1\n00:00:00,000 --> 00:00:02,000\nedge subtitle\n')
        player = Player(lib, {**options, 'sub-files': str(directory / 'caption.srt'),
                              'sub-visibility': 'yes', 'sub-font-size': '12',
                              'image-display-duration': '10'})
        try:
            assert player.load(str(directory / 'small.png'))
            time.sleep(.25)
            output = directory / 'screenshot.png'
            player.command('screenshot-to-file', output, 'subtitles')
            deadline = time.monotonic() + 3
            while not output.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            assert output.exists(), 'Small-frame subtitle screenshot failed: ' + '; '.join(player.errors)
            data = output.read_bytes()
            assert data.startswith(b'\x89PNG') and struct.unpack('>II', data[16:24]) == (78, 64)
            results.append('78x64 subtitle screenshot produced valid PNG dimensions')
        finally:
            player.close()
        # Metadata entries with a non-matching stream index stay harmless.
        edl = directory / 'metadata.edl'
        edl.write_text('# mpv EDL v0\n!track_meta,index=999,title=fixture\ntone.wav\n')
        player = Player(lib, options)
        try:
            assert player.load(str(edl)), 'EDL metadata source failed'
            results.append('EDL metadata track loaded without abort')
        finally:
            player.close()

        certificates(directory)
        httpd = server(directory)
        try:
            player = Player(lib, options)
            try:
                assert player.load(f'http://127.0.0.1:{httpd.server_port}/tone.wav')
            finally:
                player.close()
            results.append('plain HTTP control')
        finally:
            httpd.shutdown(); httpd.server_close()
        for name in ['valid', 'wrong-host', 'expired']:
            httpd = server(directory, directory / name)
            try:
                url = f'https://localhost:{httpd.server_port}/tone.wav'
                player = Player(lib, options)
                try:
                    assert not player.load(url), 'Untrusted certificate was accepted'
                finally:
                    player.close()
                results.append(name + ': untrusted chain rejected')
                # FFmpeg SecureTransport accepts a custom CA file. SChannel's
                # system store is tested separately without installing a test root.
                if os.name != 'nt':
                    player = Player(lib, {**options, 'tls-ca-file': str(directory / 'ca.crt'),
                                          # Only this isolated fixture may read its generated CA.
                                          'stream-lavf-o': 'protocol_whitelist=[file,http,https,tls,tcp,udp,crypto,httpproxy]'})
                    try:
                        assert player.load(url) == (name == 'valid'), name + ': CA/hostname/date policy: ' + '; '.join(player.errors)
                    finally:
                        player.close()
                    results.append(name + ': explicit CA policy verified')
            finally:
                httpd.shutdown(); httpd.server_close()
    if args.trusted_url:
        player = Player(lib, options)
        try:
            assert player.load(args.trusted_url, timeout=25), 'System-trusted HTTPS failed'
            results.append('system-trusted HTTPS playback')
        finally:
            player.close()
    print(json.dumps({'passed': results, 'platform': os.name}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('library')
    parser.add_argument('--force-tls-verify', action='store_true',
                        help='Preflight existing runtime before changing its default')
    parser.add_argument('--trusted-url')
    run(parser.parse_args())
