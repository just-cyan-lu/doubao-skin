param(
    [switch]$NoLaunch,
    [switch]$SkipBuild,
    [string]$PackagePath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$scriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptsRoot
$source = if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    Join-Path $projectRoot "dist\windows\Doubao Skin"
} else {
    (Get-Item -LiteralPath $PackagePath -ErrorAction Stop).FullName
}
$installParent = Join-Path $env:LOCALAPPDATA "Programs"
$destination = Join-Path $installParent "Doubao Skin"
$stage = Join-Path $installParent ("Doubao Skin.installing." + $PID)
$previous = Join-Path $installParent ("Doubao Skin.previous." + $PID)

function Test-CommandLineContainsPath {
    param(
        [string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$Path
    )
    return -not [string]::IsNullOrWhiteSpace($CommandLine) -and
        $CommandLine.IndexOf($Path, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Stop-InstalledDoubaoSkinProcesses {
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        return
    }
    $runtime = Join-Path $destination "runtime"
    $expectedNode = Join-Path $runtime "bin\node.exe"
    $expectedInjector = Join-Path $runtime "scripts\injector.mjs"
    $expectedManager = Join-Path $runtime "scripts\manage-doubao-skin-windows.ps1"
    $expectedSupervisor = Join-Path $runtime "scripts\supervisor-windows.ps1"
    $expectedTray = Join-Path $runtime "windows\DoubaoSkinTray.ps1"
    $expectedNativeManager = Join-Path $destination "Doubao Skin.exe"

    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $matchesInstalledRuntime =
            ($process.ExecutablePath -and
             $process.ExecutablePath.Equals($expectedNode, [StringComparison]::OrdinalIgnoreCase) -and
             (Test-CommandLineContainsPath -CommandLine ([string]$process.CommandLine) -Path $expectedInjector)) -or
            (Test-CommandLineContainsPath -CommandLine ([string]$process.CommandLine) -Path $expectedManager) -or
            (Test-CommandLineContainsPath -CommandLine ([string]$process.CommandLine) -Path $expectedSupervisor) -or
            (Test-CommandLineContainsPath -CommandLine ([string]$process.CommandLine) -Path $expectedTray) -or
            ($process.ExecutablePath -and
             $process.ExecutablePath.Equals($expectedNativeManager, [StringComparison]::OrdinalIgnoreCase))
        if ($matchesInstalledRuntime -and $process.ProcessId -ne $PID) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 500
}

if ([string]::IsNullOrWhiteSpace($PackagePath) -and
    (-not $SkipBuild -or
     -not (Test-Path -LiteralPath (Join-Path $source "runtime\windows\DoubaoSkinTray.ps1")))) {
    & (Join-Path $scriptsRoot "build-windows-app.ps1") -SkipArchive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "The Windows application build failed."
    }
}

$packageIdentity = Join-Path $source "runtime\assets\windows-app-identity.json"
if (-not (Test-Path -LiteralPath $packageIdentity -PathType Leaf)) {
    throw "The selected package is not a complete Doubao Skin Windows build."
}
$sourceFullPath = [IO.Path]::GetFullPath($source).TrimEnd("\")
$destinationFullPath = [IO.Path]::GetFullPath($destination).TrimEnd("\")
if ($sourceFullPath.Equals($destinationFullPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Doubao Skin is already installed at this path. Use its desktop or Start menu shortcut."
}

Stop-InstalledDoubaoSkinProcesses

New-Item -ItemType Directory -Path $installParent -Force | Out-Null
foreach ($temporaryPath in @($stage, $previous)) {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Recurse -Force
    }
}
Copy-Item -LiteralPath $source -Destination $stage -Recurse

$hadPrevious = $false
try {
    if (Test-Path -LiteralPath $destination) {
        Move-Item -LiteralPath $destination -Destination $previous
        $hadPrevious = $true
    }
    Move-Item -LiteralPath $stage -Destination $destination
} catch {
    if ($hadPrevious -and -not (Test-Path -LiteralPath $destination)) {
        Move-Item -LiteralPath $previous -Destination $destination
    }
    throw
}
if ($hadPrevious -and (Test-Path -LiteralPath $previous)) {
    Remove-Item -LiteralPath $previous -Recurse -Force
}

$powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$trayScript = Join-Path $destination "runtime\windows\DoubaoSkinTray.ps1"
$iconPath = Join-Path $destination "runtime\assets\DoubaoSkin.ico"
$trayArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $trayScript
$shell = New-Object -ComObject WScript.Shell
$startMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "Doubao Skin.lnk"
$desktop = Join-Path ([Environment]::GetFolderPath("Desktop")) "Doubao Skin.lnk"
foreach ($shortcutPath in @($startMenu, $desktop)) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = $trayArguments
    $shortcut.WorkingDirectory = $destination
    $shortcut.Description = "Doubao Skin theme manager"
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.Save()
}

if (-not $NoLaunch) {
    Start-Process -FilePath $powershell -ArgumentList $trayArguments -WindowStyle Hidden
}
Write-Output $trayScript
