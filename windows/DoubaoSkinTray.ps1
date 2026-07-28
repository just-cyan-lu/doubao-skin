param([switch]$Background)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

$windowsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$runtimeRoot = Split-Path -Parent $windowsRoot
$managerScript = Join-Path $runtimeRoot "scripts\manage-doubao-skin-windows.ps1"
$projectUrl = "https://github.com/just-cyan-lu/doubao-skin"
$stringsPath = Join-Path $windowsRoot "strings.zh-CN.json"
$strings = [IO.File]::ReadAllText(
    $stringsPath,
    (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$appIconPath = Join-Path $runtimeRoot "assets\DoubaoSkin.ico"
$appIcon = $null
try {
    if (Test-Path -LiteralPath $appIconPath -PathType Leaf) {
        $appIcon = New-Object Drawing.Icon($appIconPath)
    }
} catch {}
if ($null -eq $appIcon) {
    $appIcon = [Drawing.Icon]([Drawing.SystemIcons]::Application.Clone())
}

$script:status = $null
$script:library = $null
$script:selectedTheme = $null
$script:operation = $null
$script:operationResult = $null
$script:operationSilent = $false
$script:operationReload = $false
$script:operationFailureTitle = ""
$script:exiting = $false
$script:balloonShown = $false
$script:updatingStartup = $false
$script:updatingOpacity = $false

function Format-Ui {
    param([string]$Template, [object[]]$Values)
    return [string]::Format($Template, $Values)
}

function Invoke-BackendSync {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = @(& $managerScript @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }
    return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Quote-Single {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Start-BackendOperation {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$Progress = "",
        [bool]$Reload = $true,
        [bool]$Silent = $false,
        [string]$FailureTitle = ""
    )
    if ($null -ne $script:operation -and -not $script:operation.HasExited) {
        return $false
    }
    $stateRoot = Join-Path $env:LOCALAPPDATA "DoubaoSkin"
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $nonce = "$PID-$([DateTime]::UtcNow.Ticks)"
    $script:operationResult = Join-Path $stateRoot "ui-operation-$nonce.json"
    if ($Arguments.Count -lt 1) {
        throw "A backend command is required."
    }
    $commandParts = @(
        "&",
        (Quote-Single -Value $managerScript),
        "-Command",
        (Quote-Single -Value ([string]$Arguments[0])))
    $argumentIndex = 1
    while ($argumentIndex -lt $Arguments.Count) {
        $parameterName = [string]$Arguments[$argumentIndex]
        # A quoted '-ThemeDir' is an ordinary positional string in PowerShell,
        # not a named parameter. Keep the parameter token syntactic while
        # continuing to quote its validated user-library path as data.
        switch ($parameterName) {
            "-ThemeDir" {
                if ($argumentIndex + 1 -ge $Arguments.Count) {
                    throw "The backend ThemeDir parameter is missing its value."
                }
                $commandParts += "-ThemeDir"
                $commandParts += Quote-Single -Value ([string]$Arguments[$argumentIndex + 1])
                $argumentIndex += 2
            }
            "-ConversationOpacity" {
                if ($argumentIndex + 1 -ge $Arguments.Count) {
                    throw "The backend ConversationOpacity parameter is missing its value."
                }
                $commandParts += "-ConversationOpacity"
                $commandParts += Quote-Single -Value ([string]$Arguments[$argumentIndex + 1])
                $argumentIndex += 2
            }
            default {
                throw "Unsupported backend parameter: $parameterName"
            }
        }
    }
    $commandParts += "-OperationResultPath"
    $commandParts += Quote-Single -Value $script:operationResult
    $command = $commandParts -join " "
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $script:operation = Start-Process `
        -FilePath $powershell `
        -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" `
        -WindowStyle Hidden `
        -PassThru
    $script:operationSilent = $Silent
    $script:operationReload = $Reload
    $script:operationFailureTitle = $FailureTitle
    if (-not $Silent -and -not [string]::IsNullOrWhiteSpace($Progress)) {
        $messageLabel.Text = $Progress
        Set-Busy -Value $true
    }
    return $true
}

function Read-OperationText {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }
    try {
        # The backend publishes one small atomic JSON result. Read with sharing
        # so endpoint-security software cannot strand the manager in its busy
        # state during a brief scan of that file.
        $stream = New-Object IO.FileStream -ArgumentList @(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $reader = New-Object IO.StreamReader -ArgumentList @(
                $stream,
                (New-Object Text.UTF8Encoding($false)),
                $true)
            try {
                return $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } catch {
        return ""
    }
}

function Complete-BackendOperation {
    if ($null -eq $script:operation -or -not $script:operation.HasExited) {
        return
    }
    $exitCode = $script:operation.ExitCode
    $output = ""
    $errorText = ""
    $resultText = Read-OperationText -Path $script:operationResult
    if (-not [string]::IsNullOrWhiteSpace($resultText)) {
        try {
            $result = $resultText | ConvertFrom-Json
            if ([string]$result.schema -eq "doubao-skin-ui-operation/1") {
                $output = [string]$result.output
                $errorText = [string]$result.error
                if ($exitCode -eq 0) {
                    $exitCode = [int]$result.exitCode
                }
            }
        } catch {}
    }
    if ($script:operationResult -and
        (Test-Path -LiteralPath $script:operationResult)) {
        Remove-Item `
            -LiteralPath $script:operationResult `
            -Force `
            -ErrorAction SilentlyContinue
    }
    foreach ($stalePath in @(
        Get-ChildItem `
            -LiteralPath (Join-Path $env:LOCALAPPDATA "DoubaoSkin") `
            -File `
            -Filter "ui-operation-$PID-*.json" `
            -ErrorAction SilentlyContinue
    )) {
        if ($stalePath.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-10)) {
            Remove-Item `
                -LiteralPath $stalePath.FullName `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    $silent = $script:operationSilent
    $reload = $script:operationReload
    $failureTitle = $script:operationFailureTitle
    $script:operation.Dispose()
    $script:operation = $null
    $script:operationResult = $null
    $script:operationFailureTitle = ""
    if ($exitCode -ne 0) {
        if ($reload) {
            Refresh-Data -PreferActive $false
        }
        if (-not $silent) {
            $rawMessage = if ($errorText.Trim()) {
                $errorText.Trim()
            } elseif ($output.Trim()) {
                $output.Trim()
            } else {
                $strings.operationFailed
            }
            $match = [regex]::Match($rawMessage, "Doubao Skin:\s*([^\r\n]+)")
            $friendlyMessage = if ($match.Success) {
                $match.Groups[1].Value.Trim()
            } else {
                @($rawMessage -split "\r?\n" | Where-Object { $_.Trim() })[0].Trim()
            }
            $messageLabel.Text = $friendlyMessage
            Set-Busy -Value $false
            if (-not [string]::IsNullOrWhiteSpace($failureTitle)) {
                [void][Windows.Forms.MessageBox]::Show(
                    $form,
                    $friendlyMessage,
                    $failureTitle,
                    [Windows.Forms.MessageBoxButtons]::OK,
                    [Windows.Forms.MessageBoxIcon]::Error)
            }
        }
        return
    }
    if ($reload) {
        Refresh-Data -PreferActive $false
    } elseif (-not $silent) {
        $messageLabel.Text = $strings.operationComplete
        Set-Busy -Value $false
    }
    if (-not $silent -and $output.Trim()) {
        $messageLabel.Text = $output.Trim()
    }
}

function Test-SamePath {
    param([string]$Left, [string]$Right)
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    try {
        return [IO.Path]::GetFullPath($Left).TrimEnd("\").Equals(
            [IO.Path]::GetFullPath($Right).TrimEnd("\"),
            [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-ActiveTheme {
    param($Theme)
    if ($null -eq $script:status -or -not [bool]$script:status.enabled -or $null -eq $Theme) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:status.themeDir)) {
        return Test-SamePath -Left ([string]$script:status.themeDir) -Right ([string]$Theme.directory)
    }
    return [string]$script:status.themeId -eq [string]$Theme.id
}

function Load-UnlockedBitmap {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $stream = New-Object IO.FileStream -ArgumentList @(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read)
        try {
            $source = [Drawing.Image]::FromStream($stream)
            try {
                return New-Object Drawing.Bitmap -ArgumentList @($source)
            } finally {
                $source.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $null
    }
}

function Render-Themes {
    $oldImages = $themeList.LargeImageList
    $images = New-Object Windows.Forms.ImageList
    $images.ImageSize = New-Object Drawing.Size(208, 117)
    $images.ColorDepth = [Windows.Forms.ColorDepth]::Depth32Bit
    $themeList.BeginUpdate()
    try {
        $themeList.Items.Clear()
        $themeList.LargeImageList = $images
        $index = 0
        foreach ($theme in @($script:library.themes)) {
            $bitmap = Load-UnlockedBitmap -Path ([string]$theme.backgroundPath)
            if ($null -eq $bitmap) {
                $bitmap = New-Object Drawing.Bitmap(208, 117)
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.Clear([Drawing.Color]::FromArgb(234, 235, 229))
                } finally {
                    $graphics.Dispose()
                }
            }
            $images.Images.Add($bitmap)
            $bitmap.Dispose()
            $caption = [string]$theme.name
            if (Test-ActiveTheme -Theme $theme) {
                $caption += "  " + $strings.activeBadge
            }
            $item = New-Object Windows.Forms.ListViewItem($caption, $index)
            $item.Tag = [string]$theme.directory
            $item.ToolTipText = [string]$theme.id
            [void]$themeList.Items.Add($item)
            if ($null -ne $script:selectedTheme -and
                (Test-SamePath -Left ([string]$script:selectedTheme.directory) -Right ([string]$theme.directory))) {
                $item.Selected = $true
            }
            $index++
        }
    } finally {
        $themeList.EndUpdate()
        if ($null -ne $oldImages) {
            $oldImages.Dispose()
        }
    }
    if ($themeList.Items.Count -eq 0) {
        $messageLabel.Text = $strings.noThemes
    }
    Update-ApplyButton
}

function Select-PreferredTheme {
    param([bool]$PreferActive)
    $previousDirectory = if ($null -ne $script:selectedTheme) { [string]$script:selectedTheme.directory } else { "" }
    $active = $null
    $retained = $null
    foreach ($theme in @($script:library.themes)) {
        if (Test-ActiveTheme -Theme $theme) { $active = $theme }
        if ($previousDirectory -and
            (Test-SamePath -Left $previousDirectory -Right ([string]$theme.directory))) {
            $retained = $theme
        }
    }
    if ($PreferActive -and $null -ne $active) {
        $script:selectedTheme = $active
    } elseif ($null -ne $retained) {
        $script:selectedTheme = $retained
    } elseif ($null -ne $active) {
        $script:selectedTheme = $active
    } elseif (@($script:library.themes).Count -gt 0) {
        $script:selectedTheme = @($script:library.themes)[0]
    } else {
        $script:selectedTheme = $null
    }
}

function Update-Status {
    if ($null -eq $script:status) { return }
    $script:updatingStartup = $true
    try {
        $startupCheckBox.Checked = [bool]$script:status.startAtLogin
    } finally {
        $script:updatingStartup = $false
    }
    $script:updatingOpacity = $true
    try {
        $opacityPercent = [Math]::Round(
            [Math]::Max(0, [Math]::Min(1, [double]$script:status.conversationOpacity)) * 100)
        $conversationOpacitySlider.Value = [int]$opacityPercent
        $conversationOpacityValue.Text = "$opacityPercent%"
    } finally {
        $script:updatingOpacity = $false
    }
    if ([bool]$script:status.enabled) {
        $statusTitle.Text = if ([bool]$script:status.skinActive) { $strings.skinApplied } else { $strings.persistentEnabled }
        $statusDetail.Text = if ([bool]$script:status.skinActive) {
            Format-Ui -Template $strings.usingTheme -Values @([string]$script:status.themeName)
        } else {
            Format-Ui -Template $strings.restoreNextLaunch -Values @([string]$script:status.themeName)
        }
    } else {
        $statusTitle.Text = $strings.notEnabled
        $statusDetail.Text = Format-Ui -Template $strings.officialDetected -Values @([string]$script:status.doubaoVersion)
    }
    $disableButton.Enabled = -not $script:operation -and [bool]$script:status.enabled
    $startupCheckBox.Enabled = -not $script:operation -and [bool]$script:status.enabled
    $conversationOpacitySlider.Enabled = -not $script:operation -and [bool]$script:status.enabled
    Update-ApplyButton
}

function Update-ApplyButton {
    if ($null -eq $script:selectedTheme) {
        $applyButton.Text = $strings.chooseTheme
        $applyButton.Enabled = $false
        return
    }
    if (Test-ActiveTheme -Theme $script:selectedTheme) {
        $applyButton.Text = Format-Ui -Template $strings.reapplyTheme -Values @([string]$script:selectedTheme.name)
    } elseif ($null -ne $script:status -and [bool]$script:status.enabled) {
        $applyButton.Text = Format-Ui -Template $strings.switchTheme -Values @([string]$script:selectedTheme.name)
    } else {
        $applyButton.Text = Format-Ui -Template $strings.enableTheme -Values @([string]$script:selectedTheme.name)
    }
    $applyButton.Enabled = $null -eq $script:operation
}

function Set-Busy {
    param([bool]$Value)
    $refreshButton.Enabled = -not $Value
    $openLibraryButton.Enabled = -not $Value
    $openDoubaoButton.Enabled = -not $Value
    $disableButton.Enabled = -not $Value -and $null -ne $script:status -and [bool]$script:status.enabled
    $startupCheckBox.Enabled = -not $Value -and $null -ne $script:status -and [bool]$script:status.enabled
    $conversationOpacitySlider.Enabled = -not $Value -and $null -ne $script:status -and [bool]$script:status.enabled
    $applyButton.Enabled = -not $Value -and $null -ne $script:selectedTheme
    $form.UseWaitCursor = $Value
}

function Refresh-Data {
    param([bool]$PreferActive)
    try {
        $libraryJson = Invoke-BackendSync -Arguments @("list-themes")
        $statusJson = Invoke-BackendSync -Arguments @("status")
        $script:library = $libraryJson | ConvertFrom-Json
        $script:status = $statusJson | ConvertFrom-Json
        if ([string]$script:library.schema -ne "doubao-skin-theme-library/1" -or
            [string]$script:status.schema -ne "doubao-skin-status/1") {
            throw "Invalid manager response."
        }
        Select-PreferredTheme -PreferActive $PreferActive
        Render-Themes
        Update-Status
        $invalidCount = @($script:library.invalid).Count
        if ($invalidCount -gt 0) {
            $messageLabel.Text = Format-Ui -Template $strings.invalidThemes -Values @(
                @($script:library.themes).Count,
                $invalidCount)
        } else {
            $messageLabel.Text = $strings.libraryReady
        }
    } catch {
        $statusTitle.Text = $strings.readFailed
        $statusDetail.Text = $strings.checkLogs
        $messageLabel.Text = $_.Exception.Message
    } finally {
        Set-Busy -Value $false
    }
}

$form = New-Object Windows.Forms.Form
$form.Text = $strings.windowTitle
$form.Width = 900
$form.Height = 680
$form.MinimumSize = New-Object Drawing.Size(760, 570)
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = [Drawing.Color]::FromArgb(247, 245, 238)
$form.Font = New-Object Drawing.Font("Microsoft YaHei UI", 9)
$form.Icon = $appIcon
if ($Background) {
    $form.Opacity = 0
    $form.ShowInTaskbar = $false
}

$header = New-Object Windows.Forms.Panel
$header.Dock = [Windows.Forms.DockStyle]::Top
$header.Height = 94
$header.BackColor = [Drawing.Color]::FromArgb(238, 242, 232)

$titleLabel = New-Object Windows.Forms.Label
$titleLabel.Text = "Doubao Skin"
$titleLabel.Font = New-Object Drawing.Font($form.Font.FontFamily, 20, [Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [Drawing.Color]::FromArgb(46, 71, 54)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object Drawing.Point(24, 17)

$subtitleLabel = New-Object Windows.Forms.Label
$subtitleLabel.Text = $strings.subtitle
$subtitleLabel.ForeColor = [Drawing.Color]::FromArgb(100, 115, 102)
$subtitleLabel.AutoSize = $true
$subtitleLabel.Location = New-Object Drawing.Point(27, 58)

$statusTitle = New-Object Windows.Forms.Label
$statusTitle.Text = $strings.loading
$statusTitle.Font = New-Object Drawing.Font($form.Font.FontFamily, 11, [Drawing.FontStyle]::Bold)
$statusTitle.ForeColor = [Drawing.Color]::FromArgb(49, 77, 57)
$statusTitle.AutoSize = $true
$statusTitle.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$statusTitle.Location = New-Object Drawing.Point(690, 22)

$statusDetail = New-Object Windows.Forms.Label
$statusDetail.Text = $strings.loading
$statusDetail.ForeColor = [Drawing.Color]::FromArgb(104, 117, 105)
$statusDetail.AutoEllipsis = $true
$statusDetail.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$statusDetail.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$statusDetail.SetBounds(520, 52, 350, 22)

$header.Controls.AddRange(@($titleLabel, $subtitleLabel, $statusTitle, $statusDetail))

$toolbar = New-Object Windows.Forms.Panel
$toolbar.Dock = [Windows.Forms.DockStyle]::Top
$toolbar.Height = 54
$toolbar.BackColor = [Drawing.Color]::FromArgb(250, 249, 245)

$refreshButton = New-Object Windows.Forms.Button
$refreshButton.Text = $strings.refresh
$refreshButton.SetBounds(18, 10, 84, 36)
$openLibraryButton = New-Object Windows.Forms.Button
$openLibraryButton.Text = $strings.openLibrary
$openLibraryButton.SetBounds(112, 10, 126, 36)
$startupCheckBox = New-Object Windows.Forms.CheckBox
$startupCheckBox.Text = $strings.startAtLogin
$startupCheckBox.AutoSize = $true
$startupCheckBox.Enabled = $false
$startupCheckBox.Location = New-Object Drawing.Point(262, 18)
$toolbar.Controls.AddRange(@($refreshButton, $openLibraryButton, $startupCheckBox))

$themeList = New-Object Windows.Forms.ListView
$themeList.Dock = [Windows.Forms.DockStyle]::Fill
$themeList.View = [Windows.Forms.View]::LargeIcon
$themeList.MultiSelect = $false
$themeList.HideSelection = $false
$themeList.ShowItemToolTips = $true
$themeList.BackColor = [Drawing.Color]::FromArgb(247, 245, 238)
$themeList.ForeColor = [Drawing.Color]::FromArgb(48, 68, 53)
$themeList.Font = New-Object Drawing.Font($form.Font.FontFamily, 10, [Drawing.FontStyle]::Bold)
$themeList.TileSize = New-Object Drawing.Size(230, 155)

$footer = New-Object Windows.Forms.Panel
$footer.Dock = [Windows.Forms.DockStyle]::Bottom
$footer.Height = 182
$footer.BackColor = [Drawing.Color]::FromArgb(250, 249, 245)

$messageLabel = New-Object Windows.Forms.Label
$messageLabel.Text = $strings.loading
$messageLabel.AutoEllipsis = $true
$messageLabel.ForeColor = [Drawing.Color]::FromArgb(91, 105, 93)
$messageLabel.SetBounds(22, 12, 840, 24)
$messageLabel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right

$applyButton = New-Object Windows.Forms.Button
$applyButton.Text = $strings.chooseTheme
$applyButton.SetBounds(20, 50, 235, 38)
$applyButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$applyButton.FlatAppearance.BorderSize = 0
$applyButton.BackColor = [Drawing.Color]::FromArgb(65, 94, 70)
$applyButton.ForeColor = [Drawing.Color]::White

$openDoubaoButton = New-Object Windows.Forms.Button
$openDoubaoButton.Text = $strings.openDoubao
$openDoubaoButton.SetBounds(267, 50, 110, 38)

$disableButton = New-Object Windows.Forms.Button
$disableButton.Text = $strings.disable
$disableButton.SetBounds(389, 50, 130, 38)

$conversationOpacityLabel = New-Object Windows.Forms.Label
$conversationOpacityLabel.Text = $strings.conversationOpacity
$conversationOpacityLabel.ForeColor = [Drawing.Color]::FromArgb(66, 85, 69)
$conversationOpacityLabel.SetBounds(22, 101, 122, 24)

$conversationOpacitySlider = New-Object Windows.Forms.TrackBar
$conversationOpacitySlider.Minimum = 0
$conversationOpacitySlider.Maximum = 100
$conversationOpacitySlider.TickFrequency = 10
$conversationOpacitySlider.SmallChange = 1
$conversationOpacitySlider.LargeChange = 10
$conversationOpacitySlider.Value = 66
$conversationOpacitySlider.Enabled = $false
$conversationOpacitySlider.SetBounds(145, 91, 620, 44)
$conversationOpacitySlider.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right

$conversationOpacityValue = New-Object Windows.Forms.Label
$conversationOpacityValue.Text = "66%"
$conversationOpacityValue.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$conversationOpacityValue.ForeColor = [Drawing.Color]::FromArgb(66, 85, 69)
$conversationOpacityValue.SetBounds(776, 101, 70, 24)
$conversationOpacityValue.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right

$copyrightLabel = New-Object Windows.Forms.Label
$copyrightLabel.Text = $strings.copyrightNotice
$copyrightLabel.ForeColor = [Drawing.Color]::FromArgb(112, 120, 111)
$copyrightLabel.AutoEllipsis = $true
$copyrightLabel.SetBounds(22, 148, 690, 22)
$copyrightLabel.Anchor = [Windows.Forms.AnchorStyles]::Bottom -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right

$projectLink = New-Object Windows.Forms.LinkLabel
$projectLink.Text = $strings.viewProject
$projectLink.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$projectLink.SetBounds(750, 148, 120, 22)
$projectLink.Anchor = [Windows.Forms.AnchorStyles]::Bottom -bor [Windows.Forms.AnchorStyles]::Right
$projectLink.Add_LinkClicked({
    Start-Process -FilePath $projectUrl | Out-Null
})

$footer.Controls.AddRange(@(
    $messageLabel,
    $applyButton,
    $openDoubaoButton,
    $disableButton,
    $conversationOpacityLabel,
    $conversationOpacitySlider,
    $conversationOpacityValue,
    $copyrightLabel,
    $projectLink))
$form.Controls.Add($themeList)
$form.Controls.Add($footer)
$form.Controls.Add($toolbar)
$form.Controls.Add($header)

$trayMenu = New-Object Windows.Forms.ContextMenuStrip
$trayOpen = $trayMenu.Items.Add($strings.trayOpen)
$trayOpenDoubao = $trayMenu.Items.Add($strings.openDoubao)
$trayDisable = $trayMenu.Items.Add($strings.trayDisable)
[void]$trayMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$trayExit = $trayMenu.Items.Add($strings.trayExit)

$trayIcon = New-Object Windows.Forms.NotifyIcon
$trayIcon.Icon = $appIcon
$trayIcon.Text = "Doubao Skin"
$trayIcon.ContextMenuStrip = $trayMenu
$trayIcon.Visible = $true

$operationTimer = New-Object Windows.Forms.Timer
$operationTimer.Interval = 250
$operationTimer.Add_Tick({ Complete-BackendOperation })

$opacityTimer = New-Object Windows.Forms.Timer
$opacityTimer.Interval = 450
$opacityTimer.Add_Tick({
    $opacityTimer.Stop()
    if ($script:updatingOpacity -or
        $null -ne $script:operation -or
        $null -eq $script:status -or
        -not [bool]$script:status.enabled) {
        return
    }
    $opacity = ([double]$conversationOpacitySlider.Value / 100).ToString(
        "0.00",
        [Globalization.CultureInfo]::InvariantCulture)
    [void](Start-BackendOperation `
        -Arguments @("set-conversation-opacity", "-ConversationOpacity", $opacity) `
        -Progress $strings.conversationOpacityChanging `
        -Reload $true)
})
$conversationOpacitySlider.Add_ValueChanged({
    $conversationOpacityValue.Text = "$($conversationOpacitySlider.Value)%"
    if (-not $script:updatingOpacity -and
        $null -eq $script:operation -and
        $null -ne $script:status -and
        [bool]$script:status.enabled) {
        $opacityTimer.Stop()
        $opacityTimer.Start()
    }
})

$refreshButton.Add_Click({
    if ($null -eq $script:operation) {
        Set-Busy -Value $true
        $messageLabel.Text = $strings.loading
        Refresh-Data -PreferActive $false
    }
})
$openLibraryButton.Add_Click({
    [void](Start-BackendOperation -Arguments @("reveal-themes") -Progress $strings.openingLibrary -Reload $false)
})
$startupCheckBox.Add_CheckedChanged({
    if ($script:updatingStartup -or $null -ne $script:operation -or $null -eq $script:status) {
        return
    }
    $enabled = [bool]$startupCheckBox.Checked
    $command = if ($enabled) { "enable-startup" } else { "disable-startup" }
    $progress = if ($enabled) { $strings.startupEnabling } else { $strings.startupDisabling }
    if (-not (Start-BackendOperation -Arguments @($command) -Progress $progress -Reload $true)) {
        Update-Status
    }
})
$openDoubaoButton.Add_Click({
    [void](Start-BackendOperation -Arguments @("open") -Progress $strings.openingDoubao -Reload $true)
})
$applyButton.Add_Click({
    if ($null -eq $script:selectedTheme) {
        $messageLabel.Text = $strings.chooseTheme
        return
    }
    $progress = Format-Ui -Template $strings.applying -Values @([string]$script:selectedTheme.name)
    [void](Start-BackendOperation `
        -Arguments @("activate-library", "-ThemeDir", [string]$script:selectedTheme.directory) `
        -Progress $progress `
        -Reload $true `
        -FailureTitle $strings.applyFailed)
})
$disableButton.Add_Click({
    if ($null -eq $script:status -or -not [bool]$script:status.enabled) { return }
    $answer = [Windows.Forms.MessageBox]::Show(
        $form,
        $strings.disableConfirm,
        $strings.disableTitle,
        [Windows.Forms.MessageBoxButtons]::OKCancel,
        [Windows.Forms.MessageBoxIcon]::Information)
    if ($answer -eq [Windows.Forms.DialogResult]::OK) {
        [void](Start-BackendOperation `
            -Arguments @("disable") `
            -Progress $strings.disabling `
            -Reload $true `
            -FailureTitle $strings.disableFailed)
    }
})
$themeList.Add_SelectedIndexChanged({
    if ($themeList.SelectedItems.Count -eq 0 -or $null -eq $script:library) { return }
    $directory = [string]$themeList.SelectedItems[0].Tag
    $script:selectedTheme = @($script:library.themes) | Where-Object {
        Test-SamePath -Left ([string]$_.directory) -Right $directory
    } | Select-Object -First 1
    if ($null -ne $script:selectedTheme) {
        $messageLabel.Text = Format-Ui -Template $strings.selected -Values @([string]$script:selectedTheme.name)
    }
    Update-ApplyButton
})

function Show-ManagerWindow {
    $form.Opacity = 1
    $form.ShowInTaskbar = $true
    $form.Show()
    if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = [Windows.Forms.FormWindowState]::Normal
    }
    $form.Activate()
}

$trayOpen.Add_Click({ Show-ManagerWindow })
$trayIcon.Add_DoubleClick({ Show-ManagerWindow })
$trayOpenDoubao.Add_Click({
    [void](Start-BackendOperation -Arguments @("open") -Progress $strings.openingDoubao -Reload $true)
})
$trayDisable.Add_Click({
    if ($null -ne $script:status -and [bool]$script:status.enabled) {
        [void](Start-BackendOperation `
            -Arguments @("disable") `
            -Progress $strings.disabling `
            -Reload $true `
            -FailureTitle $strings.disableFailed)
    }
})
$trayExit.Add_Click({
    $script:exiting = $true
    $trayIcon.Visible = $false
    $form.Close()
    [Windows.Forms.Application]::Exit()
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $script:exiting -and
        $eventArgs.CloseReason -ne [Windows.Forms.CloseReason]::WindowsShutDown) {
        $eventArgs.Cancel = $true
        $form.Hide()
        $form.ShowInTaskbar = $false
        if (-not $script:balloonShown) {
            $trayIcon.BalloonTipTitle = $strings.trayStillRunningTitle
            $trayIcon.BalloonTipText = $strings.trayStillRunningText
            $trayIcon.ShowBalloonTip(2500)
            $script:balloonShown = $true
        }
    }
})

$form.Add_Shown({
    Set-Busy -Value $true
    try {
        Invoke-BackendSync -Arguments @("ensure-supervisor") | Out-Null
    } catch {}
    Refresh-Data -PreferActive $true
    if ($Background) {
        $form.Hide()
        $form.ShowInTaskbar = $false
    }
    $operationTimer.Start()
})

try {
    [Windows.Forms.Application]::Run($form)
} finally {
    $operationTimer.Stop()
    $opacityTimer.Stop()
    if ($null -ne $themeList.LargeImageList) {
        $themeList.LargeImageList.Dispose()
    }
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    $form.Dispose()
    $appIcon.Dispose()
}
