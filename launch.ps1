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

function Assert-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: '$name' not found in PATH." -ForegroundColor Red
        exit 1
    }
}

Assert-Command flutter
Assert-Command dart

Set-Location $ProjectRoot

# ── Clean ───────────────────────────────────────────────────────────────────
if ($Clean) {
    Write-Step "Cleaning build artifacts"
    flutter clean
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
    (
        (Get-Item ".\pubspec.yaml").LastWriteTime -gt
        (Get-Item ".\pubspec.lock").LastWriteTime
    )

if ($needsPubGet) {
    Write-Step "Running flutter pub get"
    flutter pub get
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
    dart run build_runner build
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
    flutter run -d windows
}
