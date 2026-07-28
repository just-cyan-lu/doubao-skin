param(
    [Parameter(Position = 0)]
    [ValidateSet(
        "status",
        "list-themes",
        "activate-library",
        "enable-default",
        "disable",
        "enable-startup",
        "disable-startup",
        "set-conversation-opacity",
        "open",
        "reveal-themes",
        "verify",
        "ensure-supervisor",
        "supervise-once"
    )]
    [string]$Command = "status",

    [int]$Port = 9451,

    [string]$ThemeDir = "",

    [string]$ConversationOpacity = "",

    [int]$ObservedProcessId = 0,

    [string]$OperationResultPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "common-windows.ps1")

function Write-OperationResult {
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [string]$OutputText = "",
        [string]$ErrorText = ""
    )
    if ([string]::IsNullOrWhiteSpace($OperationResultPath)) {
        return
    }
    try {
        Ensure-DoubaoSkinStateRoot
        $resultPath = [IO.Path]::GetFullPath($OperationResultPath)
        $stateRoot = (Get-Item -LiteralPath $script:StateRoot).FullName.TrimEnd("\")
        $resultParent = (Split-Path -Parent $resultPath).TrimEnd("\")
        $resultName = Split-Path -Leaf $resultPath
        if (-not $resultParent.Equals(
                $stateRoot,
                [StringComparison]::OrdinalIgnoreCase) -or
            $resultName -notlike "ui-operation-*.json") {
            return
        }
        $temporary = "$resultPath.tmp.$PID"
        $json = [ordered]@{
            schema = "doubao-skin-ui-operation/1"
            exitCode = $ExitCode
            output = $OutputText
            error = $ErrorText
        } | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText(
            $temporary,
            $json + [Environment]::NewLine,
            (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $resultPath -Force
    } catch {}
}

trap {
    try {
        Ensure-DoubaoSkinStateRoot
        $record = "{0} {1}{2}" -f `
            [DateTime]::UtcNow.ToString("o"), `
            $_.Exception.ToString(), `
            [Environment]::NewLine
        [IO.File]::AppendAllText(
            $script:ManagerErrorLogPath,
            $record,
            (New-Object Text.UTF8Encoding($false)))
    } catch {}
    Write-OperationResult `
        -ExitCode 1 `
        -ErrorText ([string]$_.Exception.Message)
    Write-Error $_
    exit 1
}

function Invoke-ThemePackage {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    Assert-DoubaoSkinNode | Out-Null
    $output = @(& $script:NodePath $script:ThemePackagePath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Fail-DoubaoSkin (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }
    return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
}

function Ensure-ThemeLibrary {
    Ensure-DoubaoSkinStateRoot
    if (-not (Test-Path -LiteralPath $script:ThemeLibraryMarkerPath -PathType Leaf)) {
        $source = Join-Path $script:ProjectRoot "presets"
        Invoke-ThemePackage -Arguments @("seed", $source, $script:ThemesRoot) | Out-Null
        $temporaryMarker = "$($script:ThemeLibraryMarkerPath).tmp.$PID"
        [IO.File]::WriteAllText(
            $temporaryMarker,
            "1" + [Environment]::NewLine,
            (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporaryMarker `
            -Destination $script:ThemeLibraryMarkerPath `
            -Force
    }
    Invoke-ThemePackage -Arguments @("list", $script:ThemesRoot) | Out-Null
}

function Get-ThemeLibraryJson {
    Ensure-ThemeLibrary
    return Invoke-ThemePackage -Arguments @("list", $script:ThemesRoot)
}

function Get-ValidatedLibraryTheme {
    param([Parameter(Mandatory = $true)][string]$Source)
    if ([string]::IsNullOrWhiteSpace($Source)) {
        Fail-DoubaoSkin "Choose a theme from the theme library first."
    }
    Ensure-ThemeLibrary
    $json = Invoke-ThemePackage -Arguments @("inspect", $Source)
    $theme = $json | ConvertFrom-Json
    $library = (Get-Item -LiteralPath $script:ThemesRoot).FullName.TrimEnd("\")
    $parent = (Get-Item -LiteralPath (Split-Path -Parent ([string]$theme.directory))).FullName.TrimEnd("\")
    if (-not $parent.Equals($library, [StringComparison]::OrdinalIgnoreCase)) {
        Fail-DoubaoSkin "Only a validated direct child of the theme library can be activated."
    }
    return $theme
}

function Get-ConfiguredPort {
    param([int]$Fallback = $script:DefaultPort)
    $config = Get-DoubaoSkinConfig
    if ($null -ne $config -and $null -ne $config.port) {
        $candidate = [int]$config.port
        Assert-ValidPort -Port $candidate
        return $candidate
    }
    Assert-ValidPort -Port $Fallback
    return $Fallback
}

function Ensure-DoubaoSkinAppRunning {
    param(
        [Parameter(Mandatory = $true)]$Install,
        [Parameter(Mandatory = $true)][int]$SelectedPort
    )
    if (Test-DoubaoSkinCdpReady -Install $Install -Port $SelectedPort) {
        return
    }
    if (@(Get-DoubaoFamilyProcesses -Install $Install).Count -gt 0) {
        Stop-OfficialDoubao -Install $Install
    }
    if (-not (Test-PortAvailable -Port $SelectedPort)) {
        Fail-DoubaoSkin "The configured skin port is occupied by another program."
    }
    Start-OfficialDoubaoWithCdp -Install $Install -Port $SelectedPort
    Wait-DoubaoCdpEndpoint -Install $Install -Port $SelectedPort -TimeoutSeconds 40 | Out-Null
}

function Activate-LibraryTheme {
    param(
        [Parameter(Mandatory = $true)]$Theme,
        [int]$RequestedPort,
        [Nullable[double]]$ConversationOpacityOverride = $null,
        [switch]$OpacityChange
    )
    $install = Get-OfficialDoubaoInstall
    $selectedPort = Get-ConfiguredPort -Fallback $RequestedPort
    if (-not (Test-DoubaoSkinCdpReady -Install $install -Port $selectedPort) -and
        -not (Test-PortAvailable -Port $selectedPort)) {
        $selectedPort = Select-DoubaoSkinPort -Preferred $selectedPort
    }

    $existingConfig = Get-DoubaoSkinConfig
    $startAtLogin = Get-DoubaoSkinStartAtLogin -Config $existingConfig
    $conversationOpacityValue = if ($null -ne $ConversationOpacityOverride) {
        ConvertTo-DoubaoSkinConversationOpacity -Value $ConversationOpacityOverride
    } else {
        Get-DoubaoSkinConversationOpacity -Config $existingConfig -Theme $Theme
    }
    $conversationOpacityText = Format-DoubaoSkinConversationOpacity `
        -Value $conversationOpacityValue
    Stop-DoubaoSkinEventSupervisor
    Stop-DoubaoSkinWatcher
    try {
        Ensure-DoubaoSkinAppRunning -Install $install -SelectedPort $selectedPort
        Invoke-DoubaoSkinNode -Arguments @(
            "--once",
            "--port", [string]$selectedPort,
            "--theme-dir", [string]$Theme.directory,
            "--conversation-opacity", $conversationOpacityText,
            "--timeout-ms", "45000"
        ) | Out-Null
        Invoke-DoubaoSkinNode -Arguments @(
            "--verify",
            "--port", [string]$selectedPort,
            "--theme-dir", [string]$Theme.directory,
            "--conversation-opacity", $conversationOpacityText,
            "--timeout-ms", "20000"
        ) | Out-Null
    } catch {
        # Do not claim that a disabled skin was enabled when closing Doubao,
        # opening CDP, injection, or verification failed. When switching from
        # an existing skin, best-effort restore its watcher and supervisor.
        if ($null -ne $existingConfig -and [bool]$existingConfig.enabled) {
            try {
                $existingPort = [int]$existingConfig.port
                $existingOpacity = Get-DoubaoSkinConversationOpacity `
                    -Config $existingConfig `
                    -Theme $null
                $existingOpacityText = Format-DoubaoSkinConversationOpacity `
                    -Value $existingOpacity
                Invoke-DoubaoSkinNode -Arguments @(
                    "--once",
                    "--port", [string]$existingPort,
                    "--theme-dir", [string]$existingConfig.themeDir,
                    "--conversation-opacity", $existingOpacityText,
                    "--timeout-ms", "20000"
                ) | Out-Null
                Start-DoubaoSkinWatcher `
                    -Port $existingPort `
                    -ConversationOpacity $existingOpacity `
                    -ThemeDir ([string]$existingConfig.themeDir) `
                    -ThemeId ([string]$existingConfig.themeId) | Out-Null
                Set-DoubaoSkinStartupRegistration `
                    -Enabled (Get-DoubaoSkinStartAtLogin -Config $existingConfig)
                Start-DoubaoSkinEventSupervisor | Out-Null
            } catch {}
        }
        throw
    }

    # Publish enabled state only after the renderer accepted and verified the
    # theme. This keeps the Apply button retryable after a real startup error.
    Write-DoubaoSkinConfig `
        -Enabled $true `
        -StartAtLogin $startAtLogin `
        -Port $selectedPort `
        -ConversationOpacity $conversationOpacityValue `
        -ThemeDir ([string]$Theme.directory) `
        -ThemeId ([string]$Theme.id) `
        -ThemeName ([string]$Theme.name)
    Start-DoubaoSkinWatcher `
        -Port $selectedPort `
        -ConversationOpacity $conversationOpacityValue `
        -ThemeDir ([string]$Theme.directory) `
        -ThemeId ([string]$Theme.id) | Out-Null
    Set-DoubaoSkinStartupRegistration -Enabled $startAtLogin
    Start-DoubaoSkinEventSupervisor | Out-Null
    if ($OpacityChange) {
        Write-Output (
            "Conversation transparency: {0}%" -f
            [Math]::Round((1 - $conversationOpacityValue) * 100))
    } else {
        Write-Output "Theme enabled: $($Theme.name)"
    }
}

function Disable-DoubaoSkin {
    $install = Get-OfficialDoubaoInstall
    $config = Get-DoubaoSkinConfig
    $portValue = $script:DefaultPort
    $themeDirValue = ""
    $themeIdValue = ""
    $themeNameValue = ""
    $conversationOpacityValue = [double]0.60
    if ($null -ne $config) {
        if ($null -ne $config.port) { $portValue = [int]$config.port }
        if ($null -ne $config.themeDir) { $themeDirValue = [string]$config.themeDir }
        if ($null -ne $config.themeId) { $themeIdValue = [string]$config.themeId }
        if ($null -ne $config.themeName) { $themeNameValue = [string]$config.themeName }
        $conversationOpacityValue = Get-DoubaoSkinConversationOpacity `
            -Config $config `
            -Theme $null
    }
    Write-DoubaoSkinConfig `
        -Enabled $false `
        -StartAtLogin $false `
        -Port $portValue `
        -ConversationOpacity $conversationOpacityValue `
        -ThemeDir $themeDirValue `
        -ThemeId $themeIdValue `
        -ThemeName $themeNameValue
    Stop-DoubaoSkinEventSupervisor
    Stop-DoubaoSkinWatcher
    if (Test-DoubaoSkinCdpReady -Install $install -Port $portValue) {
        try {
            Invoke-DoubaoSkinNode -Arguments @(
                "--remove",
                "--port", [string]$portValue,
                "--timeout-ms", "10000"
            ) | Out-Null
        } catch {}
    }
    if (@(Get-DoubaoFamilyProcesses -Install $install).Count -gt 0) {
        Stop-OfficialDoubao -Install $install
        Start-OfficialDoubaoNormally -Install $install
    }
    Set-DoubaoSkinStartupRegistration -Enabled $false
    if (Test-Path -LiteralPath $script:StatePath -PathType Leaf) {
        Remove-Item -LiteralPath $script:StatePath -Force
    }
    Write-Output "Doubao Skin is disabled and the official launch mode is restored."
}

function Set-DoubaoSkinStartupPreference {
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    $config = Get-DoubaoSkinConfig
    if ($null -eq $config -or -not [bool]$config.enabled) {
        Fail-DoubaoSkin "Enable a theme before changing the login-start preference."
    }
    Write-DoubaoSkinConfig `
        -Enabled ([bool]$config.enabled) `
        -StartAtLogin $Enabled `
        -Port ([int]$config.port) `
        -ConversationOpacity (
            Get-DoubaoSkinConversationOpacity -Config $config -Theme $null) `
        -ThemeDir ([string]$config.themeDir) `
        -ThemeId ([string]$config.themeId) `
        -ThemeName ([string]$config.themeName)
    Set-DoubaoSkinStartupRegistration -Enabled $Enabled
    if ($Enabled) {
        Start-DoubaoSkinEventSupervisor | Out-Null
        Write-Output "Start at login enabled. The manager window will be visible after the next login."
    } else {
        Write-Output "Start at login disabled. The current manager and skin session remain active."
    }
}

function Open-DoubaoFromManager {
    $install = Get-OfficialDoubaoInstall
    $config = Get-DoubaoSkinConfig
    if (@(Get-DoubaoFamilyProcesses -Install $install).Count -gt 0) {
        Start-Process -FilePath $install.Launcher | Out-Null
        Write-Output "Doubao is already running."
        return
    }
    if ($null -ne $config -and [bool]$config.enabled) {
        $configuredPort = [int]$config.port
        Start-OfficialDoubaoWithCdp -Install $install -Port $configuredPort
        Wait-DoubaoCdpEndpoint -Install $install -Port $configuredPort -TimeoutSeconds 40 | Out-Null
        Start-DoubaoSkinWatcher `
            -Port $configuredPort `
            -ConversationOpacity (
                Get-DoubaoSkinConversationOpacity -Config $config -Theme $null) `
            -ThemeDir ([string]$config.themeDir) `
            -ThemeId ([string]$config.themeId) | Out-Null
        Write-Output "Doubao opened with the active skin."
    } else {
        Start-OfficialDoubaoNormally -Install $install
        Write-Output "Doubao opened normally."
    }
}

function Get-DoubaoSkinStatusJson {
    $install = Get-OfficialDoubaoInstall
    $config = Get-DoubaoSkinConfig
    $state = Get-DoubaoSkinState
    $enabled = $false
    $configuredPort = $null
    $themeDirValue = $null
    $themeIdValue = $null
    $themeNameValue = $null
    $startAtLogin = $false
    $conversationOpacityValue = [double]0.60
    if ($null -ne $config) {
        $enabled = [bool]$config.enabled
        $startAtLogin = Get-DoubaoSkinStartAtLogin -Config $config
        if ($null -ne $config.port) { $configuredPort = [int]$config.port }
        $themeDirValue = $config.themeDir
        $themeIdValue = $config.themeId
        $themeNameValue = $config.themeName
        $themeForOpacity = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$config.themeDir)) {
            try {
                $themeForOpacity = Get-ValidatedLibraryTheme `
                    -Source ([string]$config.themeDir)
            } catch {}
        }
        $conversationOpacityValue = Get-DoubaoSkinConversationOpacity `
            -Config $config `
            -Theme $themeForOpacity
    }
    $watcherRunning = $false
    if ($null -ne $state -and $null -ne $state.watcherPid) {
        $watcherRunning = Test-WatcherProcess -WatcherPid ([int]$state.watcherPid)
    }
    $eventSupervisorRunning = Test-DoubaoSkinEventSupervisorRunning
    $running = @(Get-DoubaoFamilyProcesses -Install $install).Count -gt 0
    $skinActive = $false
    if ($null -ne $configuredPort) {
        $skinActive = Test-DoubaoSkinCdpReady -Install $install -Port $configuredPort
    }
    return ([ordered]@{
        schema = "doubao-skin-status/1"
        enabled = $enabled
        port = $configuredPort
        themeDir = $themeDirValue
        themeId = $themeIdValue
        themeName = $themeNameValue
        conversationOpacity = $conversationOpacityValue
        startAtLogin = $startAtLogin
        startupRegistered = (Test-DoubaoSkinStartupRegistration)
        managerInstallPath = (Split-Path -Parent $script:ProjectRoot)
        running = $running
        skinActive = $skinActive
        supervisorRunning = ($watcherRunning -and $eventSupervisorRunning)
        doubaoVersion = $install.LauncherVersion
        chromiumVersion = $install.ChromiumVersion
        doubaoExecutable = $install.Main
        signerThumbprint = $install.SignerThumbprint
    } | ConvertTo-Json -Depth 6)
}

function Invoke-SupervisorOnce {
    param([int]$NormalLaunchProcessId = 0)
    $mutex = New-Object Threading.Mutex($false, "Local\DoubaoSkinSupervisor")
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
        if (-not $acquired) {
            return
        }
        $config = Get-DoubaoSkinConfig
        if ($null -eq $config -or -not [bool]$config.enabled) {
            return
        }
        Set-DoubaoSkinStartupRegistration `
            -Enabled (Get-DoubaoSkinStartAtLogin -Config $config)
        $portValue = [int]$config.port
        Assert-ValidPort -Port $portValue
        $theme = Get-ValidatedLibraryTheme -Source ([string]$config.themeDir)
        $install = Get-OfficialDoubaoInstall
        Start-DoubaoSkinWatcher `
            -Port $portValue `
            -ConversationOpacity (
                Get-DoubaoSkinConversationOpacity -Config $config -Theme $theme) `
            -ThemeDir ([string]$theme.directory) `
            -ThemeId ([string]$theme.id) | Out-Null

        if ($NormalLaunchProcessId -gt 0) {
            $observedProcess = Get-ObservedNormalDoubaoMain `
                -Install $install `
                -ProcessId $NormalLaunchProcessId
            if ($null -eq $observedProcess) {
                return
            }
            $mainProcesses = @($observedProcess)
        } else {
            $mainProcesses = @(Get-DoubaoMainProcesses -Install $install)
        }
        if ($mainProcesses.Count -eq 0) {
            return
        }
        $hasExpectedArguments = @($mainProcesses | Where-Object {
            Test-DoubaoMainHasCdpArguments -Process $_ -Port $portValue
        }).Count -gt 0
        if ($hasExpectedArguments -and (Test-DoubaoSkinCdpReady -Install $install -Port $portValue)) {
            return
        }

        Start-Sleep -Milliseconds 1200
        if ($NormalLaunchProcessId -gt 0) {
            $observedProcess = Get-ObservedNormalDoubaoMain `
                -Install $install `
                -ProcessId $NormalLaunchProcessId
            if ($null -eq $observedProcess) {
                return
            }
            $mainProcesses = @($observedProcess)
        } else {
            $mainProcesses = @(Get-DoubaoMainProcesses -Install $install)
        }
        if ($mainProcesses.Count -eq 0) {
            return
        }
        $hasExpectedArguments = @($mainProcesses | Where-Object {
            Test-DoubaoMainHasCdpArguments -Process $_ -Port $portValue
        }).Count -gt 0
        if ($hasExpectedArguments -and (Test-DoubaoSkinCdpReady -Install $install -Port $portValue)) {
            return
        }

        Stop-OfficialDoubao -Install $install
        if (-not (Test-PortAvailable -Port $portValue)) {
            Fail-DoubaoSkin "The configured skin port is occupied; the normal Doubao launch was left closed."
        }
        Start-OfficialDoubaoWithCdp -Install $install -Port $portValue
        Wait-DoubaoCdpEndpoint -Install $install -Port $portValue -TimeoutSeconds 40 | Out-Null
    } finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

Assert-ValidPort -Port $Port

$commandOutput = @(switch ($Command) {
    "status" {
        Get-DoubaoSkinStatusJson
    }
    "list-themes" {
        Get-ThemeLibraryJson
    }
    "activate-library" {
        $selectedTheme = Get-ValidatedLibraryTheme -Source $ThemeDir
        Activate-LibraryTheme -Theme $selectedTheme -RequestedPort $Port
    }
    "enable-default" {
        Ensure-ThemeLibrary
        $selectedTheme = Get-ValidatedLibraryTheme -Source (Join-Path $script:ThemesRoot "mbti-boy-infp")
        Activate-LibraryTheme -Theme $selectedTheme -RequestedPort $Port
    }
    "disable" {
        Disable-DoubaoSkin
    }
    "enable-startup" {
        Set-DoubaoSkinStartupPreference -Enabled $true
    }
    "disable-startup" {
        Set-DoubaoSkinStartupPreference -Enabled $false
    }
    "set-conversation-opacity" {
        $config = Get-DoubaoSkinConfig
        if ($null -eq $config -or -not [bool]$config.enabled) {
            Fail-DoubaoSkin "Enable a theme before changing conversation mask opacity."
        }
        if ([string]::IsNullOrWhiteSpace($ConversationOpacity)) {
            Fail-DoubaoSkin "Conversation mask opacity is required."
        }
        $opacityValue = ConvertTo-DoubaoSkinConversationOpacity `
            -Value $ConversationOpacity
        $selectedTheme = Get-ValidatedLibraryTheme `
            -Source ([string]$config.themeDir)
        Activate-LibraryTheme `
            -Theme $selectedTheme `
            -RequestedPort ([int]$config.port) `
            -ConversationOpacityOverride $opacityValue `
            -OpacityChange
    }
    "open" {
        Open-DoubaoFromManager
    }
    "reveal-themes" {
        Ensure-ThemeLibrary
        Start-Process -FilePath "explorer.exe" -ArgumentList @($script:ThemesRoot) | Out-Null
        Write-Output $script:ThemesRoot
    }
    "verify" {
        $config = Get-DoubaoSkinConfig
        if ($null -eq $config -or -not [bool]$config.enabled) {
            Fail-DoubaoSkin "No enabled skin configuration exists."
        }
        $install = Get-OfficialDoubaoInstall
        Assert-DoubaoCdpEndpoint -Install $install -Port ([int]$config.port) | Out-Null
        $opacityValue = Get-DoubaoSkinConversationOpacity `
            -Config $config `
            -Theme $null
        Invoke-DoubaoSkinNode -Arguments @(
            "--verify",
            "--port", [string]$config.port,
            "--theme-dir", [string]$config.themeDir,
            "--conversation-opacity",
            (Format-DoubaoSkinConversationOpacity -Value $opacityValue),
            "--timeout-ms", "20000"
        )
    }
    "ensure-supervisor" {
        $config = Get-DoubaoSkinConfig
        if ($null -ne $config -and [bool]$config.enabled) {
            $startAtLogin = Get-DoubaoSkinStartAtLogin -Config $config
            if ($null -eq $config.PSObject.Properties["startAtLogin"] -or
                $null -eq $config.PSObject.Properties["conversationOpacity"]) {
                $theme = Get-ValidatedLibraryTheme -Source ([string]$config.themeDir)
                $opacityValue = Get-DoubaoSkinConversationOpacity `
                    -Config $config `
                    -Theme $theme
                Write-DoubaoSkinConfig `
                    -Enabled ([bool]$config.enabled) `
                    -StartAtLogin $startAtLogin `
                    -Port ([int]$config.port) `
                    -ConversationOpacity $opacityValue `
                    -ThemeDir ([string]$config.themeDir) `
                    -ThemeId ([string]$config.themeId) `
                    -ThemeName ([string]$config.themeName)
                $config = Get-DoubaoSkinConfig
            }
            Set-DoubaoSkinStartupRegistration `
                -Enabled $startAtLogin
            Start-DoubaoSkinEventSupervisor | Out-Null
            # The installer stops the previous watcher before replacing the
            # runtime. Reconcile the already-running official app as well as
            # future process-start events so an in-place upgrade is complete
            # without asking the user to restart Doubao.
            Invoke-SupervisorOnce
        }
    }
    "supervise-once" {
        Invoke-SupervisorOnce -NormalLaunchProcessId $ObservedProcessId
    }
})
$outputText = (
    $commandOutput |
        ForEach-Object { [string]$_ }
) -join [Environment]::NewLine
Write-OperationResult -ExitCode 0 -OutputText $outputText
if ([string]::IsNullOrWhiteSpace($OperationResultPath)) {
    $commandOutput
}
