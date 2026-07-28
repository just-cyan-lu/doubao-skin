import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  MAX_BACKGROUND_BYTES,
  buildPayload,
  colorOpacity,
  colorWithOpacity,
  isAllowedPageUrl,
  isValidCdpPageTarget,
  parseArgs,
} from "../scripts/injector.mjs";
import { solveIconFilter } from "../scripts/generate-icon-filter.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

test("manager icon master and platform assets are complete", async () => {
  const [png, icns, ico] = await Promise.all([
    fs.readFile(path.join(root, "assets/app-icon.png")),
    fs.readFile(path.join(root, "assets/DoubaoSkin.icns")),
    fs.readFile(path.join(root, "assets/DoubaoSkin.ico")),
  ]);
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.equal(icns.subarray(0, 4).toString("ascii"), "icns");
  assert.equal(ico.readUInt16LE(0), 0);
  assert.equal(ico.readUInt16LE(2), 1);
  assert.ok(ico.readUInt16LE(4) >= 8);
});

test("argument parsing is explicit and bounded", () => {
  assert.deepEqual(parseArgs(["--once", "--port", "9459", "--timeout-ms", "1200"]), {
    background: null,
    conversationOpacity: null,
    mode: "once",
    port: 9459,
    preset: null,
    screenshot: null,
    themeDir: null,
    timeoutMs: 1200,
  });
  assert.equal(
    parseArgs(["--preset", "mbti-boy-infp"]).preset,
    "mbti-boy-infp",
  );
  assert.equal(
    parseArgs(["--theme-dir", path.join(root, "presets/mbti-boy-infp")]).themeDir,
    path.join(root, "presets/mbti-boy-infp"),
  );
  assert.throws(() => parseArgs(["--port", "80"]), /Invalid CDP port/);
  assert.throws(() => parseArgs(["--timeout-ms", "10"]), /Invalid timeout/);
  assert.equal(parseArgs(["--conversation-opacity", "0.42"]).conversationOpacity, 0.42);
  assert.throws(
    () => parseArgs(["--conversation-opacity", "1.01"]),
    /Invalid conversation opacity/,
  );
  assert.throws(() => parseArgs(["--preset", "../escape"]), /Invalid preset ID/);
  assert.throws(
    () => parseArgs(["--preset", "mbti-boy-infp", "--theme-dir", "/tmp/theme"]),
    /cannot be used together/,
  );
  assert.throws(() => parseArgs(["--unknown"]), /Unknown argument/);
});

test("conversation scrim opacity override preserves its theme color", async () => {
  assert.equal(colorOpacity("#fefcf7"), 1);
  assert.equal(colorOpacity("rgba(250, 248, 240, 0.66)"), 0.66);
  assert.equal(
    colorWithOpacity("rgba(250, 248, 240, 0.66)", 0.42),
    "rgba(250, 248, 240, 0.42)",
  );
  const defaultPayload = await buildPayload({ preset: "mbti-boy-infp" });
  const overridden = await buildPayload({
    conversationOpacity: 0.42,
    preset: "mbti-boy-infp",
  });
  assert.equal(defaultPayload.themeDefaultConversationOpacity, 0.66);
  assert.equal(overridden.themeDefaultConversationOpacity, 0.66);
  assert.equal(overridden.conversationOpacity, 0.42);
  assert.equal(overridden.theme.surfaces.conversation, "rgba(250, 248, 240, 0.42)");
  assert.equal(overridden.theme.surfaces.menu, defaultPayload.theme.surfaces.menu);
  assert.notEqual(overridden.revision, defaultPayload.revision);
});

test("only Doubao chat renderer URLs are accepted", () => {
  for (const value of [
    "doubao://doubao-chat/chat",
    "doubao://doubao-chat/chat/thread/123",
    "chrome://doubao-chat/chat",
    "https://www.doubao.com/chat/",
  ]) {
    assert.equal(isAllowedPageUrl(value), true, value);
  }
  for (const value of [
    "chrome://settings/",
    "https://example.com/chat/",
    "https://www.doubao.com/",
    "file:///tmp/index.html",
    "not a url",
  ]) {
    assert.equal(isAllowedPageUrl(value), false, value);
  }
});

test("CDP target validation pins loopback, port, id, and page URL", () => {
  const valid = {
    id: "ABC_123",
    type: "page",
    url: "doubao://doubao-chat/chat",
    webSocketDebuggerUrl: "ws://127.0.0.1:9451/devtools/page/ABC_123",
  };
  assert.equal(isValidCdpPageTarget(valid, 9451), true);
  assert.equal(isValidCdpPageTarget({ ...valid, type: "service_worker" }, 9451), false);
  assert.equal(isValidCdpPageTarget({
    ...valid,
    webSocketDebuggerUrl: "ws://0.0.0.0:9451/devtools/page/ABC_123",
  }, 9451), false);
  assert.equal(isValidCdpPageTarget({
    ...valid,
    webSocketDebuggerUrl: "ws://127.0.0.1:9452/devtools/page/ABC_123",
  }, 9451), false);
  assert.equal(isValidCdpPageTarget({ ...valid, url: "https://example.com/" }, 9451), false);
});

test("payload is deterministic, self-contained, and syntactically valid", async () => {
  const first = await buildPayload();
  const second = await buildPayload();
  assert.equal(first.revision, second.revision);
  assert.equal(first.theme.id, "aurora-glass");
  assert.equal(first.backgroundBytes, 0);
  assert.ok(first.payload.length > 1000);
  for (const placeholder of [
    "__DOUBAO_SKIN_CSS_JSON__",
    "__DOUBAO_SKIN_ART_JSON__",
    "__DOUBAO_SKIN_THEME_JSON__",
    "__DOUBAO_SKIN_SELECTORS_JSON__",
    "__DOUBAO_SKIN_VERSION_JSON__",
    "__DOUBAO_SKIN_REVISION_JSON__",
  ]) {
    assert.equal(first.payload.includes(placeholder), false, placeholder);
  }
  assert.doesNotThrow(() => new Function(first.payload));
  assert.equal(first.selectors.selectors.filter((entry) => entry.required).length, 3);
  assert.equal(first.selectors.selectors.length, 21);
  assert.ok(first.selectors.selectors.some((entry) => entry.key === "composer-surface"));
  assert.ok(first.selectors.selectors.some((entry) => entry.key === "composer-mode-select"));
  assert.ok(first.selectors.selectors.some((entry) => entry.key === "mode-select-menu"));
  assert.ok(first.selectors.selectors.some((entry) => entry.key === "more-menu"));
  assert.ok(
    first.selectors.selectors.some((entry) => entry.key === "conversation-message-list"),
  );
  assert.ok(first.selectors.selectors.some((entry) => entry.key === "conversation-surface"));
  assert.ok(
    first.selectors.selectors.some((entry) => entry.key === "conversation-bottom-fade"),
  );
});

test("background input is embedded and size-limited", async () => {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "doubao-skin-test."));
  const imagePath = path.join(temporary, "background.png");
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    "base64",
  );
  try {
    await fs.writeFile(imagePath, png);
    const loaded = await buildPayload({ background: imagePath });
    assert.equal(loaded.backgroundBytes, png.length);
    assert.match(loaded.payload, /"mime":"image\/png"/);
    assert.match(loaded.payload, /"base64":/);

    const oversized = path.join(temporary, "too-large.png");
    const handle = await fs.open(oversized, "w");
    try {
      await handle.truncate(MAX_BACKGROUND_BYTES + 1);
    } finally {
      await handle.close();
    }
    await assert.rejects(
      () => buildPayload({ background: oversized }),
      /Background must be a non-empty file/,
    );
  } finally {
    await fs.rm(temporary, { force: true, recursive: true });
  }
});

test("INFP preset embeds its bundled wallpaper and exact decoration copy", async () => {
  const loaded = await buildPayload({ preset: "mbti-boy-infp" });
  assert.equal(loaded.preset, "mbti-boy-infp");
  assert.equal(loaded.theme.id, "mbti-boy-infp");
  assert.equal(loaded.theme.name, "INFP · 调停者男孩");
  assert.equal(loaded.theme.decoration.title, "INFP");
  assert.deepEqual(loaded.theme.decoration.lines, ["内心丰富", "敏感善良", "追求真理"]);
  assert.equal(loaded.theme.composer.text, "#2f4938");
  assert.match(
    loaded.theme.composer.iconFilter,
    /^brightness\(0%\) saturate\(100%\) invert\(/,
  );
  assert.equal(loaded.theme.composer.background, "rgba(255, 255, 255, 0.58)");
  assert.equal(loaded.theme.composer.backgroundAccent, loaded.theme.composer.background);
  assert.equal(loaded.theme.surfaces.conversation, "rgba(250, 248, 240, 0.66)");
  assert.equal(loaded.theme.surfaces.menu, "rgba(250, 248, 240, 0.94)");
  assert.equal(loaded.theme.typography.primary, "#314539");
  assert.equal(loaded.theme.typography.sidebar, "#344b3a");
  assert.equal(loaded.theme.typography.link, "#4f745b");
  assert.ok(loaded.backgroundBytes > 500_000);
  assert.match(loaded.payload, /"mime":"image\/jpeg"/);
  assert.doesNotThrow(() => new Function(loaded.payload));
});

test("the complete MBTI collection is valid, unique, and has exact icon filters", async () => {
  const mbtiTypes = [
    "enfj", "enfp", "entj", "entp", "esfj", "esfp", "estj", "estp",
    "infj", "infp", "intj", "intp", "isfj", "isfp", "istj", "istp",
  ];
  const presetDirectories = ["boy", "girl"].flatMap((gender) => (
    mbtiTypes.map((type) => `mbti-${gender}-${type}`)
  )).sort();
  assert.equal(presetDirectories.length, 32);
  const bundled = JSON.parse(await fs.readFile(
    path.join(root, "presets/bundled-themes.json"),
    "utf8",
  ));
  assert.equal(bundled.schema, "doubao-skin-bundled-themes/1");
  assert.equal(bundled.revision, 2);
  assert.equal(bundled.defaultTheme, "mbti-boy-infp");
  assert.equal(bundled.themes.length, 33);
  assert.equal(bundled.themes.includes("cyan-sunny"), true);
  assert.deepEqual(
    bundled.themes.filter((id) => id.startsWith("mbti-")).sort(),
    presetDirectories,
  );

  const ids = new Set();
  for (const preset of presetDirectories) {
    const loaded = await buildPayload({ preset });
    assert.equal(loaded.theme.background, "background.jpg", preset);
    assert.ok(loaded.backgroundBytes > 500_000, preset);
    assert.equal(loaded.theme.decoration.title.length, 4, preset);
    assert.equal(loaded.theme.decoration.lines.length, 3, preset);
    assert.equal(
      loaded.theme.composer.iconFilter,
      solveIconFilter(loaded.theme.composer.toolbar).filter,
      preset,
    );
    assert.equal(ids.has(loaded.theme.id), false, loaded.theme.id);
    ids.add(loaded.theme.id);
    assert.doesNotThrow(() => new Function(loaded.payload), preset);
  }
  assert.equal(ids.size, 32);
});

test("the Lu Siyuan warm-study preset preserves its artwork and semantic palette", async () => {
  const loaded = await buildPayload({ preset: "cyan-sunny" });
  assert.equal(loaded.theme.id, "cyan-sunny");
  assert.equal(loaded.theme.name, "陆思源 · 暖阳书房");
  assert.equal(loaded.theme.background, "background.jpg");
  assert.equal(loaded.theme.decoration.title, "陆思源");
  assert.deepEqual(loaded.theme.decoration.lines, [
    "慢半拍没关系",
    "温柔总会先一步到达",
    "慢一点，也会稳稳接住你",
  ]);
  assert.equal(loaded.theme.composer.toolbar, "#8b5e3c");
  assert.equal(
    loaded.theme.composer.iconFilter,
    solveIconFilter(loaded.theme.composer.toolbar).filter,
  );
  assert.equal(loaded.theme.composer.background, "rgba(255, 252, 247, 0.58)");
  assert.equal(loaded.theme.surfaces.conversation, "rgba(250, 245, 237, 0.66)");
  assert.equal(loaded.theme.surfaces.menu, "rgba(252, 248, 242, 0.95)");
  assert.ok(loaded.backgroundBytes > 800_000);
  assert.match(loaded.payload, /"mime":"image\/jpeg"/);
  assert.doesNotThrow(() => new Function(loaded.payload));
});

test("a standalone theme directory is equivalent to its repository preset", async () => {
  const preset = await buildPayload({ preset: "mbti-boy-infp" });
  const directory = await buildPayload({
    themeDir: path.join(root, "presets/mbti-boy-infp"),
  });
  assert.equal(directory.theme.id, "mbti-boy-infp");
  assert.equal(directory.backgroundBytes, preset.backgroundBytes);
  assert.equal(directory.revision, preset.revision);
  assert.equal(directory.themeDir, path.join(root, "presets/mbti-boy-infp"));
});

test("theme packages install as a validated JSON and background pair", async (context) => {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "doubao-skin-package-"));
  context.after(() => fs.rm(temporary, { force: true, recursive: true }));
  const source = path.join(temporary, "source");
  const themes = path.join(temporary, "themes");
  await fs.mkdir(source);
  const sourceTheme = JSON.parse(await fs.readFile(
    path.join(root, "presets/mbti-boy-infp/theme.json"),
    "utf8",
  ));
  await fs.copyFile(
    path.join(root, "presets/mbti-boy-infp/theme.json"),
    path.join(source, "theme.json"),
  );
  await fs.copyFile(
    path.join(root, "presets/mbti-boy-infp", sourceTheme.background),
    path.join(source, sourceTheme.background),
  );
  await fs.writeFile(path.join(source, "ignored.txt"), "not part of the package");

  const installed = JSON.parse(execFileSync(process.execPath, [
    path.join(root, "scripts/theme-package.mjs"),
    "install",
    source,
    themes,
  ], { encoding: "utf8" }));
  assert.equal(installed.id, "mbti-boy-infp");
  assert.deepEqual(
    (await fs.readdir(installed.directory)).sort(),
    [sourceTheme.background, "theme.json"].sort(),
  );
  const loaded = await buildPayload({ themeDir: installed.directory });
  assert.equal(loaded.theme.id, "mbti-boy-infp");

  const linked = path.join(temporary, "linked-theme");
  await fs.symlink(source, linked);
  assert.throws(() => execFileSync(process.execPath, [
    path.join(root, "scripts/theme-package.mjs"),
    "inspect",
    linked,
  ], { encoding: "utf8", stdio: "pipe" }), /symbolic link/);

  const linkedBackgroundTheme = path.join(temporary, "linked-background-theme");
  await fs.mkdir(linkedBackgroundTheme);
  await fs.copyFile(
    path.join(root, "presets/mbti-boy-infp/theme.json"),
    path.join(linkedBackgroundTheme, "theme.json"),
  );
  await fs.symlink(
    path.join(root, "presets/mbti-boy-infp", sourceTheme.background),
    path.join(linkedBackgroundTheme, sourceTheme.background),
  );
  assert.throws(() => execFileSync(process.execPath, [
    path.join(root, "scripts/theme-package.mjs"),
    "inspect",
    linkedBackgroundTheme,
  ], { encoding: "utf8", stdio: "pipe" }), /symbolic link/);

  await fs.mkdir(path.join(themes, "broken-theme"));
  await fs.writeFile(path.join(themes, "not-a-theme.txt"), "invalid library entry");
  await fs.symlink(source, path.join(themes, "linked-library-theme"));
  const duplicate = path.join(themes, "renamed-copy");
  await fs.mkdir(duplicate);
  await fs.copyFile(
    path.join(source, "theme.json"),
    path.join(duplicate, "theme.json"),
  );
  await fs.copyFile(
    path.join(source, sourceTheme.background),
    path.join(duplicate, sourceTheme.background),
  );
  const library = JSON.parse(execFileSync(process.execPath, [
    path.join(root, "scripts/theme-package.mjs"),
    "list",
    themes,
  ], { encoding: "utf8" }));
  assert.equal(library.schema, "doubao-skin-theme-library/1");
  assert.equal(library.themes.length, 1);
  assert.equal(library.themes[0].id, "mbti-boy-infp");
  assert.equal(library.themes[0].conversationOpacity, 0.66);
  assert.equal(
    library.themes[0].backgroundPath,
    path.join(installed.directory, sourceTheme.background),
  );
  assert.deepEqual(
    library.invalid.map(({ entry }) => entry).sort(),
    ["broken-theme", "linked-library-theme", "not-a-theme.txt", "renamed-copy"],
  );
  assert.match(
    library.invalid.find(({ entry }) => entry === "renamed-copy").reason,
    /mbti-boy-infp.*重复/,
  );
});

test("bundled theme seeding installs once without overwriting valid user edits", async (
  context,
) => {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "doubao-skin-bundled-"));
  context.after(() => fs.rm(temporary, { force: true, recursive: true }));
  const themes = path.join(temporary, "themes");
  const themePackage = path.join(root, "scripts/theme-package.mjs");
  const first = JSON.parse(execFileSync(process.execPath, [
    themePackage,
    "seed",
    path.join(root, "presets"),
    themes,
  ], { encoding: "utf8" }));
  assert.equal(first.schema, "doubao-skin-bundled-seed/1");
  assert.equal(first.revision, 2);
  assert.equal(first.defaultTheme, "mbti-boy-infp");
  assert.equal(first.installed.length, 33);
  assert.equal(first.preserved.length, 0);
  assert.deepEqual(first.conflicts, []);

  const customizedPath = path.join(themes, "mbti-boy-enfp", "theme.json");
  const customized = JSON.parse(await fs.readFile(customizedPath, "utf8"));
  customized.name = "My preserved ENFP";
  await fs.writeFile(customizedPath, `${JSON.stringify(customized, null, 2)}\n`);

  const second = JSON.parse(execFileSync(process.execPath, [
    themePackage,
    "seed",
    path.join(root, "presets"),
    themes,
  ], { encoding: "utf8" }));
  assert.equal(second.installed.length, 0);
  assert.equal(second.preserved.length, 33);
  assert.deepEqual(second.conflicts, []);
  assert.equal(
    JSON.parse(await fs.readFile(customizedPath, "utf8")).name,
    "My preserved ENFP",
  );
});

test("macOS theme library seeds the bundled collection once and respects deletion", {
  skip: process.platform === "win32",
}, async (context) => {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "doubao-skin-library-"));
  context.after(() => fs.rm(temporary, { force: true, recursive: true }));
  const stateRoot = path.join(temporary, "fresh-state");
  const manager = path.join(root, "scripts/manage-doubao-skin-macos.sh");
  const environment = {
    ...process.env,
    DOUBAO_SKIN_STATE_ROOT: stateRoot,
  };

  const first = JSON.parse(execFileSync("/bin/bash", [
    manager,
    "list-themes",
  ], { encoding: "utf8", env: environment }));
  assert.equal(first.themes.length, 33);
  assert.equal(first.themes.some(({ id }) => id === "mbti-boy-infp"), true);
  assert.equal(first.themes.some(({ id }) => id === "cyan-sunny"), true);
  assert.equal(first.themes.some(({ id }) => id === "infp-garden"), false);
  assert.equal(
    await fs.readFile(path.join(stateRoot, "bundled-theme-library-v2"), "utf8"),
    "1\n",
  );

  await fs.rm(path.join(stateRoot, "themes", "mbti-boy-infp"), {
    force: true,
    recursive: true,
  });
  const refreshed = JSON.parse(execFileSync("/bin/bash", [
    manager,
    "list-themes",
  ], { encoding: "utf8", env: environment }));
  assert.equal(refreshed.themes.length, 32);
  assert.equal(
    refreshed.themes.some(({ id }) => id === "mbti-boy-infp"),
    false,
  );

  const migratedState = path.join(temporary, "existing-state");
  await fs.mkdir(path.join(migratedState, "themes"), { recursive: true });
  await fs.writeFile(
    path.join(migratedState, "theme-library-initialized-v1"),
    "1\n",
  );
  const legacyDirectory = path.join(migratedState, "themes", "infp-garden");
  const currentInfp = JSON.parse(await fs.readFile(
    path.join(root, "presets/mbti-boy-infp/theme.json"),
    "utf8",
  ));
  await fs.mkdir(legacyDirectory);
  await fs.writeFile(
    path.join(legacyDirectory, "theme.json"),
    `${JSON.stringify({
      ...currentInfp,
      id: "infp-garden",
      name: "INFP Garden",
    }, null, 2)}\n`,
  );
  await fs.copyFile(
    path.join(root, "presets/mbti-boy-infp", currentInfp.background),
    path.join(legacyDirectory, currentInfp.background),
  );
  const migrated = JSON.parse(execFileSync("/bin/bash", [
    manager,
    "list-themes",
  ], {
    encoding: "utf8",
    env: {
      ...process.env,
      DOUBAO_SKIN_STATE_ROOT: migratedState,
    },
  }));
  assert.equal(migrated.themes.length, 33);
  assert.equal(migrated.themes.some(({ id }) => id === "infp-garden"), false);
  assert.equal(
    await fs.stat(legacyDirectory).then((value) => value.isDirectory()),
    true,
  );
  assert.equal(
    await fs.readFile(
      path.join(migratedState, "bundled-theme-library-v2"),
      "utf8",
    ),
    "1\n",
  );
});

test("monochrome icon filters are deterministic and accurately match the toolbar color", () => {
  const first = solveIconFilter("#405943");
  const second = solveIconFilter("#405943");
  assert.deepEqual(first, second);
  assert.ok(first.error < 3, `simulated RGB error was ${first.error}`);
  assert.match(
    first.filter,
    /^brightness\(0%\) saturate\(100%\) invert\([0-9]+%\).*contrast\([0-9]+%\)$/,
  );
});

test("repository and release builders publish the AGPL legal notice", async () => {
  const [
    license,
    readme,
    packageText,
    swiftApp,
    infoPlist,
    macBuild,
    macDmgBuild,
    macManager,
    windowsStringsText,
    windowsTray,
    windowsNative,
    windowsBuild,
    windowsPackageReadme,
  ] = await Promise.all([
    fs.readFile(path.join(root, "LICENSE"), "utf8"),
    fs.readFile(path.join(root, "README.md"), "utf8"),
    fs.readFile(path.join(root, "package.json"), "utf8"),
    fs.readFile(path.join(root, "macos/DoubaoSkinApp.swift"), "utf8"),
    fs.readFile(path.join(root, "macos/Info.plist"), "utf8"),
    fs.readFile(path.join(root, "scripts/build-macos-app.sh"), "utf8"),
    fs.readFile(path.join(root, "scripts/build-macos-dmg.sh"), "utf8"),
    fs.readFile(path.join(root, "scripts/manage-doubao-skin-macos.sh"), "utf8"),
    fs.readFile(path.join(root, "windows/strings.zh-CN.json"), "utf8"),
    fs.readFile(path.join(root, "windows/DoubaoSkinTray.ps1"), "utf8"),
    fs.readFile(path.join(root, "windows/DoubaoSkinApp.cs"), "utf8"),
    fs.readFile(path.join(root, "scripts/build-windows-app.ps1"), "utf8"),
    fs.readFile(path.join(root, "windows/PACKAGE-README.zh-CN.txt"), "utf8"),
  ]);
  const packageJson = JSON.parse(packageText);
  const windowsStrings = JSON.parse(windowsStringsText);

  assert.match(license, /GNU AFFERO GENERAL PUBLIC LICENSE/);
  assert.match(license, /Version 3, 19 November 2007/);
  assert.match(license, /END OF TERMS AND CONDITIONS/);
  assert.equal(packageJson.author, "陆思源Cyan");
  assert.equal(packageJson.license, "AGPL-3.0-only");
  assert.match(readme, /Copyright © 2026 \*\*陆思源Cyan\*\*/);
  assert.match(readme, /收费本身并不违规/);
  assert.match(readme, /完整对应源码/);
  assert.doesNotMatch(
    readme,
    /AGPL 不授予“豆包”、字节跳动及其他第三方名称、商标、官方程序或第三方素材的任何权利/,
  );

  assert.match(swiftApp, /© 2026 陆思源Cyan/);
  assert.match(swiftApp, /Link\("GitHub 项目"/);
  assert.match(swiftApp, /https:\/\/github\.com\/just-cyan-lu\/doubao-skin/);
  assert.doesNotMatch(swiftApp, /Link\("查看 LICENSE"/);
  assert.match(infoPlist, /Copyright © 2026 陆思源Cyan · AGPL-3\.0-only/);
  assert.match(macBuild, /macos[\s\S]*LICENSE/);
  assert.match(macManager, /LICENSE/);
  assert.match(macDmgBuild, /STAGING\/LICENSE/);

  assert.match(windowsStrings.copyrightNotice, /© 2026 陆思源Cyan/);
  assert.match(windowsStrings.copyrightNotice, /AGPL-3\.0-only/);
  assert.match(windowsStrings.copyrightNotice, /无担保/);
  assert.equal(windowsStrings.viewProject, "GitHub 项目");
  assert.match(windowsTray, /projectLink/);
  assert.match(windowsTray, /https:\/\/github\.com\/just-cyan-lu\/doubao-skin/);
  assert.doesNotMatch(windowsTray, /licenseLink|viewLicense/);
  assert.match(windowsNative, /© 2026 陆思源Cyan/);
  assert.match(windowsNative, /https:\/\/github\.com\/just-cyan-lu\/doubao-skin/);
  assert.match(windowsBuild, /"LICENSE"/);
  assert.match(windowsBuild, /Destination \(Join-Path \$temporary "LICENSE"\)/);
  assert.match(windowsPackageReadme, /完整条款见同目录 LICENSE/);
});

test("repository ships a complete cross-platform AI-agent theme authoring contract", async () => {
  const [
    schemaText,
    templateText,
    css,
    agentInstructions,
    authoringGuide,
    appGuide,
    supervisor,
    managerScript,
    macCommon,
    swiftApp,
    infoPlist,
  ] =
    await Promise.all([
      fs.readFile(path.join(root, "assets/theme.schema.json"), "utf8"),
      fs.readFile(path.join(root, "presets/_template/theme.json"), "utf8"),
      fs.readFile(path.join(root, "assets/doubao-skin.css"), "utf8"),
      fs.readFile(path.join(root, "AGENTS.md"), "utf8"),
      fs.readFile(path.join(root, "docs/THEME-AUTHORING.md"), "utf8"),
      fs.readFile(path.join(root, "docs/APP-USAGE.md"), "utf8"),
      fs.readFile(path.join(root, "scripts/supervisor-macos.sh"), "utf8"),
      fs.readFile(path.join(root, "scripts/manage-doubao-skin-macos.sh"), "utf8"),
      fs.readFile(path.join(root, "scripts/common-macos.sh"), "utf8"),
      fs.readFile(path.join(root, "macos/DoubaoSkinApp.swift"), "utf8"),
      fs.readFile(path.join(root, "macos/Info.plist"), "utf8"),
    ]);
  const schema = JSON.parse(schemaText);
  const template = JSON.parse(templateText);
  assert.equal(schema.properties.typography.$ref, "#/$defs/typography");
  assert.equal(schema.properties.composer.$ref, "#/$defs/composer");
  assert.equal(schema.properties.surfaces.$ref, "#/$defs/surfaces");
  for (const token of schema.$defs.typography.required) {
    assert.equal(typeof template.typography[token], "string", token);
  }
  for (const token of schema.$defs.composer.required) {
    assert.equal(typeof template.composer[token], "string", token);
  }
  for (const token of schema.$defs.surfaces.required) {
    assert.equal(typeof template.surfaces[token], "string", token);
  }
  assert.match(css, /--s-color-text-primary: var\(--doubao-skin-text-primary\)/);
  assert.match(
    css,
    /chat_input[\s\S]*button\[data-testid\^="skill_bar_button_"\][^{]*\{[^}]*background: transparent !important/,
  );
  assert.match(css, /skill_bar_button_.*doubao-skin-composer-icon-filter/s);
  assert.match(css, /mode-select-action-btn.*doubao-skin-composer-icon-filter/s);
  assert.match(css, /mode_fast\.png.*doubao-skin-composer-icon-filter/s);
  assert.match(css, /input-guidance-input-container-background.*background: transparent/s);
  assert.match(css, /chat_input[^}]*backdrop-filter: blur\(18px\) saturate\(1\.04\)/s);
  assert.match(css, /skill_bar_button_1005.*background: transparent/s);
  assert.match(css, /message-list.*doubao-skin-conversation-scrim/s);
  assert.match(
    css,
    /main:has\(\[data-testid="message-list"\]\)[^}]*backdrop-filter: none !important/s,
  );
  assert.match(css, /from-s-color-bg-body.*doubao-skin-conversation-scrim/s);
  assert.match(agentInstructions, /docs\/THEME-AUTHORING\.md/);
  assert.match(authoringGuide, /nativeBlackTextCount/);
  assert.match(authoringGuide, /actionButtons\.unexpectedFilledCount/);
  assert.match(authoringGuide, /untintedRasterIconCount/);
  assert.match(authoringGuide, /modeMenu\.untintedRasterIconCount/);
  assert.match(authoringGuide, /moreMenu\.unexpectedFilledItemCount/);
  assert.match(authoringGuide, /conversationOpacity/);
  assert.match(authoringGuide, /--theme-dir/);
  assert.match(appGuide, /theme\.json/);
  assert.match(appGuide, /打开主题库/);
  assert.match(appGuide, /粘贴/);
  assert.match(appGuide, /com\.local\.doubao-skin\.supervisor\.plist/);
  assert.match(appGuide, /%LOCALAPPDATA%\\DoubaoSkin\\themes/);
  assert.match(supervisor, /doubao_interactive_is_running/);
  assert.match(supervisor, /normal Doubao launch detected/);
  assert.match(managerScript, /activate-library/);
  assert.match(managerScript, /list-themes/);
  assert.match(managerScript, /conversationOpacity -float/);
  assert.match(managerScript, /THEME_LIBRARY_MARKER/);
  assert.match(managerScript, /seed "\$PROJECT_ROOT\/presets" "\$THEMES_ROOT"/);
  assert.match(macCommon, /bundled-theme-library-v2/);
  assert.doesNotMatch(
    managerScript,
    /\[\s*!\s+-e\s+"\$THEMES_ROOT\/infp-garden"\s*\]/,
  );
  assert.match(swiftApp, /MenuBarExtra/);
  assert.match(swiftApp, /applicationShouldTerminateAfterLastWindowClosed/);
  assert.match(swiftApp, /setActivationPolicy\(\.regular\)/);
  assert.match(swiftApp, /setActivationPolicy\(\.accessory\)/);
  assert.match(swiftApp, /NSWindow\.willCloseNotification/);
  assert.match(swiftApp, /ThemeLibraryCard/);
  assert.match(swiftApp, /activate-library/);
  assert.match(swiftApp, /list-themes/);
  assert.match(swiftApp, /set-conversation-opacity/);
  assert.doesNotMatch(swiftApp, /NSOpenPanel|选择主题文件夹/);
  assert.match(infoPlist, /<key>LSUIElement<\/key>\s*<true\/>/);
  assert.match(infoPlist, /<key>CFBundleIconFile<\/key>\s*<string>DoubaoSkin\.icns<\/string>/);
});

test("Windows manager pins official identity and uses event-driven tray persistence", async () => {
  const [
    identityText,
    commonScript,
    managerScript,
    supervisorScript,
    trayScript,
    nativeManager,
    stringsText,
    buildScript,
    installScript,
    packageInstaller,
    packageCommand,
    packageReadme,
    windowsGuide,
    authoringGuide,
    agentInstructions,
  ] = await Promise.all([
    fs.readFile(path.join(root, "assets/windows-app-identity.json"), "utf8"),
    fs.readFile(path.join(root, "scripts/common-windows.ps1"), "utf8"),
    fs.readFile(path.join(root, "scripts/manage-doubao-skin-windows.ps1"), "utf8"),
    fs.readFile(path.join(root, "scripts/supervisor-windows.ps1"), "utf8"),
    fs.readFile(path.join(root, "windows/DoubaoSkinTray.ps1"), "utf8"),
    fs.readFile(path.join(root, "windows/DoubaoSkinApp.cs"), "utf8"),
    fs.readFile(path.join(root, "windows/strings.zh-CN.json"), "utf8"),
    fs.readFile(path.join(root, "scripts/build-windows-app.ps1"), "utf8"),
    fs.readFile(path.join(root, "scripts/install-windows-app.ps1"), "utf8"),
    fs.readFile(path.join(root, "windows/Install-DoubaoSkinPackage.ps1"), "utf8"),
    fs.readFile(path.join(root, "windows/Install-DoubaoSkinPackage.cmd"), "utf8"),
    fs.readFile(path.join(root, "windows/PACKAGE-README.zh-CN.txt"), "utf8"),
    fs.readFile(path.join(root, "windows/README.md"), "utf8"),
    fs.readFile(path.join(root, "docs/THEME-AUTHORING.md"), "utf8"),
    fs.readFile(path.join(root, "AGENTS.md"), "utf8"),
  ]);
  const identity = JSON.parse(identityText);
  const strings = JSON.parse(stringsText);
  assert.equal(identity.schema, "doubao-skin-windows-identity/1");
  assert.equal(identity.verifiedAgainst.doubaoLauncherVersion, "2.19.9");
  assert.equal(identity.verifiedAgainst.chromiumVersion, "135.0.7049.72");
  assert.equal(identity.publisher, "Beijing Chuntian Zhiyun Technology Co., Ltd.");
  assert.equal(identity.signer.thumbprints.length, 1);
  assert.match(identity.signer.thumbprints[0], /^[A-F0-9]{40}$/);
  assert.deepEqual(identity.allowedPageUrls, [
    "chrome://doubao-chat/chat",
    "doubao://doubao-chat/chat",
    "https://www.doubao.com/chat/",
  ]);

  assert.match(commonScript, /Get-AuthenticodeSignature/);
  assert.match(commonScript, /Get-ProcessOwnerName/);
  assert.match(commonScript, /Get-ObservedNormalDoubaoMain/);
  assert.match(commonScript, /Assert-OfficialDoubaoFile/);
  assert.match(commonScript, /Identity\.allowedPageUrls/);
  assert.match(
    commonScript,
    /\$targetResponse\s*=\s*Invoke-RestMethod[\s\S]*?foreach \(\$target in \$targetResponse\)/,
  );
  assert.match(commonScript, /@\(.*127\.0\.0\.1.*::1.*\)/s);
  assert.match(commonScript, /No verified Doubao chat renderer is exposed by CDP/);
  assert.match(commonScript, /WindowsPowerShell\\v1\.0\\powershell\.exe/);
  assert.match(commonScript, /Get-DoubaoSkinStartAtLogin/);
  assert.match(commonScript, /Get-DoubaoSkinConversationOpacity/);
  assert.match(commonScript, /Test-DoubaoSkinStartupRegistration/);
  assert.match(commonScript, /startAtLogin\s*=\s*\$StartAtLogin/);
  assert.match(commonScript, /\$stableEmptySamples\s*=\s*0/);
  assert.match(
    commonScript,
    /Get-DoubaoFamilyProcesses[\s\S]*?Stop-Process[\s\S]*?Get-DoubaoFamilyProcesses/,
  );
  assert.doesNotMatch(commonScript, /-File\s+"\{1\}"\s+-Background/);
  assert.doesNotMatch(commonScript, /0\.0\.0\.0/);

  assert.match(managerScript, /\[int\]\$ObservedProcessId = 0/);
  assert.match(managerScript, /Get-ObservedNormalDoubaoMain/);
  assert.match(managerScript, /-NormalLaunchProcessId \$ObservedProcessId/);
  assert.match(managerScript, /set-conversation-opacity/);
  assert.match(trayScript, /conversationOpacitySlider/);
  assert.match(nativeManager, /conversationOpacitySlider/);
  assert.equal(strings.conversationOpacity, "对话页蒙版不透明度");
  assert.match(managerScript, /ensure-supervisor/);
  assert.match(
    managerScript,
    /"ensure-supervisor"\s*\{[\s\S]*?Start-DoubaoSkinEventSupervisor[\s\S]*?Invoke-SupervisorOnce\s*\n\s*\}/,
  );
  assert.match(managerScript, /activate-library/);
  assert.match(managerScript, /list-themes/);
  assert.match(managerScript, /ThemeLibraryMarkerPath/);
  assert.match(managerScript, /@\("seed", \$source, \$script:ThemesRoot\)/);
  assert.match(commonScript, /bundled-theme-library-v2/);
  assert.match(managerScript, /enable-startup/);
  assert.match(managerScript, /disable-startup/);
  assert.match(managerScript, /startupRegistered/);
  assert.match(managerScript, /\[string\]\$OperationResultPath = ""/);
  assert.match(managerScript, /doubao-skin-ui-operation\/1/);
  assert.match(
    managerScript,
    /"--verify"[\s\S]*?# Publish enabled state only after[\s\S]*?Write-DoubaoSkinConfig[\s\S]*?-Enabled \$true/,
  );

  assert.match(supervisorScript, /__InstanceCreationEvent WITHIN 1/);
  assert.match(supervisorScript, /WaitForNextEvent/);
  assert.match(supervisorScript, /\$process\.WaitForExit\(\)/);
  assert.match(supervisorScript, /Get-ObservedNormalDoubaoMain/);
  assert.match(supervisorScript, /-ObservedProcessId/);
  assert.doesNotMatch(supervisorScript, /Start-Sleep|AddSeconds\(15\)/);
  assert.match(trayScript, /Windows\.Forms\.NotifyIcon/);
  assert.match(trayScript, /assets\\DoubaoSkin\.ico/);
  assert.match(trayScript, /ensure-supervisor/);
  assert.match(trayScript, /Add_FormClosing/);
  assert.match(trayScript, /CloseReason\]::WindowsShutDown/);
  assert.match(trayScript, /LargeImageList/);
  assert.match(trayScript, /startAtLogin/);
  assert.match(trayScript, /CheckedChanged/);
  assert.match(trayScript, /operationFailureTitle/);
  assert.match(trayScript, /MessageBoxIcon\]::Error/);
  assert.match(
    trayScript,
    /"-Command"[\s\S]*?switch \(\$parameterName\)[\s\S]*?"-ThemeDir"[\s\S]*?\$commandParts \+= "-ThemeDir"/,
  );
  assert.match(
    trayScript,
    /function Read-OperationText[\s\S]*?FileShare\]::ReadWrite[\s\S]*?FileShare\]::Delete/,
  );
  assert.match(trayScript, /"-OperationResultPath"/);
  assert.doesNotMatch(trayScript, /RedirectStandard(Output|Error)/);
  assert.doesNotMatch(
    trayScript,
    /foreach \(\$argument in \$Arguments\)[\s\S]*?Quote-Single -Value \$argument/,
  );
  assert.doesNotMatch(trayScript, /FolderBrowserDialog|OpenFileDialog/);
  assert.doesNotMatch(trayScript, /Win32_ProcessStartTrace|lastFallback|AddSeconds\(15\)/);
  assert.match(nativeManager, /ensure-supervisor/);
  assert.doesNotMatch(
    nativeManager,
    /Win32_ProcessStartTrace|fallbackTimer|Interval = 15000/,
  );

  assert.equal(strings.windowTitle, "Doubao Skin");
  assert.match(strings.openLibrary, /主题库/);
  assert.match(strings.startAtLogin, /开机自动启动/);
  assert.match(buildScript, /\$nodeVersion = "v24\.16\.0"/);
  assert.match(
    buildScript,
    /\$nodeSha256 = "edaca9bd58ec8e92037dac4e877d52f6b8f430b81c18b57e264b4e2fb111cd56"/,
  );
  assert.match(buildScript, /if \(\$CompileNativeManager\)/);
  assert.match(buildScript, /win32icon:.*DoubaoSkin\.ico/);
  assert.match(buildScript, /Install Doubao Skin\.ps1/);
  assert.match(buildScript, /Install Doubao Skin\.cmd/);
  assert.match(buildScript, /README-zh-CN\.txt/);
  assert.match(buildScript, /-Path \(Join-Path \$appPath "\*"\)/);
  assert.doesNotMatch(buildScript, /Compress-Archive -LiteralPath \$appPath/);
  assert.match(buildScript, /\.DS_Store/);
  assert.match(installScript, /Stop-InstalledDoubaoSkinProcesses/);
  assert.match(installScript, /\[string\]\$PackagePath = ""/);
  assert.match(installScript, /DoubaoSkinTray\.ps1/);
  assert.match(installScript, /IconLocation = "\$iconPath,0"/);
  assert.match(packageInstaller, /-PackagePath \$packageRoot/);
  assert.match(packageCommand, /Install Doubao Skin\.ps1/);
  assert.match(packageReadme, /全部解压/);
  assert.match(packageReadme, /对话页蒙版不透明度/);
  assert.match(windowsGuide, /Smart App Control/);
  assert.match(windowsGuide, /no unconditional periodic relaunch check/i);
  assert.match(windowsGuide, /without `-Background`/);
  assert.match(authoringGuide, /supervise-once -ObservedProcessId/);
  assert.match(agentInstructions, /restore periodic unconditional\s+supervision/);
});

test("all macOS entry scripts pass Bash syntax validation", {
  skip: process.platform === "win32",
}, async () => {
  const files = [
    "scripts/common-macos.sh",
    "scripts/start-doubao-skin-macos.sh",
    "scripts/verify-doubao-skin-macos.sh",
    "scripts/restore-doubao-skin-macos.sh",
    "scripts/manage-doubao-skin-macos.sh",
    "scripts/supervisor-macos.sh",
    "scripts/build-macos-app.sh",
    "scripts/build-macos-dmg.sh",
    "scripts/build-app-icons.sh",
    "scripts/install-macos-app.sh",
    "Start Doubao Skin.command",
    "Start INFP Skin.command",
    "Restore Doubao Skin.command",
    "Verify Doubao Skin.command",
    "tests/smoke-headless-macos.sh",
  ];
  for (const relative of files) {
    execFileSync("/bin/bash", ["-n", path.join(root, relative)]);
  }
});

test("all Windows entry scripts pass PowerShell syntax validation on Windows", {
  skip: process.platform !== "win32",
}, () => {
  const files = [
    "scripts/common-windows.ps1",
    "scripts/manage-doubao-skin-windows.ps1",
    "scripts/supervisor-windows.ps1",
    "scripts/start-doubao-skin-windows.ps1",
    "scripts/verify-doubao-skin-windows.ps1",
    "scripts/restore-doubao-skin-windows.ps1",
    "scripts/build-windows-app.ps1",
    "scripts/install-windows-app.ps1",
    "windows/Install-DoubaoSkinPackage.ps1",
    "windows/DoubaoSkinTray.ps1",
    "tests/windows-backend-process-regression.ps1",
    "tests/windows-lifecycle-regression.ps1",
    "tests/windows-manager-ui-regression.ps1",
  ];
  for (const relative of files) {
    const absolute = path.join(root, relative).replaceAll("'", "''");
    const command = [
      "$tokens = $null",
      "$errors = $null",
      `[System.Management.Automation.Language.Parser]::ParseFile('${absolute}', [ref]$tokens, [ref]$errors) | Out-Null`,
      "if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_.Message }; exit 1 }",
    ].join("; ");
    execFileSync("powershell.exe", [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-Command",
      command,
    ]);
  }
});
