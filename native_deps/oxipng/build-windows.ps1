$ErrorActionPreference = 'Stop'
$version = '9.1.5'; $scriptDir = $PSScriptRoot
$downloads = Join-Path $scriptDir 'downloads'; $distDir = Join-Path $scriptDir 'dist-windows'
$name = "oxipng-$version-x86_64-pc-windows-msvc.zip"
$expected = 'd53981683d8b76f3f3e45410158b4bc3bd78f7d936e3620de4b1ea56c9dffa38'
New-Item -ItemType Directory -Force $downloads | Out-Null
$archive = Join-Path $downloads $name
if (-not (Test-Path $archive) -or (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant() -ne $expected) {
  Invoke-WebRequest -Uri "https://github.com/oxipng/oxipng/releases/download/v$version/$name" -OutFile $archive
}
if ((Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant() -ne $expected) { throw 'Official Oxipng archive checksum mismatch' }
$extract = Join-Path $distDir 'official'
Remove-Item -Recurse -Force $distDir -ErrorAction SilentlyContinue
Expand-Archive $archive $extract
$root = Get-ChildItem $extract -Directory | Select-Object -First 1
if (-not $root) { throw 'Official Oxipng archive has no top-level directory' }
$officialBinary = Join-Path $root.FullName 'oxipng.exe'
$officialLicense = Join-Path $root.FullName 'LICENSE.txt'
if (-not (Test-Path -PathType Leaf $officialBinary)) { throw 'Official Oxipng archive is missing oxipng.exe' }
if (-not (Test-Path -PathType Leaf $officialLicense)) { throw 'Official Oxipng archive is missing LICENSE.txt' }
$bundle = Join-Path $distDir 'oxipng-windows-x64'
New-Item -ItemType Directory -Force "$bundle/ThirdPartyLicenses/Oxipng" | Out-Null
Copy-Item $officialBinary "$bundle/oxipng.exe"
Copy-Item $officialLicense "$bundle/ThirdPartyLicenses/Oxipng/OXIPNG-LICENSE.txt"
& "$bundle/oxipng.exe" --version | Select-String -SimpleMatch $version | Out-Null
Compress-Archive -Path "$bundle/*" -DestinationPath "$distDir/oxipng-$version-windows-x64.zip"
$verifyDir = Join-Path $distDir 'verify'
Expand-Archive "$distDir/oxipng-$version-windows-x64.zip" $verifyDir
if (-not (Test-Path -PathType Leaf "$verifyDir/oxipng.exe")) { throw 'Packaged Oxipng ZIP has the wrong executable layout' }
if (-not (Test-Path -PathType Leaf "$verifyDir/ThirdPartyLicenses/Oxipng/OXIPNG-LICENSE.txt")) { throw 'Packaged Oxipng ZIP has the wrong license layout' }
