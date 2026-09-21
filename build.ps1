# Build RS_ShieldSaw.pk3 -- standalone again (2026-09-21).
#
# It lived inside RS_VR_Weapons from 09-14 to 09-21. The owner took it back out so it pairs with
# any weapon pack ("a lightsaber + shieldsaw sounds fuckin awesome"). Every lump, class, cvar and
# sound name is the one the folded build used, so saved settings and bindings carry over.
#
# ITS ONE DEPENDENCY IS RS_BALLISTICS (the deflect look, RSB_Impact.Land) -- the owner's ruling, the
# same day: "it can keep its ballistic profile". It loads after RS_Ballistics and knows nothing of
# any weapon pack. RS_VR_Weapons names it only by string.
#
# ENTRY BY ENTRY with forward slashes and an ALLOWLIST: Compress-Archive (what this script used to
# call, making a .zip) writes backslashes SLADE will not open, and a lump name ignores its
# extension, so a stray file in the root can shadow a real lump.
#
# STAGED, CHECKED, THEN INSTALLED beside this script. A pack with a script error never replaces the
# installed one. -NoCompileCheck packs and stops.
param([switch]$NoCompileCheck)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root   = $PSScriptRoot
$name   = 'RS_ShieldSaw.pk3'
$stage  = Join-Path $env:TEMP 'rs_shieldsaw_stage'
New-Item -ItemType Directory -Force $stage | Out-Null
$out    = Join-Path $stage $name

$lumps = @('zscript.txt', 'MAPINFO.txt', 'MODELDEF.txt', 'CVARINFO.txt', 'MENUDEF.txt', 'KEYCONF.txt',
           'SNDINFO.txt', 'language.txt')
$files = @()
foreach ($l in $lumps) {
    $p = Join-Path $root $l
    if (-not (Test-Path $p)) { throw "missing lump: $l" }
    $files += Get-Item $p
}
$files += Get-ChildItem (Join-Path $root 'zscript') -Recurse -File -Filter *.zs
$files += Get-ChildItem (Join-Path $root 'sprites') -File -Filter *.png
$files += Get-ChildItem (Join-Path $root 'sounds')  -Recurse -File | Where-Object { $_.Extension -in '.ogg', '.wav' }

# MESHES AND SKINS: what MODELDEF names, and nothing else.
$wanted = @{}
$path = ''
foreach ($line in (Get-Content (Join-Path $root 'MODELDEF.txt'))) {
    $t = ($line -replace '//.*$', '').Trim()
    if ($t -match '^Path\s+"([^"]+)"') { $path = $Matches[1] }
    elseif ($t -match '^(Model|Skin)\s+\d+\s+"([^"]+)"') { $wanted["$path/$($Matches[2])".ToLowerInvariant()] = $true }
    elseif ($t -match '^SurfaceSkin\s+\d+\s+\d+\s+"([^"]+)"') { $wanted["$path/$($Matches[1])".ToLowerInvariant()] = $true }
}
$files += Get-ChildItem (Join-Path $root 'models') -Recurse -File | Where-Object {
    $rel = ($_.FullName.Substring($root.Length + 1)) -replace ([regex]::Escape([char]92)), '/'
    $wanted.ContainsKey($rel.ToLowerInvariant()) }

# KEYCONF WITH A BYTE ORDER MARK SILENTLY KILLS ITS FIRST ALIAS.
$kb = [System.IO.File]::ReadAllBytes((Join-Path $root 'KEYCONF.txt'))
if ($kb.Length -ge 3 -and $kb[0] -eq 0xEF -and $kb[1] -eq 0xBB -and $kb[2] -eq 0xBF) { throw 'KEYCONF.txt starts with a UTF-8 BOM' }

if (Test-Path $out) { Remove-Item $out -Force }
$fs  = [System.IO.File]::Open($out, [System.IO.FileMode]::CreateNew)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($f in $files) {
    $rel = ($f.FullName.Substring($root.Length + 1)) -replace ([regex]::Escape([char]92)), '/'
    $e = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
    $st = $e.Open(); $b = [System.IO.File]::ReadAllBytes($f.FullName); $st.Write($b, 0, $b.Length); $st.Dispose()
}
$zip.Dispose(); $fs.Dispose()

# EVERY MESH AND SKIN MODELDEF NAMES IS IN THE PACK -- a model that fails to pack draws nothing, silently.
$z = [System.IO.Compression.ZipFile]::OpenRead($out)
$names = @($z.Entries | ForEach-Object { $_.FullName.ToLowerInvariant() })
$z.Dispose()
foreach ($w in $wanted.Keys) { if ($names -notcontains $w) { throw "verification failed: MODELDEF names $w, which is not in the pk3" } }
Write-Output "$name  --  $($names.Count) entries, $($wanted.Count) mesh/skin references resolve"

if ($NoCompileCheck) { Write-Output "compile check SKIPPED -- packed to $out, NOT installed"; return }

# ON ITS OWN, with only what it depends on. That is the claim this pack makes -- that it loads beside
# anything -- so it is checked with nothing else there to lean on.
$ballistics = 'E:\DOOMWork\RS_Ballistics\RS_Ballistics.pk3'
if (-not (Test-Path $ballistics)) { throw "no RS_Ballistics pk3 at $ballistics" }
& 'E:\DOOMWork\tools\compile_check.ps1' -Files @($ballistics, $out)
if ($LASTEXITCODE -ne 0) { throw "compile check FAILED -- NOT installed" }
$installed = Join-Path $root $name
Copy-Item $out $installed -Force
Write-Output "installed $installed"
