# Doubao Skin for Windows

Copyright © 2026 陆思源Cyan. This project is distributed under
`AGPL-3.0-only` without warranty. Redistribution or sale must retain the
copyright and license notices and provide the complete corresponding source;
see the repository root `LICENSE`.

The Windows build reuses the repository's theme schema, renderer injection,
CSS, presets, and Node.js CDP controller. It does not unpack, patch, replace,
or re-sign the official Doubao installation.

## Verified environment

- Windows 11 x64, build `10.0.26200`
- Official per-user Doubao launcher `2.19.9`
- Chromium `135.0.7049.72`
- Official executable locations:
  `%LOCALAPPDATA%\Doubao\Application\Doubao.exe` and
  `%LOCALAPPDATA%\Doubao\Application\app\Doubao.exe`

The exact publisher, product names, signer organization, certificate
thumbprint, paths, and observed versions are recorded in
`assets/windows-app-identity.json`. A future agent must update that contract
only after inspecting a newly signed official release on a real Windows
machine.

## Install the packaged ZIP

Extract the complete ZIP and double-click:

```text
Install Doubao Skin.cmd
```

If script launching is restricted, open Windows PowerShell in the extracted
folder and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\Install Doubao Skin.ps1"
```

The package installer copies the verified runtime to
`%LOCALAPPDATA%\Programs\Doubao Skin`, creates desktop and Start menu
shortcuts with the Doubao Skin icon, and opens the tray manager. The manager
window and notification-area item use the same icon. Keep the whole extracted folder
together until installation finishes.

## Build and install from source

Run in Windows PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\build-windows-app.ps1
.\scripts\install-windows-app.ps1
```

The build downloads the official Node.js `v24.16.0` Windows x64 archive from
`nodejs.org`, verifies its pinned SHA-256 hash, and bundles only `node.exe`.
The default manager uses the Microsoft-signed Windows PowerShell host, matching
the compatibility approach used by Codex Dream Skin on Windows. This matters
on Windows 11 systems where Smart App Control blocks newly compiled unsigned
executables. The repository also contains an optional C# host for releases
that will be Authenticode-signed by a certificate authority in Microsoft's
Trusted Root Program:

```powershell
.\scripts\build-windows-app.ps1 -CompileNativeManager
```

Do not ship that optional executable unsigned. The normal build does not
include it and does not ask users to weaken Smart App Control.

The installed manager lives at:

```text
%LOCALAPPDATA%\Programs\Doubao Skin\
```

Themes, state, configuration, and local logs live at:

```text
%LOCALAPPDATA%\DoubaoSkin\
```

The fixed theme library is `%LOCALAPPDATA%\DoubaoSkin\themes`. Paste a complete
theme folder containing `theme.json` and its declared image directly into that
folder, then click **Refresh** in the manager. There is deliberately no second
custom theme location. The versioned bundled catalog seeds all 32 boy/girl
MBTI themes plus the `cyan-sunny` warm-study theme once, including
`mbti-boy-infp` as the default. Later refreshes are
read-only with respect to theme folders, so a theme deleted by the user stays
deleted. Theme IDs must be unique; renamed copies that retain the same
`theme.json` ID are reported as invalid. The retired `infp-garden` ID is kept
off the visible list during upgrades.

## Runtime behavior

- While the PowerShell-hosted manager window is open, it owns a normal taskbar
  button with the Doubao Skin icon. Closing the window hides that button and
  leaves the manager in the Windows system tray.
- Only **Exit Manager** in the tray menu ends the manager process.
- The **Start automatically at login** checkbox persists in `config.json`.
  When selected, the current user's `Run` value launches the installed manager
  without `-Background`, so its window and taskbar button are visible after
  login. Clearing the checkbox removes the value without stopping the current
  manager or skin session.
- The **Conversation transparency** slider shows `0%` as fully masked and
  `100%` as fully transparent, with a `40%` built-in default. The manager
  persists its inverse as `conversationOpacity` in `config.json` and replaces
  only the alpha of the selected theme's `surfaces.conversation` color; it
  does not tint the home view, menus, or composer.
- Disabling and restoring the official appearance also clears the login-start
  preference and removes the startup value.
- A separate signed-PowerShell event supervisor blocks on WMI process-start
  events. Only an official
  Doubao main process owned by the interactive user, lacking both a helper
  `--type` and CDP arguments, is considered a normal user launch.
- The exact observed PID is passed to the backend and revalidated after the
  debounce before the manager replaces it once with a verified `127.0.0.1`
  CDP launch.
- There is no unconditional periodic relaunch check. Renderer/helper churn and
  quitting Doubao do not schedule supervision, so an explicit quit stays
  closed.
- A bundled Node watcher reapplies the theme after renderer reloads.

The manager and PowerShell backend verify the official uninstall registration,
file metadata, Authenticode certificate, process owner, executable path,
listener address, listener owner, Chromium endpoint, and Doubao renderer URL.
The renderer-injected JavaScript performs no network requests.

## CLI

```powershell
.\scripts\manage-doubao-skin-windows.ps1 list-themes
.\scripts\manage-doubao-skin-windows.ps1 enable-default
.\scripts\manage-doubao-skin-windows.ps1 activate-library `
  -ThemeDir "$env:LOCALAPPDATA\DoubaoSkin\themes\mbti-boy-infp"
.\scripts\manage-doubao-skin-windows.ps1 status
.\scripts\manage-doubao-skin-windows.ps1 verify
.\scripts\manage-doubao-skin-windows.ps1 enable-startup
.\scripts\manage-doubao-skin-windows.ps1 disable-startup
.\scripts\manage-doubao-skin-windows.ps1 disable
```

The normal user workflow does not require these commands: open **Doubao Skin**
from the desktop or Start menu, select a background thumbnail, and click the
apply button. Close the window with **X** to keep it in the tray. Use
the checkbox to control login startup; Windows may place the tray icon under
the taskbar's `^` overflow. Use **Disable and restore** to remove persistence
while keeping theme folders.

Before publishing a Windows package, run
`tests\windows-lifecycle-regression.ps1` from an interactive logged-in Windows
desktop after the build. It performs the real **enable → disable → re-enable →
verify** sequence and fails unless Doubao, the watcher, and the event
supervisor all remain active.

Task Scheduler and other interactive desktop launchers can call
`tests\run-windows-lifecycle-regression.cmd`; it writes console output to
`dist\windows-lifecycle-task.log`.

After installation, call
`tests\run-installed-windows-lifecycle-regression.cmd` to repeat the same
regression against `%LOCALAPPDATA%\Programs\Doubao Skin`.
