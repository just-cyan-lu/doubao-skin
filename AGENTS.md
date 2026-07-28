# Repository instructions for AI agents

This repository builds a reversible macOS and Windows skin for the official
Doubao desktop app. Read `docs/THEME-AUTHORING.md` before changing a theme.

## Non-negotiable boundaries

- Work on the current branch unless the user explicitly asks for a new branch.
- Never modify, unpack, patch, replace, or re-sign either official Doubao app.
- CDP must stay bound to `127.0.0.1`, and every target must pass the URL,
  process-owner, executable-path, and platform identity/signing checks already
  implemented here.
- Do not add network requests to renderer-injected code.
- Do not expose screenshots containing account names, chat titles, or messages.
- Preserve the one-click restore path.

## Theme architecture

The source of truth for a theme is one folder containing `theme.json` and the
background file named by its `background` field. Repository presets use
`presets/<preset-id>/`.

1. `scripts/injector.mjs` validates and loads the preset.
2. `assets/renderer-inject.js` converts theme values into
   `--doubao-skin-*` CSS custom properties.
3. `assets/doubao-skin.css` maps those semantic properties to Doubao UI
   regions and native token families.
4. `assets/selectors.json` records stable DOM anchors and the Doubao version
   against which they were verified.
5. `scripts/theme-package.mjs` validates, lists, and atomically copies
   end-user theme folders into the platform application-data directory.
6. `scripts/supervisor-macos.sh` waits for user-initiated Doubao launches and
   restores CDP skin mode; it must stay idle after an explicit quit.
7. `scripts/supervisor-windows.ps1` owns the blocking Windows WMI
   process-start event loop. It may schedule `supervise-once` only for a
   verified normal Doubao main-process start, passing that exact PID as
   `-ObservedProcessId`. `windows/DoubaoSkinTray.ps1` only ensures that this
   signed-PowerShell-hosted supervisor is running and requests one immediate
   `supervise-once` reconciliation for an already-running verified instance.
   The immediate reconciliation restores the renderer watcher after an
   in-place manager upgrade; it is not a timer. Do not move WMI delivery back
   into the WinForms message loop or restore periodic unconditional
   supervision.
8. `assets/windows-app-identity.json` records the real Windows installation,
   publisher, products, signer, and observed versions. Update it only after
   inspecting a newly signed official build on a real Windows machine.

Both GUI managers are thin clients. Do not put theme-specific colors or
selectors in `macos/DoubaoSkinApp.swift` or `windows/DoubaoSkinTray.ps1`;
every visual decision belongs in the JSON/CSS contract so another AI agent can
reproduce a skin from this repository alone.
The manager brand icon has one raster master at `assets/app-icon.png`.
`assets/DoubaoSkin.icns` and `assets/DoubaoSkin.ico` are derived release
artifacts; after changing the master, run `npm run build:icons`, inspect the
master at both full size and 32 px, and keep all three files in sync. The
macOS bundle, Windows window/tray icon, optional signed native host, and
Windows shortcuts must use those derived files instead of generic system
icons.
The Swift manager owns a `MenuBarExtra`, and the Windows manager owns a
`NotifyIcon`. While the macOS manager window is visible, the app must use the
regular activation policy and show its icon in the Dock. Closing that window
must switch back to accessory mode and leave only the menu-bar item. Closing
either platform window must leave the manager alive. Only the explicit menu
command may quit it.
Both interactive managers must keep a visible appropriate legal notice:
`© 2026 陆思源Cyan`, `AGPL-3.0-only`, no-warranty wording, and the reminder
that redistribution or sale must retain copyright and provide corresponding
source. They must link to the canonical public repository at
`https://github.com/just-cyan-lu/doubao-skin`; do not use a local-file
`LICENSE` link in the manager window. Do not remove or obscure this notice.
Release runtimes and both installer formats must include the unmodified root
`LICENSE`; the macOS bundle must also carry the Swift source needed to rebuild
its manager.
Windows tray operations invoke the backend in a separate PowerShell process.
Named parameters such as `-ThemeDir` must remain syntactic parameter tokens;
quoting them turns them into positional strings and breaks re-enabling from
the GUI. The backend publishes the result through the atomic
`-OperationResultPath` JSON contract. Do not restore parent-side
`RedirectStandardOutput` or `RedirectStandardError`: Doubao, the watcher, or
the event supervisor may inherit those handles and leave the manager stuck in
its busy state after a successful operation.
The user workflow has one fixed library per platform:

- macOS: `~/Library/Application Support/DoubaoSkin/themes/`
- Windows: `%LOCALAPPDATA%\DoubaoSkin\themes\`

Users paste complete theme folders there, refresh, and choose a validated
background thumbnail. Do not restore an arbitrary-folder picker or a second
custom theme location. Keep the CLI import command for developer compatibility.

`presets/bundled-themes.json` is the authoritative built-in catalog. Every
listed ID must match both its direct-child preset directory and the `id` in
that directory's `theme.json`. Platform managers may seed missing catalog
themes only when the matching `bundled-theme-library-v<revision>` marker is
absent. Refresh must be read-only after that marker exists, so a theme deleted
by the user stays deleted. Seeding must preserve an existing valid theme of the
same ID instead of overwriting user changes. When the catalog changes, increase
both the manifest revision and the platform marker version. Retired IDs may be
hidden from the library list for upgrade compatibility, but never silently
delete an active user's theme folder.

Library themes must be ordinary direct-child directories. Scan them with
`theme-package.mjs list`, omit invalid entries, and re-run `inspect` immediately
before activation. The Swift manager may display only the validated local
`backgroundPath`; it must not infer an unvalidated thumbnail path.
The same rule applies to the Windows thumbnail list. On Windows, reject
reparse points as well as symbolic links.

The default Windows package is hosted by Microsoft-signed Windows PowerShell.
Do not make the optional locally compiled `Doubao Skin.exe` the default or
tell users to weaken Smart App Control. It may be distributed only after
formal Authenticode signing by an appropriate trusted certificate.

Do not hard-code preset colors in JavaScript or scatter them through selector
rules. Add a semantic theme token, validate it, install and clean up its root
property, then consume it in CSS. Preset-specific layout rules may use
`[data-doubao-skin-theme="<theme-id>"]`.

Use `surfaces.conversation` for the conversation-route readability scrim and
`surfaces.menu` for portaled menu/dialog surfaces. Opacity terminology is
normative: `1.00` means 100% opaque, so alpha `0.90` means 90% opacity and 10%
transparency.
The theme alpha is the initial conversation default. Both managers display a
transparency slider where `0%` is fully masked, `100%` is fully transparent,
and the built-in default is `40%`. They convert it with
`conversationOpacity = 1 - conversationTransparency` before persisting the
internal `conversationOpacity` override from `0.00` to `1.00`; that override may
replace only the alpha of `surfaces.conversation`, must preserve that token's
RGB, and must be forwarded consistently to once/watch/verify injection. It
must not change the home view, menu, composer, or add a backdrop blur.

## Required workflow

When adding or changing a theme:

1. Start from `presets/_template/theme.json`.
2. Keep the file compatible with `assets/theme.schema.json`.
3. After changing `composer.toolbar`, run
   `npm run icon-filter -- '#RRGGBB'` and copy the filter into
   `composer.iconFilter`.
4. Keep backgrounds local, under 16 MB, and in PNG, JPEG, or WebP format.
5. Use `background-size: cover` for the app shell; test both wide and tall
   windows so no unskinned strip appears.
6. Prefer stable `data-testid` selectors. Add new anchors to
   `assets/selectors.json` with `required: false` until they are proven
   essential across views.
   Composer and portaled popovers can contain a native opaque child surface:
   inspect both the stable outer anchor and its immediate visual layers instead
   of assuming the outer background is visible.
7. If a new semantic token is needed, update all of:
   - `assets/theme.schema.json`
   - `scripts/injector.mjs` validation
   - `assets/renderer-inject.js` root-property install and cleanup
   - `assets/doubao-skin.css`
   - `presets/_template/theme.json`
   - tests and `docs/THEME-AUTHORING.md`
8. Run:

   ```bash
   npm test
   npm run check:infp
   DOUBAO_SKIN_SMOKE_PRESET=<preset-id> npm run smoke
   npm run build:app
   ```

   Replace `check:infp` with
   `node scripts/injector.mjs --check --preset <preset-id>` for another preset.
   On Windows also parse every `.ps1`, run
   `.\scripts\build-windows-app.ps1`, and keep the pinned Node.js archive hash.

9. With user authorization, apply the preset to the installed app and run:

   ```bash
   ./scripts/start-doubao-skin-macos.sh --restart-existing --preset <preset-id>
   ./scripts/verify-doubao-skin-macos.sh
   ```

   Or on Windows:

   ```powershell
   .\scripts\manage-doubao-skin-windows.ps1 activate-library `
     -ThemeDir "$env:LOCALAPPDATA\DoubaoSkin\themes\<theme-id>"
   .\scripts\verify-doubao-skin-windows.ps1
   ```

10. Visually inspect the home view, sidebar, composer, one conversation view,
    and one menu or dialog. Do not type or send content merely for QA.
11. For persistence changes, quit Doubao, launch it normally without CDP
    arguments, confirm the supervisor restarts it into skin mode, and then
    quit it again to confirm it stays closed. On Windows also confirm helper
    and renderer process starts do not schedule supervision and the observed
    normal PID is revalidated after the debounce.

## Definition of done

- Static tests and the real-renderer smoke test pass.
- Runtime verification reports no missing required markers.
- Runtime typography audit reports `nativeBlackTextCount: 0`.
- Runtime composer audit reports `nativeBlackVectorPaintCount: 0` and
  `untintedRasterIconCount: 0`; `nativeInnerSurface.transparent` is `true` so
  the preset-controlled outer gradient is visible.
- At a normal desktop width, runtime composer audit reports
  `actionButtons.count > 0`; responsive or headless layouts may hide the row
  and report `0`. In every layout, `actionButtons.unexpectedFilledCount` is
  `0`: ordinary `button[data-testid^="skill_bar_button_"]` actions must be
  transparent at rest and may receive only restrained hover/highlight
  feedback. Do not apply this reset to the mode selector or voice button.
- With the mode menu open, runtime audit reports
  `modeMenu.nativeBlackVectorPaintCount: 0` and
  `modeMenu.untintedRasterIconCount: 0`.
- With the More menu open, runtime audit reports
  `moreMenu.unexpectedFilledItemCount: 0`,
  `moreMenu.nativeBlackVectorPaintCount: 0`, and
  `moreMenu.untintedRasterIconCount: 0`. Keep the popover shell continuous and
  item surfaces transparent except for hover/highlight feedback. If the shell
  and item layers cannot be anchored safely after a Doubao update, leave this
  popover on its native colors instead of applying a partial tint.
- On a conversation route, runtime audit reports
  `conversation.surfaceBackgroundColor === conversation.scrimToken`,
  `conversation.backdropFilter === "none"`, both the message list and bottom
  fade are present, and the bottom fade no longer uses Doubao's opaque
  `rgb(252, 252, 252)` white.
- Both manager sliders display transparency (`0%` fully masked, `100%` fully
  transparent, default `40%`) and persist its inverse as
  `conversationOpacity`; changing it live updates only the conversation
  readability scrim, survives theme switches and relaunches, and preserves
  the selected theme's scrim RGB.
- The manager remains running in the macOS menu bar or Windows system tray
  after its window is closed and can reopen that window from its status menu.
  On macOS its Dock icon is present while the manager window is open and is
  removed after that window closes.
- Both manager windows visibly identify `陆思源Cyan`, state
  `AGPL-3.0-only` and no warranty, summarize the source-sharing requirement,
  and link to `https://github.com/just-cyan-lu/doubao-skin`. The complete
  `LICENSE` remains bundled with each release.
- The macOS app bundle and Windows manager window, tray icon, and shortcuts
  display the project icon rather than a generic system application icon.
- The manager has no arbitrary-folder picker. Opening the fixed theme library,
  refreshing it, selecting a validated background thumbnail, and switching to
  that theme all work; invalid and symlink entries are not selectable.
- Background layers use `cover`.
- Typography, composer colors, panels, and decoration are sourced from the
  preset instead of accidental Doubao defaults.
- Removing the skin still restores the official appearance.
- The installed LaunchAgent points to
  `~/Library/Application Support/DoubaoSkin/runtime`, never to a checkout.
- The Windows `Run` value points to the installed PowerShell tray under
  `%LOCALAPPDATA%\Programs\Doubao Skin`, never to a checkout or unsigned
  development executable. It must mirror the persisted `startAtLogin`
  preference and omit `-Background`, so login startup shows the manager in the
  taskbar. Turning the preference off removes the value without ending the
  current session.
- Windows CDP recovery is event-driven: no periodic call may relaunch Doubao
  after the user quits, and `supervise-once -ObservedProcessId` must revalidate
  path, owner, signature, main-process role, and absence of CDP arguments.
- The default Windows ZIP contains root-level `Install Doubao Skin.cmd`,
  `Install Doubao Skin.ps1`, `README-zh-CN.txt`, and `LICENSE`, contains no
  unsigned native manager, and contains no `.DS_Store`, AppleDouble `._*`, or
  `__MACOSX` metadata.
- The macOS DMG contains the ad-hoc-signed app, an Applications symlink, and
  usage instructions plus `LICENSE`. Its app resources contain the
  corresponding Swift source. Do not describe it as Developer ID signed or
  notarized unless those checks were actually completed with the user's
  credentials.
- A user-initiated normal launch is recovered, while a user-initiated quit does
  not cause an unwanted relaunch.
- Documentation and the template reflect any schema or workflow change.
