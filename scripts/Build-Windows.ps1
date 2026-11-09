param([switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cache = Join-Path $root 'build/windows-assets'
& (Join-Path $PSScriptRoot 'Prepare-Windows.ps1') -Destination $cache
$payload = Join-Path $root 'build/windows-payload'
New-Item -ItemType Directory -Path (Join-Path $payload 'engine'),(Join-Path $payload 'models'),(Join-Path $payload 'Licenses') -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $cache 'whisper/Release') -File | Where-Object { $_.Extension -eq '.dll' -or $_.Name -eq 'whisper-cli.exe' } | Copy-Item -Destination (Join-Path $payload 'engine')
foreach ($dll in @('msvcp140.dll','vcomp140.dll','vcruntime140.dll','vcruntime140_1.dll')) {
    Copy-Item -LiteralPath (Join-Path $cache ('native-runtime/' + $dll + '_amd64')) -Destination (Join-Path $payload ('engine/' + $dll))
}
& (Join-Path $root 'windows/Source/Packaging/Enable-Utf8Manifest.ps1') -Path (Join-Path $payload 'engine/whisper-cli.exe')
Copy-Item -LiteralPath (Join-Path $cache 'ggml-small-q5_1.bin') -Destination (Join-Path $payload 'models')
Get-ChildItem -LiteralPath (Join-Path $root 'licenses') -File | Copy-Item -Destination (Join-Path $payload 'Licenses')
Copy-Item -LiteralPath (Join-Path $cache 'Microsoft-VC-Runtime-license.rtf') -Destination (Join-Path $payload 'Licenses')
Copy-Item -LiteralPath (Join-Path $root 'docs/windows-portable.txt') -Destination (Join-Path $payload 'Licenses/App-usage.txt')
$project = Join-Path $root 'windows/Source/LocalMeetingNotes.csproj'
$zip = Join-Path $root 'build/offline-payload.zip'
dotnet restore $project -r win-x64 -p:PortablePackage=true "-p:OfflinePayloadPath=$zip" --locked-mode
if ($LASTEXITCODE -ne 0) { throw 'Dependency restore failed' }
$nuget = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.nuget/packages' }
$runtime = Join-Path $nuget 'microsoft.netcore.app.runtime.win-x64/8.0.33'
$desktop = Join-Path $nuget 'microsoft.windowsdesktop.app.runtime.win-x64/8.0.33'
Copy-Item -LiteralPath (Join-Path $runtime 'LICENSE.TXT') -Destination (Join-Path $payload 'Licenses/Microsoft-NET-runtime-license.txt')
Copy-Item -LiteralPath (Join-Path $runtime 'THIRD-PARTY-NOTICES.TXT') -Destination (Join-Path $payload 'Licenses/Microsoft-NET-third-party-notices.txt')
Copy-Item -LiteralPath (Join-Path $desktop 'LICENSE') -Destination (Join-Path $payload 'Licenses/Microsoft-WindowsDesktop-runtime-license.txt')
$notice = 'The bundled whisper-cli.exe is based on whisper.cpp 1.9.5 b5454. Its application manifest enables process-local UTF-8 paths and long-path awareness. No system settings are changed. Its MIT license is included.'
Set-Content -LiteralPath (Join-Path $payload 'Licenses/Portable-build-notes.txt') -Value $notice -Encoding utf8
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
[IO.Compression.ZipFile]::CreateFromDirectory($payload,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
$published = Join-Path $root 'build/windows-published'
dotnet publish $project -c Release -r win-x64 --self-contained true -o $published -p:PortablePackage=true "-p:OfflinePayloadPath=$zip" -p:DebugType=None -p:DebugSymbols=false --no-restore
if ($LASTEXITCODE -ne 0) { throw 'Portable publish failed' }
$exe = Join-Path $published 'LocalMeetingNotes.exe'
if (-not $SkipTests) {
    $checks = Join-Path $root 'build/windows-storage-checks'
    $process = Start-Process -FilePath $exe -ArgumentList @('--reliability-test',('"'+$checks+'"')) -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'Storage/recovery checks failed; see the build/windows-published/LocalMeetingNotes-data folder' }
    Get-Content -LiteralPath (Join-Path $checks 'test-results.txt')
}
$output = Join-Path $root 'dist/windows'
New-Item -ItemType Directory -Path $output,(Join-Path $output 'Licenses') -Force | Out-Null
Copy-Item -LiteralPath $exe -Destination $output
Copy-Item -LiteralPath (Join-Path $root 'docs/windows-portable.txt') -Destination (Join-Path $output 'Read me.txt')
Get-ChildItem -LiteralPath (Join-Path $payload 'Licenses') -File | Copy-Item -Destination (Join-Path $output 'Licenses')
$package = Join-Path $root 'dist/LocalMeetingNotes-Portable-Windows-x64.zip'
if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package }
[IO.Compression.ZipFile]::CreateFromDirectory($output,$package,[IO.Compression.CompressionLevel]::Optimal,$true)
Get-FileHash -LiteralPath $package -Algorithm SHA256
Write-Output "Created $package"
