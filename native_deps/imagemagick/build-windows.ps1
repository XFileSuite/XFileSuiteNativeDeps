[CmdletBinding()]
param(
  [string] $Version = $env:IMAGEMAGICK_VERSION,
  [string] $WorkDir = "$PSScriptRoot/work-windows",
  [string] $OutputDir = "$PSScriptRoot/dist-windows"
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = '7.1.2-27' }

# ImageMagick's official portable distribution is a complete runtime directory,
# not an exe-only package. Keep its DLLs and configuration next to magick.exe.
$archiveName = "ImageMagick-$Version-portable-Q16-HDRI-x64.7z"
$url = "https://github.com/ImageMagick/ImageMagick/releases/download/$Version/$archiveName"
$archive = Join-Path $WorkDir $archiveName
$expanded = Join-Path $WorkDir 'expanded'
$bundle = Join-Path $OutputDir 'imagemagick-windows-x64'

New-Item -ItemType Directory -Force -Path $WorkDir, $OutputDir | Out-Null
if (-not (Test-Path $archive)) { Invoke-WebRequest -Uri $url -OutFile $archive }
Remove-Item -Recurse -Force $expanded, $bundle -ErrorAction SilentlyContinue
choco install 7zip -y --no-progress --limit-output
& 7z x $archive -o"$expanded" -y | Out-Null

$magick = Get-ChildItem -Path $expanded -Filter magick.exe -Recurse | Select-Object -First 1
if ($null -eq $magick) { throw "magick.exe was not found in $archiveName" }
Copy-Item -Recurse -Force (Split-Path $magick.FullName -Parent) $bundle
& (Join-Path $bundle 'magick.exe') -version

$zip = Join-Path $OutputDir "imagemagick-$Version-windows-x64.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip -CompressionLevel Optimal
(Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant() | Set-Content "$zip.sha256" -NoNewline
