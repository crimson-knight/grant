# Builds C SQLite 3.51.0, the library Grant's engine is checked against, on
# Windows from the amalgamation pinned by hash (the same zip the engine's
# evidence pins): sqlite3.lib, static and built /MD to share the C runtime
# DLL Crystal links, for the specs that link C SQLite, and sqlite3.exe for
# the ones that run the shell. Adds the directory to the job's PATH, LIB
# and CRYSTAL_LIBRARY_PATH, and builds the shell with \r\n line ends off.
#
#   pwsh scripts/windows/build_sqlite.ps1 C:\path\to\destination
param([Parameter(Mandatory = $true)] [string] $Destination)
$ErrorActionPreference = "Stop"

$Name = "sqlite-amalgamation-3510000"
$Url = "https://www.sqlite.org/2025/$Name.zip"
$Sha256 = "1caf7116f2910600d04473ad69d37ec538fa62fa36adccd37b5e0e43647c98be"

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$Zip = Join-Path $Destination "$Name.zip"
Invoke-WebRequest -Uri $Url -OutFile $Zip -UserAgent "Grant-CI/1.0"
$Actual = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLowerInvariant()
if ($Actual -ne $Sha256) { throw "$Name.zip has sha256 $Actual, expected $Sha256" }
Write-Output "$Name.zip sha256 $Actual (pinned)"
Expand-Archive -Path $Zip -DestinationPath $Destination -Force
$Source = Join-Path $Destination $Name

# The shell starts with .crlf on under Windows and writes "\r\n" line ends;
# the specs compare its output with "\n" ends, as on every other system.
# Its one default changes (main_init), the rest of the source as pinned.
$Shell = Join-Path $Source "shell.c"
$ShellText = [System.IO.File]::ReadAllText($Shell)
$CrlfDefault = "data->crlfMode = 1;"
$Count = $ShellText.Split($CrlfDefault).Count - 1
if ($Count -ne 1) { throw "shell.c: expected one '$CrlfDefault', found $Count" }
[System.IO.File]::WriteAllText($Shell, $ShellText.Replace($CrlfDefault, "data->crlfMode = 0;"))

$VsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$VsPath = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$VcVars = Join-Path $VsPath "VC\Auxiliary\Build\vcvars64.bat"
$Build = "call `"$VcVars`" >nul && cd /d `"$Source`" && cl /nologo /O2 /MD /c sqlite3.c && lib /nologo /OUT:sqlite3.lib sqlite3.obj && cl /nologo /O2 /MD shell.c sqlite3.obj /Fe:sqlite3.exe"
cmd /c $Build
if ($LASTEXITCODE -ne 0) { throw "building SQLite failed ($LASTEXITCODE)" }
& (Join-Path $Source "sqlite3.exe") -version

$LibraryPath = (crystal env CRYSTAL_LIBRARY_PATH).Trim()
Add-Content -Path $env:GITHUB_PATH -Value $Source
Add-Content -Path $env:GITHUB_ENV -Value "CRYSTAL_LIBRARY_PATH=$Source;$LibraryPath"
Add-Content -Path $env:GITHUB_ENV -Value "LIB=$Source;$env:LIB"
Add-Content -Path $env:GITHUB_ENV -Value "SQLITE3=$(Join-Path $Source 'sqlite3.exe')"
