$ErrorActionPreference = 'Stop'
$version = '10.2.0'
$scriptDir = $PSScriptRoot
$distDir = Join-Path $scriptDir 'dist-windows'
$ffiDir = Join-Path $scriptDir 'ffi'
$workDir = Join-Path $scriptDir 'work\ffi-windows'
$target = 'x86_64-pc-windows-msvc'
$licenseFile = Join-Path $scriptDir 'LICENSE'

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
  throw 'Rust cargo is required to build oxipng.dll'
}
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
  throw 'rustup is required to build oxipng.dll'
}

Write-Host 'Building oxipng.dll (C FFI)...'
Remove-Item -Recurse -Force $distDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $workDir | Out-Null
$env:CARGO_TARGET_DIR = Join-Path $workDir 'target'
rustup target add $target
cargo build --release --manifest-path (Join-Path $ffiDir 'Cargo.toml') --target $target

$releaseDir = Join-Path $env:CARGO_TARGET_DIR "$target\release"
$dllPath = Join-Path $releaseDir 'oxipng.dll'
if (-not (Test-Path -PathType Leaf $dllPath)) {
  throw "Missing $dllPath"
}
$libCandidate = @(
  (Join-Path $releaseDir 'oxipng.dll.lib'),
  (Join-Path $releaseDir 'oxipng.lib')
) | Where-Object { Test-Path -PathType Leaf $_ } | Select-Object -First 1
if (-not $libCandidate) {
  throw 'Missing oxipng import library (.lib)'
}

$bundle = Join-Path $distDir 'oxipng-windows-x64'
if (-not (Test-Path -PathType Leaf $licenseFile)) {
  throw "Missing vendored Oxipng LICENSE at $licenseFile"
}
New-Item -ItemType Directory -Force "$bundle\ThirdPartyLicenses\Oxipng" | Out-Null
New-Item -ItemType Directory -Force "$bundle\native-headers\oxipng-$version" | Out-Null
Copy-Item $licenseFile "$bundle\ThirdPartyLicenses\Oxipng\OXIPNG-LICENSE.txt"
Copy-Item $dllPath "$bundle\oxipng.dll"
Copy-Item $libCandidate "$bundle\oxipng.lib"
Copy-Item (Join-Path $ffiDir 'include\oxipng.h') "$bundle\native-headers\oxipng-$version\oxipng.h"
Set-Content -Path "$bundle\native-headers\versions.env" -Value "OXIPNG_VERSION=$version" -NoNewline

Compress-Archive -Path "$bundle\*" -DestinationPath "$distDir\oxipng-$version-windows-x64.zip"

$verifyDir = Join-Path $distDir 'verify'
Expand-Archive "$distDir\oxipng-$version-windows-x64.zip" $verifyDir
if (Test-Path -PathType Leaf "$verifyDir\oxipng.exe") {
  throw 'Packaged Oxipng ZIP must not include oxipng.exe (FFI-only)'
}
if (-not (Test-Path -PathType Leaf "$verifyDir\oxipng.dll")) { throw 'Packaged Oxipng ZIP is missing oxipng.dll' }
if (-not (Test-Path -PathType Leaf "$verifyDir\oxipng.lib")) { throw 'Packaged Oxipng ZIP is missing oxipng.lib' }
if (-not (Test-Path -PathType Leaf "$verifyDir\native-headers\oxipng-$version\oxipng.h")) {
  throw 'Packaged Oxipng ZIP is missing oxipng.h'
}
if (-not (Test-Path -PathType Leaf "$verifyDir\native-headers\versions.env")) {
  throw 'Packaged Oxipng ZIP is missing native-headers/versions.env'
}
if (-not (Test-Path -PathType Leaf "$verifyDir\ThirdPartyLicenses\Oxipng\OXIPNG-LICENSE.txt")) {
  throw 'Packaged Oxipng ZIP has the wrong license layout'
}
Write-Host '✓ oxipng Windows x64 bundle (DLL + headers)'
