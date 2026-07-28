param(
    [string]$ThemeDir = "",
    [string]$ResultPath = "",
    [string]$ManagerScript = "",
    [ValidateRange(1, 10)]
    [int]$Iterations = 1
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $testsRoot
if ([string]::IsNullOrWhiteSpace($ManagerScript)) {
    $ManagerScript = Join-Path `
        $projectRoot `
        "dist\windows\Doubao Skin\runtime\scripts\manage-doubao-skin-windows.ps1"
}
if ([string]::IsNullOrWhiteSpace($ThemeDir)) {
    $ThemeDir = Join-Path $env:LOCALAPPDATA "DoubaoSkin\themes\mbti-boy-infp"
}
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path $projectRoot "dist\windows-lifecycle-result.json"
}

if (-not (Test-Path -LiteralPath $ManagerScript -PathType Leaf)) {
    throw "Build the Windows package before running the lifecycle regression."
}
if (-not (Test-Path -LiteralPath $ThemeDir -PathType Container)) {
    throw "The lifecycle test theme is missing: $ThemeDir"
}

function Read-Status {
    $json = & $ManagerScript status
    return (($json -join [Environment]::NewLine) | ConvertFrom-Json)
}

$cycles = @()
for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    & $ManagerScript disable | Out-Null
    $disabled = Read-Status
    if ([bool]$disabled.enabled -or [bool]$disabled.skinActive) {
        throw "The manager still reports an active skin after disable in cycle $iteration."
    }

    & $ManagerScript activate-library -ThemeDir $ThemeDir | Out-Null
    Start-Sleep -Seconds 3
    & $ManagerScript verify | Out-Null
    $enabled = Read-Status
    if (-not [bool]$enabled.enabled -or
        -not [bool]$enabled.running -or
        -not [bool]$enabled.skinActive -or
        -not [bool]$enabled.supervisorRunning) {
        throw "The skin did not remain active after re-enable in cycle $iteration."
    }
    $cycles += [ordered]@{
        cycle = $iteration
        disabledRunning = [bool]$disabled.running
        reenabledThemeId = [string]$enabled.themeId
    }
}

$result = [ordered]@{
    schema = "doubao-skin-windows-lifecycle/1"
    iterations = $Iterations
    cycles = $cycles
    disabled = [ordered]@{
        enabled = [bool]$disabled.enabled
        running = [bool]$disabled.running
        skinActive = [bool]$disabled.skinActive
        supervisorRunning = [bool]$disabled.supervisorRunning
    }
    reenabled = [ordered]@{
        enabled = [bool]$enabled.enabled
        running = [bool]$enabled.running
        skinActive = [bool]$enabled.skinActive
        supervisorRunning = [bool]$enabled.supervisorRunning
        themeId = [string]$enabled.themeId
    }
    testedAt = [DateTime]::UtcNow.ToString("o")
}
$json = $result | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText(
    $ResultPath,
    $json + [Environment]::NewLine,
    (New-Object Text.UTF8Encoding($false)))
Write-Output $json
