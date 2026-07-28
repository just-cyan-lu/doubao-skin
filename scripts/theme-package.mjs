import fs from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";

import {
  MAX_BACKGROUND_BYTES,
  buildPayload,
  validateTheme,
} from "./injector.mjs";

const MAX_THEME_BYTES = 1024 * 1024;
const MAX_BUNDLED_MANIFEST_BYTES = 64 * 1024;
const OPEN_FLAGS = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0);
const BUNDLED_MANIFEST_NAME = "bundled-themes.json";
const DEPRECATED_LIBRARY_THEME_IDS = new Set(["infp-garden"]);

function fail(message) {
  throw new Error(message);
}

function assertContained(root, candidate, label) {
  const relative = path.relative(root, candidate);
  if (
    relative === ""
    || (!path.isAbsolute(relative) && relative !== ".." && !relative.startsWith(`..${path.sep}`))
  ) return;
  fail(`${label} must stay inside the theme directory`);
}

function stableStat(before, after) {
  return before.isFile()
    && after.isFile()
    && before.dev === after.dev
    && before.ino === after.ino
    && before.size === after.size
    && before.mtimeMs === after.mtimeMs
    && before.ctimeMs === after.ctimeMs;
}

async function readStableFile(filePath, label, maximumBytes) {
  const linkStat = await fs.lstat(filePath);
  if (linkStat.isSymbolicLink()) fail(`${label} cannot be a symbolic link`);
  let handle;
  try {
    handle = await fs.open(filePath, OPEN_FLAGS);
  } catch (error) {
    if (error?.code === "ELOOP") fail(`${label} cannot be a symbolic link`);
    throw error;
  }
  try {
    const before = await handle.stat();
    if (!before.isFile()) fail(`${label} must be a regular file`);
    if (before.size < 1 || before.size > maximumBytes) {
      fail(`${label} must be between 1 and ${maximumBytes} bytes`);
    }
    const bytes = await handle.readFile();
    const after = await handle.stat();
    if (!stableStat(before, after)) fail(`${label} changed while it was being read`);
    return bytes;
  } finally {
    await handle.close();
  }
}

function parseTheme(bytes) {
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  if (text.includes("\0")) fail("theme.json contains NUL characters");
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    fail("theme.json is not valid JSON");
  }
  return validateTheme(parsed);
}

function validateImageSignature(bytes, extension) {
  if (extension === ".png") {
    if (!bytes.subarray(0, 8).equals(Buffer.from("89504e470d0a1a0a", "hex"))) {
      fail("The PNG background has an invalid file signature");
    }
    return;
  }
  if (extension === ".jpg" || extension === ".jpeg") {
    if (bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) {
      fail("The JPEG background has an invalid file signature");
    }
    return;
  }
  if (extension === ".webp") {
    const riff = bytes.subarray(0, 4).toString("ascii");
    const webp = bytes.subarray(8, 12).toString("ascii");
    if (riff !== "RIFF" || webp !== "WEBP") {
      fail("The WebP background has an invalid file signature");
    }
    return;
  }
  fail("Background must be PNG, JPEG, or WebP");
}

async function inspectSource(sourceArgument) {
  const requested = path.resolve(sourceArgument);
  const requestedStat = await fs.lstat(requested);
  if (requestedStat.isSymbolicLink()) fail("Theme directory cannot be a symbolic link");
  const source = await fs.realpath(requested);
  const sourceStat = await fs.stat(source);
  if (!sourceStat.isDirectory()) fail("Theme source must be a directory");

  const themeBytes = await readStableFile(
    path.join(source, "theme.json"),
    "theme.json",
    MAX_THEME_BYTES,
  );
  const theme = parseTheme(themeBytes);
  if (!theme.background) {
    fail("Imported themes must declare a background image in theme.json");
  }

  const backgroundPath = path.resolve(source, theme.background);
  assertContained(source, backgroundPath, "Background");
  const backgroundBytes = await readStableFile(
    backgroundPath,
    "Background image",
    MAX_BACKGROUND_BYTES,
  );
  validateImageSignature(backgroundBytes, path.extname(theme.background).toLowerCase());
  return {
    backgroundBytes,
    source,
    theme,
    themeBytes,
  };
}

async function writePrivate(filePath, bytes) {
  await fs.writeFile(filePath, bytes, { flag: "wx", mode: 0o600 });
}

async function installTheme(
  sourceArgument,
  themesRootArgument,
  { replaceExisting = true } = {},
) {
  const inspected = await inspectSource(sourceArgument);
  const themesRoot = path.resolve(themesRootArgument);
  await fs.mkdir(themesRoot, { recursive: true, mode: 0o700 });
  await fs.chmod(themesRoot, 0o700);
  const canonicalRoot = await fs.realpath(themesRoot);
  const id = inspected.theme.id.toLowerCase();
  const destination = path.join(canonicalRoot, id);
  assertContained(canonicalRoot, destination, "Installed theme");

  const nonce = `${process.pid}-${randomBytes(6).toString("hex")}`;
  const stage = path.join(canonicalRoot, `.installing-${nonce}`);
  const previous = path.join(canonicalRoot, `.previous-${nonce}`);
  await fs.mkdir(stage, { mode: 0o700 });
  let previousNeedsCleanup = false;
  try {
    await writePrivate(path.join(stage, inspected.theme.background), inspected.backgroundBytes);
    await writePrivate(path.join(stage, "theme.json"), inspected.themeBytes);
    await buildPayload({ themeDir: stage });

    if (!replaceExisting) {
      await fs.rename(stage, destination);
    } else {
      let hadPrevious = false;
      try {
        await fs.rename(destination, previous);
        hadPrevious = true;
        previousNeedsCleanup = true;
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
      try {
        await fs.rename(stage, destination);
      } catch (error) {
        if (hadPrevious) {
          // Preserve the backup even if rollback itself fails.
          previousNeedsCleanup = false;
          await fs.rename(previous, destination);
        }
        throw error;
      }
      if (hadPrevious) {
        await fs.rm(previous, { recursive: true, force: true });
        previousNeedsCleanup = false;
      }
    }
  } finally {
    await fs.rm(stage, { recursive: true, force: true }).catch(() => {});
    if (previousNeedsCleanup) {
      // The new destination has already been published. Failure here leaves a
      // harmless hidden backup rather than risking deletion during rollback.
      await fs.rm(previous, { recursive: true, force: true }).catch(() => {});
    }
  }

  return {
    background: inspected.theme.background,
    directory: destination,
    id,
    name: inspected.theme.name,
  };
}

async function inspectTheme(sourceArgument) {
  const inspected = await inspectSource(sourceArgument);
  const loaded = await buildPayload({ themeDir: inspected.source });
  return {
    background: inspected.theme.background,
    backgroundPath: path.join(inspected.source, inspected.theme.background),
    directory: inspected.source,
    id: inspected.theme.id.toLowerCase(),
    name: inspected.theme.name,
    revision: loaded.revision,
  };
}

async function readBundledManifest(presetsRootArgument) {
  const requestedRoot = path.resolve(presetsRootArgument);
  const requestedStat = await fs.lstat(requestedRoot);
  if (requestedStat.isSymbolicLink()) fail("Bundled presets root cannot be a symbolic link");
  if (!requestedStat.isDirectory()) fail("Bundled presets root must be a directory");
  const presetsRoot = await fs.realpath(requestedRoot);
  const manifestBytes = await readStableFile(
    path.join(presetsRoot, BUNDLED_MANIFEST_NAME),
    BUNDLED_MANIFEST_NAME,
    MAX_BUNDLED_MANIFEST_BYTES,
  );
  let manifest;
  try {
    manifest = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(manifestBytes));
  } catch {
    fail(`${BUNDLED_MANIFEST_NAME} is not valid UTF-8 JSON`);
  }
  if (
    manifest?.schema !== "doubao-skin-bundled-themes/1"
    || !Number.isInteger(manifest.revision)
    || manifest.revision < 1
    || !Array.isArray(manifest.themes)
    || manifest.themes.length < 1
  ) {
    fail(`${BUNDLED_MANIFEST_NAME} has an invalid schema`);
  }
  const themes = [];
  const seen = new Set();
  for (const value of manifest.themes) {
    const id = String(value);
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(id) || seen.has(id)) {
      fail(`${BUNDLED_MANIFEST_NAME} contains an invalid or duplicate theme ID`);
    }
    seen.add(id);
    themes.push(id);
  }
  const defaultTheme = String(manifest.defaultTheme ?? "");
  if (!seen.has(defaultTheme)) {
    fail(`${BUNDLED_MANIFEST_NAME} defaultTheme is not in the theme list`);
  }
  return {
    defaultTheme,
    presetsRoot,
    revision: manifest.revision,
    themes,
  };
}

async function seedBundledThemes(presetsRootArgument, themesRootArgument) {
  const manifest = await readBundledManifest(presetsRootArgument);
  const requestedThemesRoot = path.resolve(themesRootArgument);
  await fs.mkdir(requestedThemesRoot, { recursive: true, mode: 0o700 });
  const rootStat = await fs.lstat(requestedThemesRoot);
  if (rootStat.isSymbolicLink()) fail("Theme library cannot be a symbolic link");
  if (!rootStat.isDirectory()) fail("Theme library must be a directory");
  await fs.chmod(requestedThemesRoot, 0o700);
  const themesRoot = await fs.realpath(requestedThemesRoot);
  const installed = [];
  const preserved = [];
  const conflicts = [];

  for (const id of manifest.themes) {
    const source = path.join(manifest.presetsRoot, id);
    assertContained(manifest.presetsRoot, source, "Bundled theme");
    const bundled = await inspectTheme(source);
    if (bundled.id !== id || path.basename(bundled.directory) !== id) {
      fail(`Bundled theme identity mismatch: ${id}`);
    }

    const destination = path.join(themesRoot, id);
    assertContained(themesRoot, destination, "Bundled theme destination");
    let destinationExists = false;
    try {
      const destinationStat = await fs.lstat(destination);
      destinationExists = true;
      if (destinationStat.isSymbolicLink() || !destinationStat.isDirectory()) {
        throw new Error("destination is not an ordinary directory");
      }
      const existing = await inspectTheme(destination);
      if (existing.id !== id) {
        throw new Error(`destination declares theme ID "${existing.id}"`);
      }
      preserved.push(id);
    } catch (error) {
      if (destinationExists) {
        conflicts.push({
          id,
          reason: safeDiagnostic(error?.message, "existing destination is invalid"),
        });
        continue;
      }
      if (error?.code !== "ENOENT") throw error;
      const result = await installTheme(source, themesRoot, { replaceExisting: false });
      installed.push(result.id);
    }
  }

  return {
    schema: "doubao-skin-bundled-seed/1",
    revision: manifest.revision,
    defaultTheme: manifest.defaultTheme,
    installed,
    preserved,
    conflicts,
  };
}

function safeDiagnostic(value, fallback) {
  const cleaned = String(value ?? "")
    .replaceAll(/[\u0000-\u001f\u007f]/g, " ")
    .trim();
  return cleaned ? cleaned.slice(0, 240) : fallback;
}

async function listThemes(themesRootArgument) {
  const requestedRoot = path.resolve(themesRootArgument);
  await fs.mkdir(requestedRoot, { recursive: true, mode: 0o700 });
  const requestedStat = await fs.lstat(requestedRoot);
  if (requestedStat.isSymbolicLink()) fail("Theme library cannot be a symbolic link");
  if (!requestedStat.isDirectory()) fail("Theme library must be a directory");
  await fs.chmod(requestedRoot, 0o700);
  const themesRoot = await fs.realpath(requestedRoot);
  const entries = await fs.readdir(themesRoot, { withFileTypes: true });
  const themes = [];
  const invalid = [];
  const themeById = new Map();

  for (const entry of entries.sort((left, right) => (
    left.name.localeCompare(right.name, "zh-CN")
  ))) {
    if (entry.name.startsWith(".")) continue;
    const entryPath = path.join(themesRoot, entry.name);
    if (!entry.isDirectory() || entry.isSymbolicLink()) {
      invalid.push({
        entry: safeDiagnostic(entry.name, "未命名项目"),
        reason: "主题必须是普通文件夹，不能是文件或符号链接",
      });
      continue;
    }
    try {
      const inspected = await inspectTheme(entryPath);
      const parent = path.dirname(inspected.directory);
      if (parent !== themesRoot) fail("Theme must be a direct child of the library");
      // The early PoC shipped the boy INFP artwork as "infp-garden".
      // Keep its files untouched for active upgrade compatibility, but hide
      // that retired identity after the consistently named replacement is
      // bundled as "mbti-boy-infp".
      if (DEPRECATED_LIBRARY_THEME_IDS.has(inspected.id)) continue;
      const existing = themeById.get(inspected.id);
      if (existing) {
        invalid.push({
          entry: safeDiagnostic(entry.name, "未命名主题"),
          reason: `主题 ID "${safeDiagnostic(inspected.id, "unknown")}" `
            + `与文件夹 "${safeDiagnostic(path.basename(existing.directory), "未知主题")}" 重复`,
        });
        continue;
      }
      themeById.set(inspected.id, inspected);
      themes.push(inspected);
    } catch (error) {
      invalid.push({
        entry: safeDiagnostic(entry.name, "未命名主题"),
        reason: safeDiagnostic(error?.message, "主题校验失败"),
      });
    }
  }

  themes.sort((left, right) => (
    left.name.localeCompare(right.name, "zh-CN")
    || left.id.localeCompare(right.id, "en")
  ));
  return {
    schema: "doubao-skin-theme-library/1",
    directory: themesRoot,
    themes,
    invalid,
  };
}

const [command, source, destination] = process.argv.slice(2);
let result;
if (command === "install" && source && destination) {
  result = await installTheme(source, destination);
} else if (command === "seed" && source && destination) {
  result = await seedBundledThemes(source, destination);
} else if (command === "inspect" && source && !destination) {
  result = await inspectTheme(source);
} else if (command === "list" && source && !destination) {
  result = await listThemes(source);
} else {
  fail(
    "Usage: theme-package.mjs inspect <theme-dir> | "
      + "install <theme-dir> <themes-root> | "
      + "seed <presets-root> <themes-root> | list <themes-root>",
  );
}
process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
