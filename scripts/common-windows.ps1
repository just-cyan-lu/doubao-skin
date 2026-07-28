Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$script:ScriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ProjectRoot = Split-Path -Parent $script:ScriptsRoot
$script:IdentityPath = Join-Path $script:ProjectRoot "assets\windows-app-identity.json"
$script:InjectorPath = Join-Path $script:ProjectRoot "scripts\injector.mjs"
$script:ThemePackagePath = Join-Path $script:ProjectRoot "scripts\theme-package.mjs"
$script:NodePath = Join-Path $script:ProjectRoot "bin\node.exe"
$script:StateRoot = Join-Path $env:LOCALAPPDATA "DoubaoSkin"
$script:ThemesRoot = Join-Path $script:StateRoot "themes"
$script:ConfigPath = Join-Path $script:StateRoot "config.json"
$script:StatePath = Join-Path $script:StateRoot "state.json"
$script:ThemeLibraryMarkerPath = Join-Path $script:StateRoot "bundled-theme-library-v2"
$script:WatcherLogPath = Join-Path $script:StateRoot "injector.log"
$script:WatcherErrorLogPath = Join-Path $script:StateRoot "injector-error.log"
$script:ManagerErrorLogPath = Join-Path $script:StateRoot "manager-error.log"
$script:DefaultPort = 9451
$script:StartupRegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$script:StartupRegistryName = "DoubaoSkin"
$script:TrayScriptPath = Join-Path $script:ProjectRoot "windows\DoubaoSkinTray.ps1"
$script:WindowsSupervisorPath = Join-Path $script:ProjectRoot "scripts\supervisor-windows.ps1"
$script:WindowsPowerShellPath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"

function Fail-DoubaoSkin {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw "Doubao Skin: $Message"
}

function Ensure-DoubaoSkinStateRoot {
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $script:ThemesRoot -Force | Out-Null
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $text = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true)))
    return $text | ConvertFrom-Json
}

function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    Ensure-DoubaoSkinStateRoot
    $temporary = "$Path.tmp.$PID"
    $json = $Value | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-DoubaoSkinIdentity {
    $identity = Read-JsonFile -Path $script:IdentityPath
    if ($null -eq $identity -or $identity.schema -ne "doubao-skin-windows-identity/1") {
        Fail-DoubaoSkin "Windows identity contract is missing or invalid."
    }
    return $identity
}

function Assert-OrdinaryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$Directory
    )
    if ($Directory) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Fail-DoubaoSkin "$Label is missing: $Path"
        }
    } elseif (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail-DoubaoSkin "$Label is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail-DoubaoSkin "$Label cannot be a reparse point: $Path"
    }
    return $item
}

function Assert-OfficialDoubaoFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedProduct,
        [Parameter(Mandatory = $true)]$Identity
    )
    $item = Assert-OrdinaryPath -Path $Path -Label $ExpectedProduct
    if ($item.VersionInfo.CompanyName -ne [string]$Identity.publisher) {
        Fail-DoubaoSkin "Unexpected Doubao company metadata on $Path"
    }
    if ($item.VersionInfo.ProductName -ne $ExpectedProduct) {
        Fail-DoubaoSkin "Unexpected product metadata on $Path"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -ne "Valid") {
        Fail-DoubaoSkin "The official Doubao signature is not valid: $Path"
    }
    if ($null -eq $signature.SignerCertificate) {
        Fail-DoubaoSkin "Doubao has no signing certificate: $Path"
    }
    $subjectNeedle = [string]$Identity.signer.subjectContains
    if ([string]::IsNullOrWhiteSpace($subjectNeedle) -or
        $signature.SignerCertificate.Subject.IndexOf($subjectNeedle, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Fail-DoubaoSkin "Doubao signer organization does not match the verified identity."
    }
    $allowedThumbprints = @($Identity.signer.thumbprints | ForEach-Object { ([string]$_).ToUpperInvariant() })
    $actualThumbprint = $signature.SignerCertificate.Thumbprint.ToUpperInvariant()
    if ($allowedThumbprints -notcontains $actualThumbprint) {
        Fail-DoubaoSkin "Doubao signing certificate is not in the verified allow-list."
    }
    return [pscustomobject]@{
        Path = $item.FullName
        ProductName = $item.VersionInfo.ProductName
        ProductVersion = $item.VersionInfo.ProductVersion
        FileVersion = $item.VersionInfo.FileVersion
        CompanyName = $item.VersionInfo.CompanyName
        SignerThumbprint = $actualThumbprint
    }
}

function Get-OfficialDoubaoInstall {
    $identity = Get-DoubaoSkinIdentity
    $entry = Get-ItemProperty -LiteralPath ([string]$identity.uninstallKey) -ErrorAction SilentlyContinue
    if ($null -eq $entry) {
        Fail-DoubaoSkin "The official per-user Doubao installation was not found."
    }
    if (@($identity.displayNames) -notcontains [string]$entry.DisplayName) {
        Fail-DoubaoSkin "The Doubao uninstall registration has an unexpected display name."
    }
    if ([string]$entry.Publisher -ne [string]$identity.publisher) {
        Fail-DoubaoSkin "The Doubao uninstall registration has an unexpected publisher."
    }

    $base = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA ([string]$identity.installRootRelativeToLocalAppData)))
    $application = Join-Path $base "Application"
    $appDirectory = Join-Path $application "app"
    Assert-OrdinaryPath -Path $base -Label "Doubao install root" -Directory | Out-Null
    Assert-OrdinaryPath -Path $application -Label "Doubao application directory" -Directory | Out-Null
    Assert-OrdinaryPath -Path $appDirectory -Label "Doubao runtime directory" -Directory | Out-Null

    $launcher = [IO.Path]::GetFullPath((Join-Path $base ([string]$identity.launcherRelativePath)))
    $main = [IO.Path]::GetFullPath((Join-Path $base ([string]$identity.mainRelativePath)))
    $launcherInfo = Assert-OfficialDoubaoFile -Path $launcher -ExpectedProduct ([string]$identity.launcherProductName) -Identity $identity
    $mainInfo = Assert-OfficialDoubaoFile -Path $main -ExpectedProduct ([string]$identity.mainProductName) -Identity $identity

    return [pscustomobject]@{
        Base = $base
        Application = $application
        AppDirectory = $appDirectory
        Launcher = $launcher
        Main = $main
        LauncherVersion = $launcherInfo.ProductVersion
        ChromiumVersion = $mainInfo.ProductVersion
        Publisher = [string]$identity.publisher
        SignerThumbprint = $mainInfo.SignerThumbprint
        Identity = $identity
    }
}

function Assert-DoubaoSkinNode {
    if (-not (Test-Path -LiteralPath $script:NodePath -PathType Leaf)) {
        Fail-DoubaoSkin "The bundled Windows Node.js runtime is missing."
    }
    $version = (& $script:NodePath --version 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]$version -notmatch "^v([0-9]+)\.") {
        Fail-DoubaoSkin "The bundled Node.js runtime cannot be executed."
    }
    if ([int]$Matches[1] -lt 22) {
        Fail-DoubaoSkin "Node.js 22 or newer is required."
    }
    return [string]$version
}

function Get-DoubaoFamilyProcesses {
    param([Parameter(Mandatory = $true)]$Install)
    $prefix = $Install.Base.TrimEnd("\") + "\"
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and
        $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Get-DoubaoMainProcesses {
    param([Parameter(Mandatory = $true)]$Install)
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and
        $_.ExecutablePath.Equals($Install.Main, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$_.CommandLine -notmatch "(^|\s)--type=")
    })
}

function Get-ProcessOwnerName {
    param([Parameter(Mandatory = $true)]$Process)
    $owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwner
    if ($owner.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace([string]$owner.User)) {
        Fail-DoubaoSkin "Unable to verify the owner of process $($Process.ProcessId)."
    }
    if ([string]::IsNullOrWhiteSpace([string]$owner.Domain)) {
        return [string]$owner.User
    }
    return "$($owner.Domain)\$($owner.User)"
}

function Get-InteractiveUserName {
    $userName = [string](Get-CimInstance Win32_ComputerSystem).UserName
    if ([string]::IsNullOrWhiteSpace($userName)) {
        Fail-DoubaoSkin "No interactive Windows user is logged on."
    }
    return $userName
}

function Get-ObservedNormalDoubaoMain {
    param(
        [Parameter(Mandatory = $true)]$Install,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )
    if ($ProcessId -le 0) {
        return $null
    }
    $process = Get-CimInstance Win32_Process `
        -Filter "ProcessId=$ProcessId" `
        -ErrorAction SilentlyContinue
    if ($null -eq $process -or
        [string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or
        -not $process.ExecutablePath.Equals($Install.Main, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$process.CommandLine -match "(^|\s)--type=" -or
        [string]$process.CommandLine -match "(^|\s)--remote-debugging-(?:address|port)=") {
        return $null
    }
    $owner = Get-ProcessOwnerName -Process $process
    $interactiveUser = Get-InteractiveUserName
    if (-not $owner.Equals($interactiveUser, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    Assert-OfficialDoubaoFile `
        -Path $process.ExecutablePath `
        -ExpectedProduct ([string]$Install.Identity.mainProductName) `
        -Identity $Install.Identity | Out-Null
    return $process
}

function Test-DoubaoMainHasCdpArguments {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $line = [string]$Process.CommandLine
    return $line.Contains("--remote-debugging-address=127.0.0.1") -and
        $line.Contains("--remote-debugging-port=$Port")
}

function Get-CdpListeners {
    param([Parameter(Mandatory = $true)][int]$Port)
    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Test-PortAvailable {
    param([Parameter(Mandatory = $true)][int]$Port)
    return @(Get-CdpListeners -Port $Port).Count -eq 0
}

function Select-DoubaoSkinPort {
    param([int]$Preferred = $script:DefaultPort)
    for ($candidate = $Preferred; $candidate -le [Math]::Min(65535, $Preferred + 100); $candidate++) {
        if (Test-PortAvailable -Port $candidate) {
            return $candidate
        }
    }
    Fail-DoubaoSkin "No loopback port is available in the configured range."
}

function Test-AllowedDoubaoPageUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)]$Identity
    )
    foreach ($allowedValue in @($Identity.allowedPageUrls)) {
        $allowed = ([string]$allowedValue).TrimEnd("/")
        if ($Url.Equals($allowed, [StringComparison]::Ordinal) -or
            $Url.StartsWith($allowed + "/", [StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Assert-DoubaoCdpEndpoint {
    param(
        [Parameter(Mandatory = $true)]$Install,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $listeners = @(Get-CdpListeners -Port $Port)
    if ($listeners.Count -eq 0) {
        Fail-DoubaoSkin "Doubao is not listening on the configured CDP port."
    }
    $interactiveUser = Get-InteractiveUserName
    foreach ($listener in $listeners) {
        if (@("127.0.0.1", "::1") -notcontains [string]$listener.LocalAddress) {
            Fail-DoubaoSkin "Rejected a CDP listener outside loopback."
        }
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
        if ($null -eq $process -or -not $process.ExecutablePath.Equals($Install.Main, [StringComparison]::OrdinalIgnoreCase)) {
            Fail-DoubaoSkin "The CDP listener does not belong to the verified Doubao executable."
        }
        $owner = Get-ProcessOwnerName -Process $process
        if (-not $owner.Equals($interactiveUser, [StringComparison]::OrdinalIgnoreCase)) {
            Fail-DoubaoSkin "The CDP listener is owned by a different Windows account."
        }
        Assert-OfficialDoubaoFile -Path $process.ExecutablePath -ExpectedProduct ([string]$Install.Identity.mainProductName) -Identity $Install.Identity | Out-Null
    }

    $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -UseBasicParsing -TimeoutSec 3
    if ([string]$version.Browser -notmatch "^Chrome/[0-9.]+$" -or [string]$version."Protocol-Version" -ne "1.3") {
        Fail-DoubaoSkin "The CDP version endpoint is not the expected Chromium endpoint."
    }
    # Windows PowerShell 5.1 can emit a JSON array from Invoke-RestMethod as
    # one pipeline object. Flatten that response explicitly; otherwise a
    # multi-target CDP session concatenates each target's properties and the
    # allow-list check fails closed even when the real chat page is present.
    $targetResponse = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$Port/json/list" `
        -UseBasicParsing `
        -TimeoutSec 3
    $targets = @(
        foreach ($target in $targetResponse) {
            $target
        }
    )
    $validTargets = @($targets | Where-Object {
        $_.type -eq "page" -and
        (Test-AllowedDoubaoPageUrl -Url ([string]$_.url) -Identity $Install.Identity)
    })
    if ($validTargets.Count -eq 0) {
        Fail-DoubaoSkin "No verified Doubao chat renderer is exposed by CDP."
    }
    return [pscustomobject]@{
        Browser = [string]$version.Browser
        ListenerCount = $listeners.Count
        TargetCount = $validTargets.Count
    }
}

function Wait-DoubaoCdpEndpoint {
    param(
        [Parameter(Mandatory = $true)]$Install,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutSeconds = 30
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return Assert-DoubaoCdpEndpoint -Install $Install -Port $Port
        } catch {
            if ((Get-Date) -ge $deadline) {
                throw
            }
            Start-Sleep -Milliseconds 500
        }
    } while ($true)
}

function Stop-OfficialDoubao {
    param([Parameter(Mandatory = $true)]$Install)
    $mainProcesses = Get-DoubaoMainProcesses -Install $Install
    foreach ($process in $mainProcesses) {
        try {
            (Get-Process -Id $process.ProcessId -ErrorAction Stop).CloseMainWindow() | Out-Null
        } catch {}
    }
    $deadline = (Get-Date).AddSeconds(8)
    $stableEmptySamples = 0
    do {
        $remaining = @(Get-DoubaoFamilyProcesses -Install $Install)
        if ($remaining.Count -eq 0) {
            $stableEmptySamples += 1
            if ($stableEmptySamples -ge 3) {
                return
            }
        } else {
            $stableEmptySamples = 0
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    # Electron launchers and helpers can briefly replace one another while
    # shutting down. A single process snapshot leaves a race where a newly
    # spawned helper survives and makes the next CDP launch silently fail.
    # Re-enumerate the already verified install family until it remains empty
    # for three consecutive samples.
    $deadline = (Get-Date).AddSeconds(10)
    $stableEmptySamples = 0
    do {
        $remaining = @(Get-DoubaoFamilyProcesses -Install $Install)
        if ($remaining.Count -eq 0) {
            $stableEmptySamples += 1
            if ($stableEmptySamples -ge 3) {
                return
            }
        } else {
            $stableEmptySamples = 0
            foreach ($process in ($remaining | Sort-Object ProcessId -Descending)) {
                Stop-Process `
                    -Id $process.ProcessId `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    $remainingIds = @(
        Get-DoubaoFamilyProcesses -Install $Install |
            Sort-Object ProcessId |
            ForEach-Object { [string]$_.ProcessId }
    )
    Fail-DoubaoSkin (
        "Doubao did not exit cleanly. Remaining verified process IDs: " +
        ($remainingIds -join ", "))
}

function Start-OfficialDoubaoWithCdp {
    param(
        [Parameter(Mandatory = $true)]$Install,
        [Parameter(Mandatory = $true)][int]$Port
    )
    if (-not (Test-PortAvailable -Port $Port)) {
        Fail-DoubaoSkin "Port $Port is already occupied."
    }
    $arguments = @(
        "--remote-debugging-address=127.0.0.1",
        "--remote-debugging-port=$Port",
        "--launch_from=doubao_skin"
    )
    Start-Process -FilePath $Install.Launcher -ArgumentList $arguments | Out-Null
}

function Start-OfficialDoubaoNormally {
    param([Parameter(Mandatory = $true)]$Install)
    Start-Process -FilePath $Install.Launcher | Out-Null
}

function Invoke-DoubaoSkinNode {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    Assert-DoubaoSkinNode | Out-Null
    $output = @(& $script:NodePath $script:InjectorPath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Fail-DoubaoSkin (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }
    return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
}

function Quote-WindowsProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-DoubaoSkinEventSupervisorProcesses {
    if (-not (Test-Path -LiteralPath $script:WindowsSupervisorPath -PathType Leaf)) {
        return @()
    }
    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.Equals($script:WindowsPowerShellPath, [StringComparison]::OrdinalIgnoreCase) -and
            ([string]$_.CommandLine).IndexOf(
                $script:WindowsSupervisorPath,
                [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
}

function Test-DoubaoSkinEventSupervisorRunning {
    return @(Get-DoubaoSkinEventSupervisorProcesses).Count -gt 0
}

function Stop-DoubaoSkinEventSupervisor {
    foreach ($process in @(Get-DoubaoSkinEventSupervisorProcesses)) {
        if ($process.ProcessId -ne $PID) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-DoubaoSkinEventSupervisor {
    $existing = @(Get-DoubaoSkinEventSupervisorProcesses)
    if ($existing.Count -gt 0) {
        return [int]$existing[0].ProcessId
    }
    Assert-OrdinaryPath `
        -Path $script:WindowsSupervisorPath `
        -Label "Windows event supervisor" | Out-Null
    $arguments = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-File", (Quote-WindowsProcessArgument -Value $script:WindowsSupervisorPath)
    ) -join " "
    $process = Start-Process `
        -FilePath $script:WindowsPowerShellPath `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -PassThru
    return $process.Id
}

function Get-DoubaoSkinConfig {
    return Read-JsonFile -Path $script:ConfigPath
}

function Get-DoubaoSkinStartAtLogin {
    param($Config)
    if ($null -eq $Config) {
        return $true
    }
    $property = $Config.PSObject.Properties["startAtLogin"]
    if ($null -eq $property) {
        # Configurations written before this preference existed always
        # registered the manager at login, so preserve that behavior while
        # migrating them to the explicit setting.
        return $true
    }
    return [bool]$property.Value
}

function ConvertTo-DoubaoSkinConversationOpacity {
    param([Parameter(Mandatory = $true)]$Value)
    try {
        $opacity = [Convert]::ToDouble(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        Fail-DoubaoSkin "Conversation mask opacity must be between 0 and 1."
    }
    if ([double]::IsNaN($opacity) -or
        [double]::IsInfinity($opacity) -or
        $opacity -lt 0 -or
        $opacity -gt 1) {
        Fail-DoubaoSkin "Conversation mask opacity must be between 0 and 1."
    }
    return [Math]::Round($opacity, 4)
}

function Format-DoubaoSkinConversationOpacity {
    param([Parameter(Mandatory = $true)][double]$Value)
    return $Value.ToString("0.####", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-DoubaoSkinConversationOpacity {
    param(
        $Config,
        $Theme
    )
    if ($null -ne $Config) {
        $property = $Config.PSObject.Properties["conversationOpacity"]
        if ($null -ne $property -and $null -ne $property.Value) {
            return ConvertTo-DoubaoSkinConversationOpacity -Value $property.Value
        }
    }
    if ($null -ne $Theme) {
        $property = $Theme.PSObject.Properties["conversationOpacity"]
        if ($null -ne $property -and $null -ne $property.Value) {
            return ConvertTo-DoubaoSkinConversationOpacity -Value $property.Value
        }
    }
    return [double]0.66
}

function Write-DoubaoSkinConfig {
    param(
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][bool]$StartAtLogin,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][double]$ConversationOpacity,
        [string]$ThemeDir,
        [string]$ThemeId,
        [string]$ThemeName
    )
    Write-JsonFileAtomic -Path $script:ConfigPath -Value ([ordered]@{
        schema = "doubao-skin-config/1"
        enabled = $Enabled
        startAtLogin = $StartAtLogin
        port = $Port
        conversationOpacity = $ConversationOpacity
        themeDir = $ThemeDir
        themeId = $ThemeId
        themeName = $ThemeName
        updatedAt = [DateTime]::UtcNow.ToString("o")
    })
}

function Get-DoubaoSkinState {
    return Read-JsonFile -Path $script:StatePath
}

function Write-DoubaoSkinState {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][double]$ConversationOpacity,
        [string]$ThemeDir,
        [string]$ThemeId,
        [Nullable[int]]$WatcherPid
    )
    Write-JsonFileAtomic -Path $script:StatePath -Value ([ordered]@{
        schema = "doubao-skin-state/3"
        status = $Status
        persistent = $true
        port = $Port
        conversationOpacity = $ConversationOpacity
        themeDir = $ThemeDir
        themeId = $ThemeId
        watcherPid = $WatcherPid
        updatedAt = [DateTime]::UtcNow.ToString("o")
    })
}

function Test-WatcherProcess {
    param([Nullable[int]]$WatcherPid)
    if ($null -eq $WatcherPid) {
        return $false
    }
    $watcherPidValue = [int]$WatcherPid
    if ($watcherPidValue -le 0) {
        return $false
    }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$watcherPidValue" -ErrorAction SilentlyContinue
    if ($null -eq $process -or [string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) {
        return $false
    }
    return $process.ExecutablePath.Equals($script:NodePath, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$process.CommandLine).Contains($script:InjectorPath) -and
        ([string]$process.CommandLine).Contains("--watch")
}

function Stop-DoubaoSkinWatcher {
    $state = Get-DoubaoSkinState
    if ($null -ne $state -and $null -ne $state.watcherPid) {
        $watcherPid = [int]$state.watcherPid
        if (Test-WatcherProcess -WatcherPid $watcherPid) {
            Stop-Process -Id $watcherPid -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-DoubaoSkinWatcher {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][double]$ConversationOpacity,
        [Parameter(Mandatory = $true)][string]$ThemeDir,
        [Parameter(Mandatory = $true)][string]$ThemeId
    )
    $state = Get-DoubaoSkinState
    if ($null -ne $state -and $null -ne $state.watcherPid) {
        $existingPid = [int]$state.watcherPid
        if (Test-WatcherProcess -WatcherPid $existingPid) {
            return $existingPid
        }
    }
    Stop-DoubaoSkinWatcher
    Ensure-DoubaoSkinStateRoot
    Assert-DoubaoSkinNode | Out-Null
    $arguments = @(
        (Quote-WindowsProcessArgument -Value $script:InjectorPath),
        "--watch",
        "--port", [string]$Port,
        "--theme-dir", (Quote-WindowsProcessArgument -Value $ThemeDir),
        "--conversation-opacity",
        (Format-DoubaoSkinConversationOpacity -Value $ConversationOpacity),
        "--timeout-ms", "45000"
    ) -join " "
    $process = Start-Process -FilePath $script:NodePath `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $script:WatcherLogPath `
        -RedirectStandardError $script:WatcherErrorLogPath `
        -PassThru
    Write-DoubaoSkinState `
        -Status "active" `
        -Port $Port `
        -ConversationOpacity $ConversationOpacity `
        -ThemeDir $ThemeDir `
        -ThemeId $ThemeId `
        -WatcherPid $process.Id
    return $process.Id
}

function Get-DoubaoSkinStartupCommand {
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f `
        $script:WindowsPowerShellPath, $script:TrayScriptPath)
}

function Test-DoubaoSkinStartupRegistration {
    if (-not (Test-Path -LiteralPath $script:TrayScriptPath -PathType Leaf)) {
        return $false
    }
    try {
        $actual = Get-ItemPropertyValue `
            -Path $script:StartupRegistryPath `
            -Name $script:StartupRegistryName `
            -ErrorAction Stop
        return [string]$actual -eq (Get-DoubaoSkinStartupCommand)
    } catch {
        return $false
    }
}

function Set-DoubaoSkinStartupRegistration {
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    if ($Enabled) {
        if (Test-Path -LiteralPath $script:TrayScriptPath -PathType Leaf) {
            New-Item -Path $script:StartupRegistryPath -Force | Out-Null
            Set-ItemProperty -Path $script:StartupRegistryPath `
                -Name $script:StartupRegistryName `
                -Value (Get-DoubaoSkinStartupCommand)
        }
    } else {
        Remove-ItemProperty -Path $script:StartupRegistryPath `
            -Name $script:StartupRegistryName `
            -ErrorAction SilentlyContinue
    }
}

function Test-DoubaoSkinCdpReady {
    param(
        [Parameter(Mandatory = $true)]$Install,
        [Parameter(Mandatory = $true)][int]$Port
    )
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            Assert-DoubaoCdpEndpoint -Install $Install -Port $Port | Out-Null
            return $true
        } catch {
            if ($attempt -lt 2) {
                Start-Sleep -Milliseconds 200
            }
        }
    }
    return $false
}

function Assert-ValidPort {
    param([Parameter(Mandatory = $true)][int]$Port)
    if ($Port -lt 1024 -or $Port -gt 65535) {
        Fail-DoubaoSkin "Port must be between 1024 and 65535."
    }
}
