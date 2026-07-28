import fs from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = path.dirname(scriptPath);
const projectRoot = path.resolve(scriptDir, "..");
const assetsRoot = path.join(projectRoot, "assets");
const presetsRoot = path.join(projectRoot, "presets");

export const SKIN_VERSION = "0.8.3";
export const RUNTIME_STATE_KEY = "__DOUBAO_SKIN_POC_RUNTIME__";
export const MAX_BACKGROUND_BYTES = 16 * 1024 * 1024;
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]"]);
const CDP_TARGET_ID = /^[A-Za-z0-9._-]{1,200}$/;
const PRESET_ID = /^[a-z0-9][a-z0-9-]{0,79}$/;

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

export function parseArgs(argv) {
  const options = {
    background: null,
    mode: "watch",
    port: 9451,
    preset: null,
    screenshot: null,
    themeDir: null,
    timeoutMs: 30000,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--port") options.port = Number(argv[++index]);
    else if (argument === "--background") options.background = path.resolve(argv[++index]);
    else if (argument === "--preset") options.preset = argv[++index] ?? "";
    else if (argument === "--theme-dir") options.themeDir = path.resolve(argv[++index]);
    else if (argument === "--timeout-ms") options.timeoutMs = Number(argv[++index]);
    else if (argument === "--screenshot") options.screenshot = path.resolve(argv[++index]);
    else if (argument === "--once") options.mode = "once";
    else if (argument === "--watch") options.mode = "watch";
    else if (argument === "--verify") options.mode = "verify";
    else if (argument === "--remove") options.mode = "remove";
    else if (argument === "--check") options.mode = "check";
    else throw new Error(`Unknown argument: ${argument}`);
  }

  if (!Number.isInteger(options.port) || options.port < 1024 || options.port > 65535) {
    throw new Error(`Invalid CDP port: ${options.port}`);
  }
  if (!Number.isFinite(options.timeoutMs) || options.timeoutMs < 250 || options.timeoutMs > 120000) {
    throw new Error(`Invalid timeout: ${options.timeoutMs}`);
  }
  if (options.preset !== null && !PRESET_ID.test(options.preset)) {
    throw new Error(`Invalid preset ID: ${options.preset || "<empty>"}`);
  }
  if (options.preset !== null && options.themeDir !== null) {
    throw new Error("--preset and --theme-dir cannot be used together");
  }
  return options;
}

export function isAllowedPageUrl(value) {
  try {
    const url = new URL(value);
    if (
      (url.protocol === "doubao:" || url.protocol === "chrome:")
      && url.hostname === "doubao-chat"
    ) {
      return url.pathname === "/chat" || url.pathname.startsWith("/chat/");
    }
    return url.protocol === "https:"
      && url.hostname === "www.doubao.com"
      && (url.pathname === "/chat" || url.pathname.startsWith("/chat/"));
  } catch {
    return false;
  }
}

export function validatedDebuggerUrl(target, port) {
  if (typeof target?.webSocketDebuggerUrl !== "string") {
    throw new Error("CDP target has no WebSocket URL");
  }
  const url = new URL(target.webSocketDebuggerUrl);
  const validPath = /^\/devtools\/page\/[A-Za-z0-9._-]{1,200}$/.test(url.pathname);
  if (
    url.protocol !== "ws:"
    || !LOOPBACK_HOSTS.has(url.hostname)
    || Number(url.port) !== port
    || url.username
    || url.password
    || url.search
    || url.hash
    || !validPath
  ) {
    throw new Error("Rejected a CDP WebSocket outside the expected loopback page endpoint");
  }
  return url.href;
}

export function isValidCdpPageTarget(target, port) {
  if (
    target?.type !== "page"
    || typeof target.id !== "string"
    || !CDP_TARGET_ID.test(target.id)
    || !isAllowedPageUrl(target.url)
  ) {
    return false;
  }
  try {
    const url = new URL(validatedDebuggerUrl(target, port));
    return url.pathname === `/devtools/page/${target.id}`;
  } catch {
    return false;
  }
}

class CdpSession {
  constructor(target, port) {
    this.target = target;
    this.socket = new WebSocket(validatedDebuggerUrl(target, port));
    this.nextId = 1;
    this.pending = new Map();
    this.closed = false;
  }

  async open() {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        try {
          this.socket.close();
        } catch {}
        reject(new Error("CDP WebSocket connection timed out"));
      }, 5000);
      this.socket.addEventListener("open", () => {
        clearTimeout(timeout);
        resolve();
      }, { once: true });
      this.socket.addEventListener("error", () => {
        clearTimeout(timeout);
        reject(new Error("CDP WebSocket connection failed"));
      }, { once: true });
    });

    this.socket.addEventListener("message", (event) => this.onMessage(event));
    this.socket.addEventListener("close", () => this.close());
    this.socket.addEventListener("error", () => this.close());
    await this.send("Runtime.enable");
    await this.send("Page.enable");
    return this;
  }

  onMessage(event) {
    let message;
    try {
      message = JSON.parse(String(event.data));
    } catch {
      this.close();
      return;
    }
    if (!message?.id) return;
    const waiter = this.pending.get(message.id);
    if (!waiter) return;
    clearTimeout(waiter.timeout);
    this.pending.delete(message.id);
    if (message.error) {
      waiter.reject(new Error(`${message.error.message} (${message.error.code})`));
    } else {
      waiter.resolve(message.result);
    }
  }

  send(method, params = {}, timeoutMs = 10000) {
    if (this.closed) return Promise.reject(new Error("CDP session is closed"));
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
      }, timeoutMs);
      this.pending.set(id, { reject, resolve, timeout });
      try {
        this.socket.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  async evaluate(expression, timeoutMs = 10000) {
    const response = await this.send("Runtime.evaluate", {
      awaitPromise: true,
      expression,
      returnByValue: true,
      userGesture: false,
    }, timeoutMs);
    if (response.exceptionDetails) {
      const detail = response.exceptionDetails.exception?.description
        ?? response.exceptionDetails.text
        ?? "unknown renderer exception";
      throw new Error(`Renderer evaluation failed: ${detail}`);
    }
    return response.result?.value;
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    for (const waiter of this.pending.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(new Error("CDP session closed"));
    }
    this.pending.clear();
    try {
      this.socket.close();
    } catch {}
  }
}

async function listPageTargets(port) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2500);
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`, {
      redirect: "error",
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`CDP target list returned HTTP ${response.status}`);
    const targets = await response.json();
    if (!Array.isArray(targets)) throw new Error("CDP target list is not an array");
    return targets.filter((target) => isValidCdpPageTarget(target, port));
  } finally {
    clearTimeout(timeout);
  }
}

function probeExpression(selectorContract) {
  const selectors = selectorContract.selectors.map(({ key, selector, required }) => ({
    key,
    required: Boolean(required),
    selector,
  }));
  return `(() => {
    const entries = ${JSON.stringify(selectors)};
    const markers = Object.fromEntries(entries.map((entry) => {
      try {
        return [entry.key, Boolean(document.querySelector(entry.selector))];
      } catch {
        return [entry.key, false];
      }
    }));
    const href = location.href;
    let allowed = false;
    try {
      const url = new URL(href);
      allowed = ((url.protocol === "doubao:" || url.protocol === "chrome:") &&
        url.hostname === "doubao-chat" &&
        (url.pathname === "/chat" || url.pathname.startsWith("/chat/"))) ||
        (url.protocol === "https:" && url.hostname === "www.doubao.com" &&
        (url.pathname === "/chat" || url.pathname.startsWith("/chat/")));
    } catch {}
    return {
      allowed,
      doubao: allowed && markers.shell && (markers.sidebar || markers.composer),
      href,
      markers,
      readyState: document.readyState,
      title: document.title,
    };
  })()`;
}

async function waitForProbe(session, selectorContract, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let probe = null;
  while (Date.now() < deadline) {
    probe = await session.evaluate(probeExpression(selectorContract));
    if (probe?.doubao) return probe;
    await sleep(100);
  }
  return probe;
}

async function connectDoubaoTargets(port, timeoutMs, selectorContract) {
  const deadline = Date.now() + timeoutMs;
  let lastError = new Error("No matching page target appeared");

  while (Date.now() < deadline) {
    try {
      const targets = await listPageTargets(port);
      const connected = [];
      for (const target of targets) {
        let session = null;
        try {
          session = await new CdpSession(target, port).open();
          const probe = await waitForProbe(
            session,
            selectorContract,
            Math.min(5000, Math.max(500, deadline - Date.now())),
          );
          if (probe?.doubao) connected.push({ probe, session, target });
          else session.close();
        } catch (error) {
          session?.close();
          lastError = error;
        }
      }
      if (connected.length) return connected;
      lastError = new Error("No page matched the expected Doubao shell markers");
    } catch (error) {
      lastError = error;
    }
    await sleep(300);
  }
  throw new Error(
    `No verified Doubao renderer on 127.0.0.1:${port}: ${lastError.message}`,
  );
}

function validateSelectorContract(contract) {
  if (contract?.schema !== "doubao-skin-selectors/1" || !Array.isArray(contract.selectors)) {
    throw new Error("assets/selectors.json has an unsupported schema");
  }
  const keys = new Set();
  for (const entry of contract.selectors) {
    if (
      typeof entry?.key !== "string"
      || typeof entry.selector !== "string"
      || keys.has(entry.key)
    ) {
      throw new Error(`Invalid selector contract entry: ${entry?.key ?? "<missing>"}`);
    }
    keys.add(entry.key);
  }
  for (const required of ["shell", "sidebar"]) {
    if (!keys.has(required)) throw new Error(`Selector contract is missing ${required}`);
  }
  return contract;
}

export function validateTheme(theme) {
  if (
    theme?.schemaVersion !== 1
    || typeof theme.id !== "string"
    || !/^[a-z0-9][a-z0-9-]{0,79}$/i.test(theme.id)
    || typeof theme.name !== "string"
    || !theme.name.trim()
    || typeof theme.colors !== "object"
    || !theme.colors
    || Array.isArray(theme.colors)
  ) {
    throw new Error("assets/theme.json has an unsupported schema");
  }
  const colorPattern = /^(#[0-9a-f]{6}|rgba?\([0-9., %]+\))$/i;
  for (const [name, value] of Object.entries(theme.colors)) {
    if (typeof value !== "string" || !colorPattern.test(value.trim())) {
      throw new Error(`Invalid theme color ${name}`);
    }
  }
  if (theme.composer !== undefined) {
    const requiredComposerColors = [
      "background",
      "backgroundAccent",
      "border",
      "iconFilter",
      "placeholder",
      "text",
      "toolbar",
    ];
    if (
      !theme.composer
      || typeof theme.composer !== "object"
      || Array.isArray(theme.composer)
      || requiredComposerColors.some((name) => !(name in theme.composer))
    ) {
      throw new Error("Invalid theme composer palette");
    }
    const iconFilterPattern = /^brightness\(0%\) saturate\(100%\) invert\([0-9]{1,3}%\) sepia\([0-9]{1,3}%\) saturate\([0-9]{1,5}%\) hue-rotate\(-?[0-9]{1,3}deg\) brightness\([0-9]{1,3}%\) contrast\([0-9]{1,3}%\)$/;
    for (const [name, value] of Object.entries(theme.composer)) {
      if (name === "iconFilter") {
        if (typeof value !== "string" || !iconFilterPattern.test(value.trim())) {
          throw new Error("Invalid composer iconFilter");
        }
        continue;
      }
      if (typeof value !== "string" || !colorPattern.test(value.trim())) {
        throw new Error(`Invalid composer color ${name}`);
      }
    }
  }
  if (theme.typography !== undefined) {
    const requiredTypographyColors = [
      "action",
      "disabled",
      "heading",
      "link",
      "muted",
      "primary",
      "secondary",
      "sidebar",
      "sidebarMuted",
      "subtle",
      "suggestion",
    ];
    if (
      !theme.typography
      || typeof theme.typography !== "object"
      || Array.isArray(theme.typography)
      || requiredTypographyColors.some((name) => !(name in theme.typography))
    ) {
      throw new Error("Invalid theme typography palette");
    }
    for (const [name, value] of Object.entries(theme.typography)) {
      if (typeof value !== "string" || !colorPattern.test(value.trim())) {
        throw new Error(`Invalid typography color ${name}`);
      }
    }
  }
  if (theme.surfaces !== undefined) {
    const requiredSurfaces = ["conversation", "menu"];
    if (
      !theme.surfaces
      || typeof theme.surfaces !== "object"
      || Array.isArray(theme.surfaces)
      || requiredSurfaces.some((name) => !(name in theme.surfaces))
    ) {
      throw new Error("Invalid theme surface palette");
    }
    for (const [name, value] of Object.entries(theme.surfaces)) {
      if (typeof value !== "string" || !colorPattern.test(value.trim())) {
        throw new Error(`Invalid surface color ${name}`);
      }
    }
  }
  if (
    theme.background !== undefined
    && (
      typeof theme.background !== "string"
      || !/^[A-Za-z0-9][A-Za-z0-9._-]*\.(png|jpe?g|webp)$/i.test(theme.background)
    )
  ) {
    throw new Error("Invalid preset background filename");
  }
  if (theme.decoration !== undefined) {
    const decoration = theme.decoration;
    const validText = (value, max = 40) => (
      typeof value === "string" && value.trim().length > 0 && value.length <= max
    );
    if (
      !decoration
      || typeof decoration !== "object"
      || Array.isArray(decoration)
      || !validText(decoration.title, 20)
      || (decoration.subtitle !== undefined && !validText(decoration.subtitle, 20))
      || (
        decoration.lines !== undefined
        && (
          !Array.isArray(decoration.lines)
          || decoration.lines.length > 5
          || decoration.lines.some((line) => !validText(line))
        )
      )
    ) {
      throw new Error("Invalid theme decoration");
    }
  }
  return theme;
}

function themePathForPreset(preset) {
  return preset
    ? path.join(presetsRoot, preset, "theme.json")
    : path.join(assetsRoot, "theme.json");
}

function presetBackgroundPath(preset, theme) {
  if (!preset || !theme.background) return null;
  const presetDir = path.join(presetsRoot, preset);
  const candidate = path.resolve(presetDir, theme.background);
  if (!candidate.startsWith(`${presetDir}${path.sep}`)) {
    throw new Error("Preset background escaped its preset directory");
  }
  return candidate;
}

async function resolveThemeSource({ preset = null, themeDir = null } = {}) {
  if (!themeDir) {
    const themePath = themePathForPreset(preset);
    return {
      directory: path.dirname(themePath),
      themePath,
    };
  }
  const requested = path.resolve(themeDir);
  const requestedStat = await fs.lstat(requested);
  if (requestedStat.isSymbolicLink()) {
    throw new Error("Theme directory cannot be a symbolic link");
  }
  const canonical = await fs.realpath(requested);
  const canonicalStat = await fs.stat(canonical);
  if (!canonicalStat.isDirectory()) throw new Error("Theme path must be a directory");
  return {
    directory: canonical,
    themePath: path.join(canonical, "theme.json"),
  };
}

function themeBackgroundPath(themeDirectory, theme) {
  if (!theme.background) return null;
  const candidate = path.resolve(themeDirectory, theme.background);
  if (!candidate.startsWith(`${themeDirectory}${path.sep}`)) {
    throw new Error("Theme background escaped its theme directory");
  }
  return candidate;
}

async function readOptionalBackground(backgroundPath) {
  if (!backgroundPath) {
    return {
      asset: null,
      bytes: Buffer.alloc(0),
      sourcePath: null,
    };
  }
  const canonical = await fs.realpath(backgroundPath);
  const lstat = await fs.lstat(backgroundPath);
  if (lstat.isSymbolicLink()) throw new Error("Background image cannot be a symbolic link");
  const extension = path.extname(canonical).toLowerCase();
  const mime = extension === ".jpg" || extension === ".jpeg"
    ? "image/jpeg"
    : extension === ".png"
      ? "image/png"
      : extension === ".webp"
        ? "image/webp"
        : null;
  if (!mime) throw new Error("Background must be PNG, JPEG, or WebP");

  const handle = await fs.open(canonical, fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0));
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size < 1 || stat.size > MAX_BACKGROUND_BYTES) {
      throw new Error(`Background must be a non-empty file up to ${MAX_BACKGROUND_BYTES} bytes`);
    }
    const bytes = await handle.readFile();
    return {
      asset: {
        base64: bytes.toString("base64"),
        mime,
      },
      bytes,
      sourcePath: canonical,
    };
  } finally {
    await handle.close();
  }
}

export async function buildPayload({
  background = null,
  preset = null,
  themeDir = null,
} = {}) {
  if (preset !== null && !PRESET_ID.test(preset)) {
    throw new Error(`Invalid preset ID: ${preset || "<empty>"}`);
  }
  if (preset !== null && themeDir !== null) {
    throw new Error("--preset and --theme-dir cannot be used together");
  }
  const source = await resolveThemeSource({ preset, themeDir });
  const [css, template, rawTheme, rawSelectors] = await Promise.all([
    fs.readFile(path.join(assetsRoot, "doubao-skin.css"), "utf8"),
    fs.readFile(path.join(assetsRoot, "renderer-inject.js"), "utf8"),
    fs.readFile(source.themePath, "utf8"),
    fs.readFile(path.join(assetsRoot, "selectors.json"), "utf8"),
  ]);
  const theme = validateTheme(JSON.parse(rawTheme));
  const selectors = validateSelectorContract(JSON.parse(rawSelectors));
  const art = await readOptionalBackground(
    background || themeBackgroundPath(source.directory, theme),
  );
  const revision = createHash("sha256")
    .update(SKIN_VERSION)
    .update(css)
    .update(template)
    .update(JSON.stringify(theme))
    .update(JSON.stringify(selectors))
    .update(art.bytes)
    .digest("hex")
    .slice(0, 20);
  const payload = template
    .replace("__DOUBAO_SKIN_CSS_JSON__", JSON.stringify(css))
    .replace("__DOUBAO_SKIN_ART_JSON__", JSON.stringify(art.asset))
    .replace("__DOUBAO_SKIN_THEME_JSON__", JSON.stringify(theme))
    .replace("__DOUBAO_SKIN_SELECTORS_JSON__", JSON.stringify(selectors))
    .replace("__DOUBAO_SKIN_VERSION_JSON__", JSON.stringify(SKIN_VERSION))
    .replace("__DOUBAO_SKIN_REVISION_JSON__", JSON.stringify(revision));

  // Parse without executing to fail before attaching to the application.
  new Function(payload);
  return {
    backgroundBytes: art.bytes.length,
    backgroundPath: art.sourcePath,
    payload,
    preset,
    revision,
    selectors,
    themeDir: themeDir ? source.directory : null,
    theme,
  };
}

function verifyExpression(expectedRevision) {
  return `(() => {
    const state = window[${JSON.stringify(RUNTIME_STATE_KEY)}];
    const status = state?.status?.() ?? null;
    const pass = Boolean(
      status &&
      status.installed &&
      status.stylePresent &&
      status.decorationPresent !== false &&
      status.revision === ${JSON.stringify(expectedRevision)} &&
      status.missingRequired?.length === 0 &&
      status.visual?.backgroundSize
        ?.split(",")
        .every((value) => value.trim() === "cover") &&
      status.visual?.composer?.backgroundImage?.includes("linear-gradient") &&
      status.visual?.composer?.backdropFilter?.includes("blur(18px)") &&
      status.visual?.composer?.nativeInnerSurface?.present === true &&
      status.visual?.composer?.nativeInnerSurface?.transparent === true &&
      status.visual?.composer?.inputColor !== "missing" &&
      Number.isInteger(status.visual?.composer?.actionButtons?.count) &&
      status.visual?.composer?.actionButtons?.unexpectedFilledCount === 0 &&
      status.visual?.composer?.icons?.iconFilter !== "missing" &&
      status.visual?.composer?.icons?.nativeBlackVectorPaintCount === 0 &&
      status.visual?.composer?.icons?.untintedRasterIconCount === 0 &&
      (
        !status.visual?.conversation?.active ||
        (
          status.visual.conversation.surfaceBackgroundColor
            === status.visual.conversation.scrimToken &&
          status.visual.conversation.backdropFilter === "none" &&
          status.visual.conversation.messageListPresent === true &&
          status.visual.conversation.bottomFadePresent === true &&
          status.visual.conversation.bottomFadeBackgroundImage
            ?.includes("linear-gradient") &&
          !status.visual.conversation.bottomFadeBackgroundImage
            ?.includes("rgb(252, 252, 252)")
        )
      ) &&
      (
        !status.visual?.modeMenu?.open ||
        (
          status.visual.modeMenu.backgroundImage?.includes("linear-gradient") &&
          status.visual.modeMenu.backgroundImage
            ?.includes(status.visual.conversation.menuToken) &&
          status.visual.modeMenu.rasterIconCount > 0 &&
          status.visual.modeMenu.nativeBlackVectorPaintCount === 0 &&
          status.visual.modeMenu.untintedRasterIconCount === 0
        )
      ) &&
      (
        !status.visual?.moreMenu?.open ||
        (
          status.visual.moreMenu.backgroundImage?.includes("linear-gradient") &&
          status.visual.moreMenu.backgroundImage
            ?.includes(status.visual.conversation.menuToken) &&
          status.visual.moreMenu.itemCount === 3 &&
          status.visual.moreMenu.unexpectedFilledItemCount === 0 &&
          status.visual.moreMenu.rasterIconCount > 0 &&
          status.visual.moreMenu.nativeBlackVectorPaintCount === 0 &&
          status.visual.moreMenu.untintedRasterIconCount === 0
        )
      ) &&
      status.visual?.typography?.palette?.primary !== "missing" &&
      status.visual?.typography?.nativePrimary
        === status.visual?.typography?.palette?.primary &&
      status.visual?.typography?.nativeBlackTextCount === 0 &&
      document.documentElement.getAttribute("data-doubao-skin") === "active"
    );
    return { pass, status };
  })()`;
}

const removeExpression = `(() => {
  const key = ${JSON.stringify(RUNTIME_STATE_KEY)};
  const removed = window[key]?.cleanup?.() ?? false;
  document.getElementById("doubao-skin-poc-style")?.remove();
  document.getElementById("doubao-skin-poc-decoration")?.remove();
  const root = document.documentElement;
  root?.removeAttribute("data-doubao-skin");
  root?.removeAttribute("data-doubao-skin-theme");
  root?.removeAttribute("data-doubao-skin-has-art");
  return {
    removed,
    clean: !window[key] && root?.getAttribute("data-doubao-skin") !== "active",
    href: location.href,
  };
})()`;

async function captureScreenshot(session, outputPath) {
  await sleep(1800);
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  const result = await session.send("Page.captureScreenshot", {
    captureBeyondViewport: false,
    format: "png",
    fromSurface: true,
  }, 15000);
  if (typeof result?.data !== "string" || !result.data) {
    throw new Error("CDP returned an empty screenshot");
  }
  await fs.writeFile(outputPath, Buffer.from(result.data, "base64"), { mode: 0o600 });
}

function closeRecords(records) {
  for (const record of records) record.session.close();
}

async function runCheck(options) {
  const loaded = await buildPayload(options);
  process.stdout.write(`${JSON.stringify({
    backgroundBytes: loaded.backgroundBytes,
    backgroundPath: loaded.backgroundPath,
    payloadBytes: Buffer.byteLength(loaded.payload),
    preset: loaded.preset,
    revision: loaded.revision,
    selectorCount: loaded.selectors.selectors.length,
    themeDir: loaded.themeDir,
    themeId: loaded.theme.id,
    version: SKIN_VERSION,
  }, null, 2)}\n`);
}

async function runOnce(options) {
  const loaded = await buildPayload(options);
  const records = await connectDoubaoTargets(
    options.port,
    options.timeoutMs,
    loaded.selectors,
  );
  const results = [];
  try {
    for (const record of records) {
      const status = await record.session.evaluate(loaded.payload, 15000);
      results.push({ status, targetId: record.target.id });
    }
    if (options.screenshot) {
      await captureScreenshot(records[0].session, options.screenshot);
    }
  } finally {
    closeRecords(records);
  }
  if (!results.some((entry) => entry.status?.installed)) {
    throw new Error("Doubao renderer did not confirm skin installation");
  }
  process.stdout.write(`${JSON.stringify({
    appliedTargets: results.length,
    revision: loaded.revision,
    screenshot: options.screenshot,
    themeId: loaded.theme.id,
  }, null, 2)}\n`);
}

async function runVerify(options) {
  const loaded = await buildPayload(options);
  const records = await connectDoubaoTargets(
    options.port,
    options.timeoutMs,
    loaded.selectors,
  );
  const results = [];
  try {
    for (const record of records) {
      const result = await record.session.evaluate(verifyExpression(loaded.revision));
      results.push({
        href: record.probe.href,
        pass: Boolean(result?.pass),
        status: result?.status ?? null,
        targetId: record.target.id,
      });
    }
  } finally {
    closeRecords(records);
  }
  process.stdout.write(`${JSON.stringify({
    expectedRevision: loaded.revision,
    pass: results.length > 0 && results.every((entry) => entry.pass),
    results,
  }, null, 2)}\n`);
  if (!results.length || results.some((entry) => !entry.pass)) process.exitCode = 1;
}

async function runRemove(options) {
  const selectors = validateSelectorContract(JSON.parse(
    await fs.readFile(path.join(assetsRoot, "selectors.json"), "utf8"),
  ));
  const records = await connectDoubaoTargets(
    options.port,
    options.timeoutMs,
    selectors,
  );
  const results = [];
  try {
    for (const record of records) {
      const result = await record.session.evaluate(removeExpression);
      results.push({ ...result, targetId: record.target.id });
    }
  } finally {
    closeRecords(records);
  }
  const pass = results.length > 0 && results.every((entry) => entry.clean);
  process.stdout.write(`${JSON.stringify({ pass, results }, null, 2)}\n`);
  if (!pass) process.exitCode = 1;
}

async function sourceFingerprint(options) {
  const source = await resolveThemeSource(options);
  const themePath = source.themePath;
  const paths = [
    path.join(assetsRoot, "doubao-skin.css"),
    path.join(assetsRoot, "renderer-inject.js"),
    themePath,
    path.join(assetsRoot, "selectors.json"),
  ];
  if (options.background) {
    paths.push(options.background);
  } else {
    try {
      const theme = validateTheme(JSON.parse(await fs.readFile(themePath, "utf8")));
      const themeBackground = themeBackgroundPath(source.directory, theme);
      if (themeBackground) paths.push(themeBackground);
    } catch {}
  }
  const parts = [];
  for (const source of paths) {
    try {
      const stat = await fs.stat(source);
      parts.push(`${source}:${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}`);
    } catch (error) {
      parts.push(`${source}:missing:${error.code ?? "error"}`);
    }
  }
  return parts.join("|");
}

function installedRevisionExpression(expectedRevision) {
  return `(() => {
    const state = window[${JSON.stringify(RUNTIME_STATE_KEY)}];
    if (
      state?.revision !== ${JSON.stringify(expectedRevision)}
      || typeof state.ensure !== "function"
    ) {
      return null;
    }
    const installed = Boolean(state.ensure());
    return {
      href: location.href,
      installed,
      revision: state.revision,
    };
  })()`;
}

async function runWatch(options) {
  let stopping = false;
  let loaded = await buildPayload(options);
  let fingerprint = await sourceFingerprint(options);
  const announced = new Map();
  const stop = () => {
    stopping = true;
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  process.stdout.write(
    `[doubao-skin] watching 127.0.0.1:${options.port}, revision ${loaded.revision}\n`,
  );

  while (!stopping) {
    try {
      const nextFingerprint = await sourceFingerprint(options);
      if (nextFingerprint !== fingerprint) {
        loaded = await buildPayload(options);
        fingerprint = nextFingerprint;
        announced.clear();
        process.stdout.write(`[doubao-skin] theme reloaded: ${loaded.revision}\n`);
      }

      const records = await connectDoubaoTargets(options.port, 2500, loaded.selectors);
      try {
        for (const record of records) {
          let status = await record.session.evaluate(
            installedRevisionExpression(loaded.revision),
          );
          if (!status?.installed) {
            status = await record.session.evaluate(loaded.payload, 15000);
          }
          if (status?.installed && announced.get(record.target.id) !== loaded.revision) {
            announced.set(record.target.id, loaded.revision);
            process.stdout.write(
              `[doubao-skin] applied ${loaded.theme.id} to ${status.href}\n`,
            );
          }
        }
        const activeIds = new Set(records.map((record) => record.target.id));
        for (const targetId of announced.keys()) {
          if (!activeIds.has(targetId)) announced.delete(targetId);
        }
      } finally {
        closeRecords(records);
      }
    } catch (error) {
      if (!stopping && !String(error?.message).includes("No verified Doubao renderer")) {
        process.stderr.write(`[doubao-skin] watch warning: ${error.message}\n`);
      }
    }
    if (!stopping) await sleep(1500);
  }
}

export async function main(argv = process.argv.slice(2)) {
  if (typeof WebSocket !== "function") {
    throw new Error("This PoC requires Node.js 22 or newer with global WebSocket support");
  }
  const options = parseArgs(argv);
  if (options.mode === "check") await runCheck(options);
  else if (options.mode === "once") await runOnce(options);
  else if (options.mode === "verify") await runVerify(options);
  else if (options.mode === "remove") await runRemove(options);
  else await runWatch(options);
}

if (process.argv[1] && path.resolve(process.argv[1]) === scriptPath) {
  main().catch((error) => {
    process.stderr.write(`Doubao Skin: ${error.stack ?? error.message}\n`);
    process.exitCode = 1;
  });
}
