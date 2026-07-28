Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

$scriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptsRoot "common-windows.ps1")

$managerScript = Join-Path $scriptsRoot "manage-doubao-skin-windows.ps1"
$supervisorLog = Join-Path $script:StateRoot "supervisor-windows.log"
$mutex = New-Object Threading.Mutex($false, "Local\DoubaoSkinWindowsEventSupervisor")
$acquired = $false
$watcher = $null

function Write-SupervisorLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    try {
        Ensure-DoubaoSkinStateRoot
        $line = "{0} {1}{2}" -f `
            [DateTime]::UtcNow.ToString("o"), `
            $Message, `
            [Environment]::NewLine
        [IO.File]::AppendAllText(
            $supervisorLog,
            $line,
            (New-Object Text.UTF8Encoding($false)))
    } catch {}
}

function Invoke-ManagerChild {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $parts = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-File", (Quote-WindowsProcessArgument -Value $managerScript)
    )
    foreach ($argument in $Arguments) {
        $parts += Quote-WindowsProcessArgument -Value $argument
    }
    $process = Start-Process `
        -FilePath $script:WindowsPowerShellPath `
        -ArgumentList ($parts -join " ") `
        -WindowStyle Hidden `
        -PassThru
    # Start-Process -Wait can wait for the manager's persistent Node watcher
    # descendants. Wait on the manager process object only so the WMI event
    # loop becomes active as soon as that one command exits.
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        Write-SupervisorLog -Message "manager command failed with exit code $($process.ExitCode)"
    }
}

try {
    $acquired = $mutex.WaitOne(0)
    if (-not $acquired) {
        exit 0
    }
    $config = Get-DoubaoSkinConfig
    if ($null -eq $config -or -not [bool]$config.enabled) {
        exit 0
    }
    $install = Get-OfficialDoubaoInstall
    $query = New-Object Management.WqlEventQuery -ArgumentList @(
        "SELECT * FROM __InstanceCreationEvent WITHIN 1 " +
        "WHERE TargetInstance ISA 'Win32_Process' " +
        "AND TargetInstance.Name = 'Doubao.exe'")
    $watcher = New-Object Management.ManagementEventWatcher -ArgumentList @($query)
    $watcher.Start()
    Write-SupervisorLog -Message "event supervisor started"

    # Reconcile exactly once at supervisor startup in case Doubao was already
    # open before the manager. All later recovery requires an observed PID.
    Invoke-ManagerChild -Arguments @("supervise-once")

    while ($true) {
        $eventRecord = $watcher.WaitForNextEvent()
        $currentConfig = Get-DoubaoSkinConfig
        if ($null -eq $currentConfig -or -not [bool]$currentConfig.enabled) {
            break
        }
        $startedProcessId = [int]$eventRecord.TargetInstance.ProcessId
        $observed = $null
        try {
            $observed = Get-ObservedNormalDoubaoMain `
                -Install $install `
                -ProcessId $startedProcessId
        } catch {
            Write-SupervisorLog -Message "a process-start candidate failed identity validation"
            continue
        }
        if ($null -eq $observed) {
            continue
        }
        Write-SupervisorLog -Message "verified normal Doubao launch detected"
        Invoke-ManagerChild -Arguments @(
            "supervise-once",
            "-ObservedProcessId", [string]$startedProcessId)
    }
} catch {
    Write-SupervisorLog -Message ("event supervisor stopped after an error: " + $_.Exception.Message)
    exit 1
} finally {
    if ($null -ne $watcher) {
        try { $watcher.Stop() } catch {}
        $watcher.Dispose()
    }
    if ($acquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
