# Rebuild RS_ShieldSaw.zip from the working tree.
#
# The zip is what gets LOADED -- a launcher config points at it by path -- so
# deleting it breaks the launch with "wad not found", and editing the loose
# files without rebuilding means you are testing the old code. Run this after
# any change you want to see in game.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$out = Join-Path $PSScriptRoot 'RS_ShieldSaw.zip'
if (Test-Path $out) { Remove-Item $out }
$stage = Join-Path $env:TEMP 'ss_stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
Get-ChildItem -Force | Where-Object {
    $_.Name -notin @('.git', '.gitignore', 'RS_ShieldSaw.zip', 'build.ps1')
} | ForEach-Object { Copy-Item $_.FullName -Destination $stage -Recurse -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $out -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force
"RS_ShieldSaw.zip  {0:N1} MB" -f ((Get-Item $out).Length / 1MB)
