param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference = 'Stop'
$Destination = [IO.Path]::GetFullPath($Destination)
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
function Get-Verified([string]$Uri,[string]$Path,[string]$Hash) {
    if ((Test-Path -LiteralPath $Path) -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Hash) { return }
    Invoke-WebRequest -Uri $Uri -OutFile ($Path + '.download')
    if ((Get-FileHash -LiteralPath ($Path + '.download') -Algorithm SHA256).Hash -ne $Hash) { throw "Checksum mismatch: $Path" }
    Move-Item -LiteralPath ($Path + '.download') -Destination $Path -Force
}
$engineZip = Join-Path $Destination 'whisper-b5454-x64.zip'
Get-Verified 'https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-bin-x64.zip' $engineZip '6ba69e3482d7826214f90a6a9c84ca07782aec1e1d0c6a7c30c994fd5d816ccb'
$model = Join-Path $Destination 'ggml-small-q5_1.bin'
Get-Verified 'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin' $model 'ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb'
Expand-Archive -LiteralPath $engineZip -DestinationPath (Join-Path $Destination 'whisper') -Force
$redist = Join-Path $Destination 'vc_redist.x64.exe'
if (-not (Test-Path -LiteralPath $redist)) { Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $redist }
$signature = Get-AuthenticodeSignature -LiteralPath $redist
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw 'Microsoft runtime signature verification failed' }
# Read the embedded CABs; the redistributable installer is never executed.
$bytes = [IO.File]::ReadAllBytes($redist)
$ascii = [Text.Encoding]::ASCII.GetString($bytes)
$offset = -1; $cabIndex = 0
while (($offset = $ascii.IndexOf('MSCF',$offset + 1,[StringComparison]::Ordinal)) -ge 0) {
    if ($offset + 36 -gt $bytes.Length) { continue }
    $size = [BitConverter]::ToUInt32($bytes,$offset + 8)
    if ($size -lt 36 -or $offset + $size -gt $bytes.Length -or $bytes[$offset + 25] -ne 1) { continue }
    $cab = Join-Path $Destination "runtime-$cabIndex.cab"
    $slice = [byte[]]::new($size); [Array]::Copy($bytes,$offset,$slice,0,$size); [IO.File]::WriteAllBytes($cab,$slice)
    $expanded = Join-Path $Destination "runtime-$cabIndex"; New-Item -ItemType Directory -Path $expanded -Force | Out-Null
    & expand.exe '-F:*' $cab $expanded | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract the Microsoft runtime container' }
    $cabIndex++
}
if ($cabIndex -ne 2) { throw 'Unexpected Microsoft runtime container format' }
[xml]$manifest = Get-Content -LiteralPath (Join-Path $Destination 'runtime-0/0') -Raw
$minimum = @($manifest.BurnManifest.Payload | Where-Object FilePath -like '*vcRuntimeMinimum_amd64*cab1.cab')
$license = @($manifest.BurnManifest.UX.Payload | Where-Object FilePath -eq 'license.rtf')
if ($minimum.Count -ne 1 -or $license.Count -ne 1) { throw 'Runtime DLL archive or license was not found' }
$native = Join-Path $Destination 'native-runtime'; New-Item -ItemType Directory -Path $native -Force | Out-Null
& expand.exe '-F:*' (Join-Path $Destination ('runtime-1/' + $minimum[0].SourcePath)) $native | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not extract native runtime libraries' }
Copy-Item -LiteralPath (Join-Path $Destination ('runtime-0/' + $license[0].SourcePath)) -Destination (Join-Path $Destination 'Microsoft-VC-Runtime-license.rtf')
Write-Output 'Verified offline Windows dependencies are ready.'
