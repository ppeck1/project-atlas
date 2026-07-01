# Project Atlas — Launch Script
# Run from the project root: .\launch.ps1
#
# Options:
#   .\launch.ps1           — build + run (skips pub get if lock unchanged)
#   .\launch.ps1 -Full     — force pub get + build_runner + run
#   .\launch.ps1 -Build    — build_runner only (no run)
#   .\launch.ps1 -Clean    — flutter clean + full rebuild + run

param(
    [switch]$Full,
    [switch]$Build,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot

function Write-Step($msg) {
    Write-Host ""
    Write-Host "═══ $msg" -ForegroundColor Cyan
}

function Resolve-ToolCommand {
    param(
        [string]$Name,
        [string]$EnvVar,
        [string[]]$FallbackPaths
    )

    $override = [Environment]::GetEnvironmentVariable($EnvVar)
    if ($override) {
        if (Test-Path -LiteralPath $override) {
            return (Resolve-Path -LiteralPath $override).Path
        }

        Write-Host "ERROR: '$EnvVar' points to a missing path: $override" -ForegroundColor Red
        exit 1
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        if ($command.Path) { return $command.Path }
        if ($command.Source) { return $command.Source }
        return $Name
    }

    foreach ($path in $FallbackPaths) {
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    Write-Host "ERROR: '$Name' not found in PATH and no fallback path exists." -ForegroundColor Red
    Write-Host "Set $EnvVar to an explicit executable path to override discovery." -ForegroundColor Yellow
    exit 1
}

function Resolve-DartCommand {
    param([string]$FlutterCommand)

    $override = [Environment]::GetEnvironmentVariable("PROJECT_ATLAS_DART")
    if ($override) {
        if (Test-Path -LiteralPath $override) {
            return (Resolve-Path -LiteralPath $override).Path
        }

        Write-Host "ERROR: 'PROJECT_ATLAS_DART' points to a missing path: $override" -ForegroundColor Red
        exit 1
    }

    $command = Get-Command dart -ErrorAction SilentlyContinue
    if ($command) {
        if ($command.Path) { return $command.Path }
        if ($command.Source) { return $command.Source }
        return "dart"
    }

    $flutterBin = Split-Path -Parent $FlutterCommand
    $flutterRoot = Split-Path -Parent $flutterBin
    $bundledDart = Join-Path $flutterRoot "bin\cache\dart-sdk\bin\dart.exe"
    if (Test-Path -LiteralPath $bundledDart) {
        return (Resolve-Path -LiteralPath $bundledDart).Path
    }

    Write-Host "ERROR: 'dart' not found in PATH or the resolved Flutter SDK cache." -ForegroundColor Red
    Write-Host "Set PROJECT_ATLAS_DART to an explicit executable path to override discovery." -ForegroundColor Yellow
    exit 1
}

$FlutterCommand = Resolve-ToolCommand `
    -Name "flutter" `
    -EnvVar "PROJECT_ATLAS_FLUTTER" `
    -FallbackPaths @("B:\dev\flutter\bin\flutter.bat")
$DartCommand = Resolve-DartCommand -FlutterCommand $FlutterCommand

Set-Location $ProjectRoot

# ── Clean ───────────────────────────────────────────────────────────────────
if ($Clean) {
    Write-Step "Cleaning build artifacts"
    & $FlutterCommand clean
    $Full = $true
}

# ── Delete stale database (use when migration is broken) ────────────────────
# Uncomment the block below to wipe the local DB and start fresh.
# WARNING: this erases all your data.
#
# $dbPath = "$env:APPDATA\project_atlas\project_atlas.sqlite"
# if (Test-Path $dbPath) {
#     Remove-Item $dbPath -Force
#     Write-Host "Deleted local database at $dbPath" -ForegroundColor Yellow
# }

# ── Flutter pub get ─────────────────────────────────────────────────────────
$needsPubGet = $Full -or $Clean -or
    (-not (Test-Path ".\pubspec.lock")) -or
    (-not (Test-Path ".\.dart_tool\package_config.json")) -or
    (
        (Get-Item ".\pubspec.yaml").LastWriteTime -gt
        (Get-Item ".\pubspec.lock").LastWriteTime
    )

if ($needsPubGet) {
    Write-Step "Running flutter pub get"
    & $FlutterCommand pub get
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# ── build_runner ─────────────────────────────────────────────────────────────
$generatedFile = ".\lib\db\app_db.g.dart"
$tablesFile    = ".\lib\db\tables.dart"
$appDbFile     = ".\lib\db\app_db.dart"

$needsBuild = $Full -or $Clean -or $Build -or
    (-not (Test-Path $generatedFile)) -or
    (
        (Get-Item $tablesFile).LastWriteTime -gt
        (Get-Item $generatedFile).LastWriteTime
    ) -or
    (
        (Get-Item $appDbFile).LastWriteTime -gt
        (Get-Item $generatedFile).LastWriteTime
    )

if ($needsBuild) {
    Write-Step "Running build_runner (Drift code generation)"
    & $DartCommand run build_runner build
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "build_runner failed. Try:" -ForegroundColor Yellow
        Write-Host "  dart run build_runner build --delete-conflicting-outputs"
        exit $LASTEXITCODE
    }
} else {
    Write-Host "  build_runner: up to date, skipping." -ForegroundColor DarkGray
}

# ── Run ──────────────────────────────────────────────────────────────────────
if (-not $Build) {
    Write-Step "Launching Project Atlas (Windows)"
    & $FlutterCommand run -d windows
}
