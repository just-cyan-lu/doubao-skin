param(
    [string]$ManagerScript = "",
    [string]$ResultPath = "",
    [ValidateRange(1, 5)]
    [int]$Iterations = 1
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $testsRoot
if ([string]::IsNullOrWhiteSpace($ManagerScript)) {
    $ManagerScript = Join-Path `
        $env:LOCALAPPDATA `
        "Programs\Doubao Skin\runtime\scripts\manage-doubao-skin-windows.ps1"
}
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path $projectRoot "dist\windows-manager-ui-result.json"
}
if (-not (Test-Path -LiteralPath $ManagerScript -PathType Leaf)) {
    throw "The installed Windows manager backend was not found."
}

$runtimeRoot = Split-Path -Parent (Split-Path -Parent $ManagerScript)
$stringsPath = Join-Path $runtimeRoot "windows\strings.zh-CN.json"
$strings = [IO.File]::ReadAllText(
    $stringsPath,
    (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Read-Status {
    $json = & $ManagerScript status
    return (($json -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Find-TopLevelWindow {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 15
    )
    $condition = New-Object Windows.Automation.PropertyCondition -ArgumentList @(
        [Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $window = [Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [Windows.Automation.TreeScope]::Children,
            $condition)
        if ($null -ne $window) {
            return $window
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Get-Buttons {
    param([Parameter(Mandatory = $true)]$Window)
    $condition = New-Object Windows.Automation.PropertyCondition -ArgumentList @(
        [Windows.Automation.AutomationElement]::ControlTypeProperty,
        [Windows.Automation.ControlType]::Button)
    return @($Window.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        $condition))
}

function Find-Button {
    param(
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][scriptblock]$Predicate,
        [bool]$RequireEnabled = $false,
        [int]$TimeoutSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        foreach ($button in @(Get-Buttons -Window $Window)) {
            if ((& $Predicate ([string]$button.Current.Name)) -and
                (-not $RequireEnabled -or [bool]$button.Current.IsEnabled)) {
                return $button
            }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Invoke-Button {
    param([Parameter(Mandatory = $true)]$Button)
    $pattern = $Button.GetCurrentPattern(
        [Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
}

function Get-WindowText {
    param([Parameter(Mandatory = $true)]$Window)
    $names = @(
        foreach ($element in $Window.FindAll(
            [Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.Condition]::TrueCondition)) {
            $name = ([string]$element.Current.Name).Trim()
            if ($name) { $name }
        }
    )
    return ($names | Select-Object -Unique) -join " | "
}

$window = Find-TopLevelWindow -Name ([string]$strings.windowTitle)
if ($null -eq $window) {
    throw "The Doubao Skin manager window is not visible in the interactive session."
}
Write-Output ("managerWindowProcessId=" + [string]$window.Current.ProcessId)
$initialWindowText = Get-WindowText -Window $window
if ($initialWindowText -notlike ("*" + [string]$strings.copyrightNotice + "*")) {
    throw "The manager does not expose the required copyright and AGPL notice."
}
$projectCondition = New-Object Windows.Automation.PropertyCondition -ArgumentList @(
    [Windows.Automation.AutomationElement]::NameProperty,
    [string]$strings.viewProject)
$projectElement = $window.FindFirst(
    [Windows.Automation.TreeScope]::Descendants,
    $projectCondition)
if ($null -eq $projectElement -or -not [bool]$projectElement.Current.IsEnabled) {
    throw "The manager does not expose an enabled GitHub project link."
}
$initialButtons = @(Get-Buttons -Window $window)
$initialRefresh = @($initialButtons | Where-Object {
    [string]$_.Current.Name -eq [string]$strings.refresh
}) | Select-Object -First 1
if ($null -ne $initialRefresh -and -not [bool]$initialRefresh.Current.IsEnabled) {
    $blockingButton = @($initialButtons | Where-Object {
        [bool]$_.Current.IsEnabled
    }) | Select-Object -First 1
    if ($null -ne $blockingButton) {
        Write-Output ("blockingDialog=" + (Get-WindowText -Window $window))
        Invoke-Button -Button $blockingButton
        Start-Sleep -Milliseconds 500
    }
}

$cycles = @()
for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    $readyRefresh = Find-Button -Window $window -Predicate {
        param($name)
        $name -eq [string]$strings.refresh
    } -RequireEnabled $true -TimeoutSeconds 30
    if ($null -eq $readyRefresh) {
        throw (
            "The manager was not ready before UI cycle $iteration. Elements: " +
            (Get-WindowText -Window $window))
    }
    Write-Output "cycle=$iteration disable"
    & $ManagerScript disable | Out-Null
    $disabled = Read-Status
    if ([bool]$disabled.enabled -or [bool]$disabled.skinActive) {
        throw "The backend did not disable the skin before UI cycle $iteration."
    }

    $refresh = Find-Button -Window $window -Predicate {
        param($name)
        $name -eq [string]$strings.refresh
    } -RequireEnabled $true
    if ($null -eq $refresh) {
        throw "The manager Refresh button was not found."
    }
    Invoke-Button -Button $refresh
    $buttonSummary = @(Get-Buttons -Window $window | ForEach-Object {
        "{0} [enabled={1}]" -f `
            [string]$_.Current.Name, `
            [bool]$_.Current.IsEnabled
    }) -join " | "
    Write-Output ("cycle=$iteration buttons=" + $buttonSummary)

    $enable = Find-Button -Window $window -Predicate {
        param($name)
        $name.StartsWith(([string]$strings.enableTheme).Split("{")[0])
    } -RequireEnabled $true
    if ($null -eq $enable) {
        $buttonNames = @(Get-Buttons -Window $window | ForEach-Object {
            [string]$_.Current.Name
        }) -join " | "
        throw "The manager Enable button was not found. Buttons: $buttonNames"
    }
    Write-Output (
        "cycle=$iteration invoke=" +
        [string]$enable.Current.Name +
        " enabled=" +
        [string][bool]$enable.Current.IsEnabled)
    Invoke-Button -Button $enable
    Start-Sleep -Seconds 1
    $afterInvoke = Read-Status
    Write-Output (
        "cycle=$iteration afterInvoke enabled=" +
        [string][bool]$afterInvoke.enabled +
        " running=" +
        [string][bool]$afterInvoke.running +
        " skinActive=" +
        [string][bool]$afterInvoke.skinActive)

    $deadline = (Get-Date).AddSeconds(65)
    $enabled = $null
    do {
        $errorWindow = Find-TopLevelWindow `
            -Name ([string]$strings.applyFailed) `
            -TimeoutSeconds 1
        if ($null -ne $errorWindow) {
            $message = Get-WindowText -Window $errorWindow
            $dismiss = Find-Button -Window $errorWindow -Predicate {
                param($name)
                -not [string]::IsNullOrWhiteSpace($name)
            } -TimeoutSeconds 1
            if ($null -ne $dismiss) {
                Invoke-Button -Button $dismiss
            }
            throw "The manager displayed its Apply failure dialog: $message"
        }
        $candidate = Read-Status
        if ([bool]$candidate.enabled -and
            [bool]$candidate.running -and
            [bool]$candidate.skinActive -and
            [bool]$candidate.supervisorRunning) {
            $enabled = $candidate
            break
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $enabled) {
        throw "The UI did not leave the skin active after cycle $iteration."
    }
    & $ManagerScript verify | Out-Null
    $readyRefresh = Find-Button -Window $window -Predicate {
        param($name)
        $name -eq [string]$strings.refresh
    } -RequireEnabled $true -TimeoutSeconds 30
    if ($null -eq $readyRefresh) {
        throw "The manager did not leave its busy state after UI cycle $iteration."
    }
    $cycles += [ordered]@{
        cycle = $iteration
        themeId = [string]$enabled.themeId
        enabled = [bool]$enabled.enabled
        skinActive = [bool]$enabled.skinActive
        supervisorRunning = [bool]$enabled.supervisorRunning
    }
}

$result = [ordered]@{
    schema = "doubao-skin-windows-manager-ui/1"
    iterations = $Iterations
    legalNotice = $true
    projectLink = $true
    cycles = $cycles
    testedAt = [DateTime]::UtcNow.ToString("o")
}
$json = $result | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText(
    $ResultPath,
    $json + [Environment]::NewLine,
    (New-Object Text.UTF8Encoding($false)))
Write-Output $json
