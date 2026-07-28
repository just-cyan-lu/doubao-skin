param(
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [switch]$CloseAfterAudit
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class DoubaoSkinWindowAuditItem
{
    public long Handle;
    public bool Visible;
    public long ExtendedStyle;
    public string Title;
}

public static class DoubaoSkinWindowAudit
{
    public delegate bool EnumWindowsCallback(IntPtr window, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr data);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong32(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr window, int index);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    public static DoubaoSkinWindowAuditItem[] ForProcess(uint targetProcessId)
    {
        var result = new List<DoubaoSkinWindowAuditItem>();
        EnumWindows(delegate(IntPtr window, IntPtr data)
        {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId == targetProcessId)
            {
                var title = new StringBuilder(512);
                GetWindowText(window, title, title.Capacity);
                long style = IntPtr.Size == 8
                    ? GetWindowLongPtr64(window, -20).ToInt64()
                    : GetWindowLong32(window, -20);
                result.Add(new DoubaoSkinWindowAuditItem
                {
                    Handle = window.ToInt64(),
                    Visible = IsWindowVisible(window),
                    ExtendedStyle = style,
                    Title = title.ToString()
                });
            }
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
}
"@

$manager = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object {
        $_.CommandLine -like "*\windows\DoubaoSkinTray.ps1*"
    } |
    Select-Object -First 1
if ($null -eq $manager) {
    throw "The installed Doubao Skin manager is not running."
}

$windows = @([DoubaoSkinWindowAudit]::ForProcess([uint32]$manager.ProcessId))
$mainWindow = $windows |
    Where-Object { $_.Visible -and $_.Title -eq "Doubao Skin" } |
    Select-Object -First 1
$before = [ordered]@{
    processId = [int]$manager.ProcessId
    managerWindowCount = @($windows).Count
    visible = $null -ne $mainWindow
    handle = if ($null -ne $mainWindow) { [long]$mainWindow.Handle } else { 0 }
    title = if ($null -ne $mainWindow) { [string]$mainWindow.Title } else { "" }
    appWindowStyle = if ($null -ne $mainWindow) {
        (($mainWindow.ExtendedStyle -band 0x00040000) -ne 0)
    } else { $false }
    toolWindowStyle = if ($null -ne $mainWindow) {
        (($mainWindow.ExtendedStyle -band 0x00000080) -ne 0)
    } else { $false }
}

$afterClose = $null
if ($CloseAfterAudit -and $null -ne $mainWindow) {
    [void][DoubaoSkinWindowAudit]::PostMessage(
        [IntPtr]$mainWindow.Handle,
        0x0010,
        [IntPtr]::Zero,
        [IntPtr]::Zero)
    Start-Sleep -Seconds 2
    $remaining = @([DoubaoSkinWindowAudit]::ForProcess([uint32]$manager.ProcessId))
    $afterClose = [ordered]@{
        processRunning = $null -ne (
            Get-Process -Id $manager.ProcessId -ErrorAction SilentlyContinue)
        visibleManagerWindowCount = @(
            $remaining |
                Where-Object { $_.Visible -and $_.Title -eq "Doubao Skin" }
        ).Count
    }
}

$result = [ordered]@{
    schema = "doubao-skin-taskbar-audit/1"
    sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    before = $before
    afterClose = $afterClose
}
$json = $result | ConvertTo-Json -Depth 5
$temporary = "$ResultPath.tmp-$PID"
[IO.File]::WriteAllText(
    $temporary,
    $json,
    (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath $temporary -Destination $ResultPath -Force
