param([switch]$NoLaunch)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $packageRoot "runtime\scripts\install-windows-app.ps1"
$identity = Join-Path $packageRoot "runtime\assets\windows-app-identity.json"

if (-not (Test-Path -LiteralPath $installer -PathType Leaf) -or
    -not (Test-Path -LiteralPath $identity -PathType Leaf)) {
    throw "This folder is not a complete Doubao Skin Windows package. Extract the whole ZIP before installing."
}

& $installer `
    -SkipBuild `
    -PackagePath $packageRoot `
    -NoLaunch:$NoLaunch
