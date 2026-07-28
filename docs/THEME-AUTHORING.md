# Doubao Skin theme authoring

This document is the reproducible procedure for humans and AI agents creating
or modifying a skin. The repository intentionally separates visual choices
from injection mechanics.

## 1. Files and data flow

```text
theme folder/theme.json
        │ validated by scripts/injector.mjs
        ▼
assets/renderer-inject.js
        │ installs --doubao-skin-* properties
        ▼
assets/doubao-skin.css
        │ maps semantic values to Doubao tokens and stable selectors
        ▼
official Doubao renderer over loopback CDP
```

The default Aurora theme lives at `assets/theme.json`. Reusable presets live
under `presets/`. Start new work by copying `presets/_template/theme.json`.
`presets/bundled-themes.json` is the explicit release catalog installed into a
user's theme library once per catalog revision. Version 2 contains the 32
`mbti-<gender>-<type>` themes plus `cyan-sunny`, and defaults to
`mbti-boy-infp`.
The platform managers scan one fixed library:

```text
macOS:   ~/Library/Application Support/DoubaoSkin/themes/
Windows: %LOCALAPPDATA%\DoubaoSkin\themes\
```

End users paste one complete theme folder directly into that directory, click
Refresh, select its local background thumbnail, and switch themes. Both
managers list only validated direct-child folders and invoke the injector with
`--theme-dir`; no visual token or arbitrary source path is stored in Swift or
PowerShell UI code. The CLI import path remains available for developers and
atomically publishes a validated theme into the same platform library.

## 2. Theme schema

`assets/theme.schema.json` is the machine-readable contract. Every theme has:

- `schemaVersion`: currently `1`
- `id`: letters, numbers, and hyphens; must match the preset identity
- `name`: display name
- `background`: optional local filename in the same preset directory
- `colors`: brand, panel, and border colors
- `typography`: semantic colors for the rest of the application
- `composer`: input-area colors
- `surfaces`: conversation readability and portaled menu surfaces
- `decoration`: optional non-interactive home-view copy

Supported color syntax is six-digit hex or `rgb()` / `rgba()`.

### `colors`

| Token | Purpose |
| --- | --- |
| `accent` | focus, hover, caret, and active emphasis |
| `accentSoft` | soft emphasis and selection |
| `cyan`, `pink` | optional decorative accents |
| `text`, `muted` | legacy fallbacks when a semantic palette is absent |
| `panel`, `panelStrong` | translucent cards and surfaces |
| `line` | generic dividers and borders |

### `surfaces`

| Token | Purpose |
| --- | --- |
| `conversation` | full main-area scrim used only when a message list is present |
| `menu` | high-contrast background shared by menus and dialogs |

Opacity terminology in this repository always treats `100%` as fully opaque.
Therefore CSS alpha `0.90` means **90% opacity / 10% transparency**. Do not call
alpha `0.90` “90% transparent.”

### `typography`

| Token | UI regions |
| --- | --- |
| `primary` | normal application and conversation text |
| `secondary` | supporting text |
| `muted` | captions and tertiary information |
| `subtle` | quaternary labels |
| `disabled` | disabled controls |
| `heading` | page title, greeting, conversation title |
| `sidebar` | sidebar actions and conversation rows |
| `sidebarMuted` | sidebar placeholder and secondary labels |
| `suggestion` | onboarding suggestion cards |
| `action` | skill and action buttons |
| `link` | links and linked text |

The CSS bridge maps these values into Doubao's current `s-color`, DBX, Semi,
Markdown, link, and message-bubble token families. Keep that bridge centralized
in the first `:root[data-doubao-skin="active"]` rule.

### `composer`

| Token | Purpose |
| --- | --- |
| `text` | entered text |
| `placeholder` | empty-input hint |
| `toolbar` | composer labels and icons |
| `iconFilter` | recolors Doubao's monochrome PNG skill icons to `toolbar` |
| `background`, `backgroundAccent` | translucent gradient endpoints |
| `border` | composer outline and shadow tint |

`toolbar` is enough for text and SVG icons, but Doubao 2.19.9 also ships some
skill-bar icons as black PNG images. After choosing `toolbar`, generate the
matching safe CSS filter and copy the first output line into `iconFilter`:

```bash
npm run icon-filter -- '#405943'
```

The generated filter first normalizes a monochrome source to black and then
maps it to the requested color. The CSS applies it only to `aria-hidden` images
inside `skill_bar_button_*` and the current image below
`[data-valid-btn="mode-select-action-btn"]`; never broaden the styling selector
to avatars, stickers, or other multicolor artwork.

The opened mode menu contains separate copies of the same PNGs. Its four 16px
mode glyphs use the same filter through a menu-specific `:has()` selector. The
10px blue upgrade badge is intentionally excluded because it is not a
monochrome toolbar glyph.

For an artwork-backed light theme, start the composer at a neutral white alpha
near `0.58` (58% opacity). Use the same value for `background` and
`backgroundAccent` when a uniform glass surface is wanted; use different
values only for an intentional gradient. The shared CSS uses an 18px blur and
restrained saturation on the composer itself, so artwork remains visible
through neutral frosted glass without painting the whole input area in the
theme accent color.
This follows the same panel-token principle used by
[Codex Dream Skin](https://github.com/Fei-Away/Codex-Dream-Skin/blob/main/macos/assets/dream-skin.css):
theme panel colors drive native translucent surfaces instead of painting an
unrelated opaque white box.

Doubao 2.19.9 places a separate opaque native child surface inside
`[data-testid="chat_input"]`. The shared CSS deliberately makes that child
transparent and assigns the glass surface, border, blur, and focus state to the
stable outer composer anchor. When adapting a future Doubao version, verify
both computed layers: changing only the outer node can appear to do nothing
when an inner white layer still covers it.

Conversation text requires a separate readability layer. The shared CSS uses
`main:has([data-testid="message-list"])` so `surfaces.conversation` covers the
entire main area only on real conversation routes; the home artwork remains
unmasked. Start around alpha `0.66`. The conversation surface must use
`backdrop-filter: none`: it may soften the artwork through opacity, but must
not blur the message content or wallpaper. Doubao also adds a white bottom fade with
the semantic class fragment `from-s-color-bg-body`; the skin rebuilds that fade
from the same conversation token so it cannot become a detached white strip.
Menus use `surfaces.menu`; start around alpha `0.94` for readable labels.

## 3. Create a theme package

1. Copy `presets/_template` to `presets/<id>`.
2. Change `id`, `name`, copy, and all palette values.
3. Regenerate `composer.iconFilter` from the final `composer.toolbar` color.
4. If using artwork, add `background.png`, `.jpg`, or `.webp` and set
   `"background": "background.png"`. The file must be non-empty and at most
   16 MB.
5. Compose artwork with the focal subject away from the central chat controls.
   The shell must still use `background-size: cover`; use
   `background-position` in a theme-scoped CSS rule to preserve the subject.
6. Add a one-click `.command` file only when the preset is meant for end users.

The end-user package is exactly `theme.json` plus the image named by
`background`. `scripts/theme-package.mjs` opens both without following symbolic
links, checks containment, size and image signatures, and validates the
complete payload. Its `list` command safely scans only direct children of the
theme library; its `install` command publishes a validated pair atomically.
Each platform manager must revalidate the selected library folder immediately
before activation and render thumbnails only from validated local
`backgroundPath` values. Invalid folders are omitted, never partially loaded.
AI agents must preserve this library contract rather than teaching users to
edit the installed runtime or configure a second custom theme location.
Windows reparse points and symbolic links are invalid even when their resolved
target appears to stay inside the library.

The platform managers invoke `theme-package.mjs seed` only when the matching
`bundled-theme-library-v<revision>` marker is absent. Seeding installs missing
catalog entries without overwriting an existing valid theme of the same ID,
then the marker makes later Refresh operations read-only. Therefore users may
delete unwanted bundled themes without having them reappear. When the bundled
catalog changes, increment both the manifest revision and the platform marker;
do not reuse a revision to force deleted themes back into a library.

Validate a standalone package with:

```bash
node scripts/injector.mjs --check --theme-dir "/path/to/theme-folder"
```

## 4. Import the matching Codex MBTI collection

When the sibling MBTI Codex project is available, its 32 boy/girl presets can
be converted into ordinary Doubao theme packages with:

```bash
node scripts/import-mbti-presets.mjs \
  --source "/absolute/path/to/mbtiskin/presets"
```

The importer preserves every 2560 × 1440 JPEG and source palette, derives the
complete Doubao typography, composer, panel, conversation, and menu tokens,
and regenerates each monochrome icon filter. Every output uses
`presets/mbti-<gender>-<type>/`. The boy INFP output retains its manually tuned
Doubao tokens while using the same `mbti-boy-infp` ID and
`INFP · 调停者男孩` display-name convention as the other 31 themes.

Early builds exposed that artwork as `infp-garden`. The library scanner keeps
that retired ID on disk for active upgrade compatibility but omits it from the
manager after `mbti-boy-infp` is available. Do not reuse `infp-garden` for a
new theme.

The imported folders are standard end-user packages containing only
`theme.json` and `background.jpg`. Validate them exactly like a hand-authored
theme; the importer is a reproducible migration helper, not an alternative
theme format.

The warm study artwork imported from
`cyanskin/lu-siyuan-codex-skin/preset-lu-siyuan` uses the concise Doubao
identity `cyan-sunny`. Its package uses a complete warm-brown
semantic palette, a neutral 58%-opaque composer, 66%-opaque conversation
surface, 95%-opaque menu surface, and a theme-scoped `72% 45%` focal position
so the right-side character remains visible while the left side stays clear
for controls and decoration.

## 5. Add a semantic token

Do this only when no existing token describes the visual role:

1. Add it to `assets/theme.schema.json`.
2. Require and validate it in `validateTheme()` in `scripts/injector.mjs`.
3. Add the corresponding property to `ROOT_PROPERTIES` and `applyRoot()` in
   `assets/renderer-inject.js`; cleanup depends on that list.
4. Define a fallback and consume it in `assets/doubao-skin.css`.
5. Add it to `presets/_template/theme.json` and every preset that uses the
   complete section.
6. Assert it in `tests/injector.test.mjs`.
7. Update the token table in this document.

## 6. Selector policy

Prefer `data-testid` anchors from `assets/selectors.json`.

- `L1`: shell structure; required for safe attachment.
- `L2`: optional feature surface; absence is allowed on other routes.

Class substring selectors are a fallback for purely visual details and must be
scoped below a stable `data-testid`. Never target generic generated class names
globally. When Doubao updates, update `verifiedAgainst` only after real-app
inspection.

## 7. Validation

Static and payload validation:

```bash
npm test
npm run check:infp
# Other presets:
node scripts/injector.mjs --check --preset <id>
```

Real renderer smoke test:

```bash
npm run smoke:infp
# Other presets:
DOUBAO_SKIN_SMOKE_PRESET=<id> npm run smoke
```

Authorized live-app check:

```bash
./scripts/start-doubao-skin-macos.sh --restart-existing --preset <id>
./scripts/verify-doubao-skin-macos.sh
```

Authorized Windows live-app check:

```powershell
.\scripts\manage-doubao-skin-windows.ps1 activate-library `
  -ThemeDir "$env:LOCALAPPDATA\DoubaoSkin\themes\<id>"
.\scripts\verify-doubao-skin-windows.ps1
```

Native manager and persistence check:

```bash
npm run build:app
# CLI compatibility path: validate and import a development folder.
./scripts/manage-doubao-skin-macos.sh enable \
  --theme-dir "$PWD/presets/<id>"
# Normal manager path: activate a validated direct child of the theme library.
./scripts/manage-doubao-skin-macos.sh activate-library \
  --theme-dir "$HOME/Library/Application Support/DoubaoSkin/themes/<id>"
# Quit Doubao, launch it normally from Dock/Finder, then verify:
./scripts/manage-doubao-skin-macos.sh verify
```

Windows packaging and persistence check:

```powershell
.\scripts\build-windows-app.ps1
.\scripts\install-windows-app.ps1
& "$env:LOCALAPPDATA\Programs\Doubao Skin\runtime\scripts\manage-doubao-skin-windows.ps1" verify
```

The default archive must contain root-level `Install Doubao Skin.cmd`,
`Install Doubao Skin.ps1`, and `README-zh-CN.txt` so it can install
independently of the source checkout. It must not contain an unsigned native
manager or macOS metadata such as `.DS_Store`, AppleDouble `._*`, or
`__MACOSX`.

On Windows, quit Doubao, start the official launcher normally, and confirm
`scripts/supervisor-windows.ps1` receives the WMI process-start event and
passes the exact normal main PID to
`supervise-once -ObservedProcessId`. The backend must revalidate that PID's
official path, owner, Authenticode signature, main-process role, and lack of
CDP arguments before and after its debounce. Quit Doubao again and wait past
the debounce; no new instance may appear. Do not replace this lifecycle with
an unconditional polling relaunch loop. Starting the tray manager also runs
one `supervise-once` reconciliation without an observed PID. This is required
after an in-place manager upgrade: the installer stops the old renderer
watcher, so the new runtime must restore that watcher for an already-running
verified Doubao instance without waiting for another process-start event.
Windows PowerShell 5.1 may return `/json/list` as one array-valued pipeline
object, so the endpoint validator must explicitly enumerate that response
before checking every target URL against `allowedPageUrls`. Do not validate a
string-concatenated set of target properties or broaden the URL allow-list to
work around this behavior.

Inspect at least:

- tall and wide home windows, especially around the composer;
- sidebar primary, muted, disabled, and selected text;
- heading and suggestion-card text;
- composer input, placeholder, actions, border, and focus state;
- conversation Markdown and links;
- a menu or dialog;
- cleanup through `Restore Doubao Skin.command`.

Runtime verification exposes computed background and composer values. A
revision hash change is expected whenever CSS, renderer code, selectors, theme
JSON, or artwork changes. It audits visible text and icon paint without
returning text content or image URLs:

- `nativeBlackTextCount` must be `0`;
- `composer.icons.nativeBlackVectorPaintCount` must be `0`;
- `composer.icons.untintedRasterIconCount` must be `0`;
- At a normal desktop width, `composer.actionButtons.count` must be greater
  than `0`; responsive or headless layouts may legitimately hide the row and
  report `0`. In every layout,
  `composer.actionButtons.unexpectedFilledCount` must be `0`: ordinary
  `skill_bar_button_*` actions stay transparent at rest and may show only a
  restrained hover/highlight surface.
- `composer.icons.rasterSamples` audits every visible composer image up to
  24 × 24 px outside menus/dialogs and reports only its stable anchor and
  computed filter. This wider audit is intentional: it catches new monochrome
  icon structures without applying a broad styling rule.
- When the mode menu is open, `modeMenu.untintedRasterIconCount` and
  `modeMenu.nativeBlackVectorPaintCount` must both be `0`. The audit ignores the
  smaller colored upgrade badge.
- `composer.nativeInnerSurface.present` and
  `composer.nativeInnerSurface.transparent` must both be `true`; this proves
  that the preset gradient is not hidden behind Doubao's native white layer.
- `composer.backdropFilter` must contain `blur(18px)` for the neutral glass
  surface; this blur is intentionally limited to the composer.
- On a conversation route, `conversation.surfaceBackgroundColor` must equal
  `conversation.scrimToken`, `conversation.backdropFilter` must be `none`;
  `messageListPresent` and `bottomFadePresent` must be true, and
  `bottomFadeBackgroundImage` must not contain
  `rgb(252, 252, 252)`.
- When the More menu is open, `moreMenu.itemCount` must be `3`,
  `moreMenu.unexpectedFilledItemCount` must be `0`, and both icon tint counts
  must be `0`. This proves that the dialog has one continuous theme surface
  instead of three smaller white item rectangles.

## 8. Known pitfalls

- `background-size: 100% auto` leaves an unskinned strip in windows taller than
  the artwork. Use `cover` and a deliberate focal position.
- Large data URLs can be silently rejected as CSS custom-property values.
  The renderer converts embedded artwork to a Blob URL; preserve that path.
- Styling only `color` on the shell is insufficient because Doubao uses several
  token families and locally scoped component rules. Update the centralized
  semantic bridge.
- `color`, `fill`, and `currentColor` cannot recolor a raster `<img>`. Keep
  monochrome skill PNGs on the narrowly scoped `iconFilter` path, and regenerate
  that filter whenever `composer.toolbar` changes.
- In Doubao 2.19.9, `[data-testid="guidance-skill-bar"]` also wraps the
  composer action row. A generic guidance-button background therefore leaks
  into the composer as white pills. Override only
  `[data-testid="chat_input"] button[data-testid^="skill_bar_button_"]` to be
  transparent at rest, then add a light hover surface. Do not broaden this rule
  to the mode selector or voice button, which have intentional surfaces.
- Dropdowns may render outside the visual composer through a portal or popper.
  Do not assume a descendant composer selector reaches them; anchor the exact
  menu structure and verify it while the menu is open.
- A popover can inherit ordinary skill-bar button backgrounds even when its
  outer dialog is correctly tinted. For the Doubao 2.19.9 More menu, anchor the
  exact `role="dialog"` containing actionbar buttons `skill_bar_button_1005`,
  `skill_bar_button_9`, and `skill_bar_button_11`; paint the dialog once, keep
  its default item surfaces transparent, and add color only for hover or
  highlight. If those anchors no longer identify the shell and all three
  items, retain the native popover colors rather than shipping a partial tint.
- A screenshot may expose chat history even in a headless profile. Keep QA
  screenshots local and delete temporary captures.
- Do not modify or re-sign the official app. This project is a reversible,
  loopback-only runtime layer.
- Do not point a LaunchAgent at a checkout. The manager must copy the runtime
  into Application Support and load the supervisor from that stable path.
- Do not point the Windows `Run` value at a checkout. It must start the
  installed PowerShell tray host from `%LOCALAPPDATA%\Programs\Doubao Skin`.
- Treat `config.json`'s `startAtLogin` as the source of truth for the Windows
  login-start preference. The registered command must omit `-Background` so a
  login launch presents the manager window and taskbar button. Clearing the
  preference removes the `Run` value but does not stop the current manager,
  supervisor, watcher, or skin session.
- Do not ship the optional Windows C# manager unsigned or advise disabling
  Smart App Control. The default build intentionally uses Microsoft-signed
  Windows PowerShell as its UI host.
- Keep manager branding separate from theme artwork. The app icon master is
  `assets/app-icon.png`; regenerate `assets/DoubaoSkin.icns` and
  `assets/DoubaoSkin.ico` with `npm run build:icons` after changing it. Do not
  derive the manager icon from an end-user theme folder.
- The supervisor may take over a user-initiated normal Doubao launch, but must
  never relaunch Doubao merely because the user quit it.
