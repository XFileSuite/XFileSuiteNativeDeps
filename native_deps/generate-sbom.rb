#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates a JSON SBOM (Software Bill of Materials) from a native-deps
# manifest file. The SBOM lists every distributed component with its
# version, license, checksum, and source-release location.
#
# Usage: ruby generate-sbom.rb <manifest.json> [output.json]

require 'json'
require 'time'

# Static license mapping for all known components. Keys match the
# component names used in manifest JSON files.
LICENSES = {
  'ffmpeg'        => 'LGPL-2.1',
  'lame'          => 'LGPL-2.0',
  'libogg'        => 'BSD-3-Clause',
  'libvorbis'     => 'BSD-3-Clause',
  'libvpx'        => 'BSD-3-Clause',
  'libwebp'       => 'BSD-3-Clause',
  'libopus'       => 'BSD-3-Clause',
  'mpv'           => 'LGPL-2.1',
  'libplacebo'    => 'LGPL-2.1',
  'libass'        => 'ISC',
  'dav1d'         => 'BSD-2-Clause',
  'freetype'      => 'FTL',
  'fribidi'       => 'LGPL-2.1',
  'harfbuzz'      => 'MIT',
  'mbedtls'       => 'Apache-2.0',
  'libxml2'       => 'MIT',
  'libpng'        => 'BSD-2-Clause',
  'uchardet'      => 'MPL-2.0',
  'imagemagick'   => 'ImageMagick License',
  'mozjpeg'       => 'BSD-3-Clause',
  'libtiff'       => 'MIT',
  'giflib'        => 'MIT',
  'resvg'         => 'Apache-2.0 OR MIT',
  'mediaRuntime'  => 'LGPL-2.1 (aggregate: FFmpeg LGPL-2.1, mpv LGPL-2.1, libplacebo LGPL-2.1, libass ISC, dav1d BSD-2-Clause, FreeType FTL, FriBidi LGPL-2.1, HarfBuzz MIT, Mbed TLS Apache-2.0, libxml2 MIT, libpng BSD-2-Clause, uchardet MPL-2.0, LAME LGPL-2.0, Opus BSD-3-Clause, libogg BSD-3-Clause, libvorbis BSD-3-Clause, libvpx BSD-3-Clause, libwebp BSD-3-Clause)'
}.freeze

# Sub-components bundled inside the media runtime aggregate.
MEDIA_RUNTIME_SUBCOMPONENTS = %w[
  ffmpeg mpv libplacebo libass dav1d freetype fribidi harfbuzz
  mbedtls libxml2 libpng uchardet lame libopus libogg libvorbis
  libvpx libwebp
].freeze

# Sub-components bundled inside the FFmpeg standalone binary.
FFMPEG_SUBCOMPONENTS = %w[lame libogg libvorbis libvpx libwebp libopus].freeze

# Sub-components bundled inside the ImageMagick macOS binary.
IMAGEMAGICK_MACOS_SUBCOMPONENTS = %w[mozjpeg libpng libwebp libtiff giflib].freeze

def subcomponents_for(name, platform)
  case name
  when 'mediaRuntime'
    MEDIA_RUNTIME_SUBCOMPONENTS.map { |s| { 'name' => s, 'license' => LICENSES.fetch(s, 'unknown') } }
  when 'ffmpeg'
    FFMPEG_SUBCOMPONENTS.map { |s| { 'name' => s, 'license' => LICENSES.fetch(s, 'unknown') } }
  when 'imagemagick'
    if platform == 'macos'
      IMAGEMAGICK_MACOS_SUBCOMPONENTS.map { |s| { 'name' => s, 'license' => LICENSES.fetch(s, 'unknown') } }
    else
      []
    end
  else
    []
  end
end

manifest_path = ARGV.fetch(0)
output_path = ARGV[1]

manifest = JSON.parse(File.read(manifest_path))
platform = manifest.fetch('platform')
components = manifest.fetch('components')

sbom_components = components.map do |name, info|
  entry = {
    'name' => name,
    'version' => info['version'],
    'releaseRevision' => info['releaseRevision'],
    'architecture' => info['architecture'],
    'license' => LICENSES.fetch(name, 'unknown'),
    'r2Key' => info['r2Key'],
    'sourceRelease' => info['sourceRelease'],
    'subComponents' => subcomponents_for(name, platform)
  }
  if info.key?('binarySha256')
    entry['binarySha256'] = info['binarySha256']
  elsif info.key?('bundleSha256')
    entry['bundleSha256'] = info['bundleSha256']
  end
  entry
end

sbom = {
  'sbomVersion' => '1.0',
  'generatedAt' => Time.now.utc.iso8601,
  'platform' => platform,
  'manifestId' => manifest['manifestId'],
  'components' => sbom_components
}

json = JSON.pretty_generate(sbom) + "\n"

if output_path
  File.write(output_path, json)
  warn "SBOM written to #{output_path}"
else
  puts json
end
