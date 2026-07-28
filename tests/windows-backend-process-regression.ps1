param(
    [string]$ManagerScript = "",
    [ValidateSet("status", "activate-library")]
    [string]$Command = "status",
    [string]$ThemeDir = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($ManagerScript)) {
    $ManagerScript = Join-Path `
        $env:LOCALAPPDATA `
        "Programs\Doubao Skin\runtime\scripts\manage-doubao-skin-windows.ps1"
}
if (-not (Test-Path -LiteralPath $ManagerScript -PathType Leaf)) {
    throw "The installed Windows manager backend was not found."
}

function Quote-Single {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

if ($Command -eq "activate-library") {
    if ([string]::IsNullOrWhiteSpace($ThemeDir)) {
        $ThemeDir = Join-Path `
            $env:LOCALAPPDATA `
            "DoubaoSkin\themes\mbti-boy-infp"
    }
    & $ManagerScript disable | Out-Null
}

$stateRoot = Join-Path $env:LOCALAPPDATA "DoubaoSkin"
$resultPath = Join-Path `
    $stateRoot `
    "ui-operation-backend-regression-$PID.json"
$commandParts = @(
    "&",
    (Quote-Single -Value $ManagerScript),
    "-Command",
    (Quote-Single -Value $Command))
if ($Command -eq "activate-library") {
    $commandParts += "-ThemeDir"
    $commandParts += Quote-Single -Value $ThemeDir
}
$commandParts += "-OperationResultPath"
$commandParts += Quote-Single -Value $resultPath
$commandLine = $commandParts -join " "
$encoded = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($commandLine))
$powershell = Join-Path `
    $env:WINDIR `
    "System32\WindowsPowerShell\v1.0\powershell.exe"
$process = Start-Process `
    -FilePath $powershell `
    -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" `
    -WindowStyle Hidden `
    -PassThru
if (-not $process.WaitForExit(90000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "The manager backend child process did not exit in time."
}
$operation = if (Test-Path -LiteralPath $resultPath) {
    [IO.File]::ReadAllText(
        $resultPath,
        (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json
} else { $null }
$result = [ordered]@{
    schema = "doubao-skin-windows-backend-process/1"
    exitCode = $process.ExitCode
    resultPublished = $null -ne $operation
    resultExitCode = if ($null -ne $operation) {
        [int]$operation.exitCode
    } else { $null }
    outputLength = if ($null -ne $operation) {
        ([string]$operation.output).Length
    } else { 0 }
    errorLength = if ($null -ne $operation) {
        ([string]$operation.error).Length
    } else { 0 }
    command = $Command
}
Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
$process.Dispose()
$json = $result | ConvertTo-Json
Write-Output $json
if ($result.exitCode -ne 0 -or
    -not [bool]$result.resultPublished -or
    $result.resultExitCode -ne 0) {
    throw "The manager backend child process returned a non-zero exit code."
}
