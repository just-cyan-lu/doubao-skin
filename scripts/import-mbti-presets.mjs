#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { solveIconFilter } from "./generate-icon-filter.mjs";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const presetsRoot = path.join(projectRoot, "presets");
const types = {
  enfj: ["热情真诚", "善于共情", "鼓舞他人"],
  enfp: ["充满好奇", "热情自由", "富有创意"],
  entj: ["目标明确", "果断自信", "善于统筹"],
  entp: ["思维敏捷", "勇于质疑", "点子丰富"],
  esfj: ["热心周到", "重视关系", "乐于助人"],
  esfp: ["活力四射", "享受当下", "感染他人"],
  estj: ["务实高效", "重视秩序", "执行有力"],
  estp: ["果断行动", "灵活应变", "敢于冒险"],
  infj: ["洞察深刻", "坚持理想", "温柔坚定"],
  infp: ["内心丰富", "敏感善良", "追求真理"],
  intj: ["独立思考", "长远规划", "追求卓越"],
  intp: ["好奇理性", "热爱分析", "探索本质"],
  isfj: ["细致可靠", "温暖体贴", "默默守护"],
  isfp: ["温柔随性", "感受细腻", "热爱美好"],
  istj: ["沉稳负责", "重视规则", "值得信赖"],
  istp: ["冷静务实", "擅长动手", "随机应变"],
};
const genders = ["boy", "girl"];

function parseArguments(argv) {
  let source = "";
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--source") {
      source = argv[index + 1] || "";
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${argument}`);
  }
  if (!source) {
    throw new Error(
      "Usage: node scripts/import-mbti-presets.mjs --source /absolute/path/to/presets",
    );
  }
  return { source: path.resolve(source) };
}

function parseHex(value) {
  const match = /^#([0-9a-f]{6})$/i.exec(value);
  if (!match) throw new Error(`Expected a six-digit hex color, received ${value}`);
  return [
    Number.parseInt(match[1].slice(0, 2), 16),
    Number.parseInt(match[1].slice(2, 4), 16),
    Number.parseInt(match[1].slice(4, 6), 16),
  ];
}

function toHex(channels) {
  return `#${channels
    .map((channel) => Math.round(channel).toString(16).padStart(2, "0"))
    .join("")}`;
}

function mixHex(left, right, rightWeight) {
  const leftChannels = parseHex(left);
  const rightChannels = parseHex(right);
  return toHex(leftChannels.map(
    (channel, index) => channel * (1 - rightWeight) + rightChannels[index] * rightWeight,
  ));
}

function rgba(hexColor, alpha) {
  const [red, green, blue] = parseHex(hexColor);
  return `rgba(${red}, ${green}, ${blue}, ${alpha.toFixed(2)})`;
}

function splitDisplayName(sourceTheme) {
  const [title, subtitle] = String(sourceTheme.displayName || "")
    .split("·")
    .map((part) => part.trim());
  if (!title || !subtitle) {
    throw new Error(`Invalid MBTI displayName in ${sourceTheme.id}`);
  }
  return { subtitle, title };
}

function generatedTheme(sourceTheme, gender, type) {
  const palette = sourceTheme.colors;
  const dark = sourceTheme.appearance === "dark";
  const { subtitle, title } = splitDisplayName(sourceTheme);
  const toolbar = dark
    ? mixHex(palette.text, palette.accentAlt, 0.22)
    : mixHex(palette.text, palette.accent, 0.25);
  const directory = `mbti-${gender}-${type}`;

  return {
    $schema: "../../assets/theme.schema.json",
    schemaVersion: 1,
    id: directory,
    name: sourceTheme.name,
    background: "background.jpg",
    surfaces: {
      conversation: rgba(dark ? palette.panel : palette.panel, dark ? 0.76 : 0.66),
      menu: rgba(palette.panel, dark ? 0.96 : 0.94),
    },
    decoration: {
      title,
      subtitle,
      lines: types[type],
    },
    composer: {
      text: palette.text,
      placeholder: palette.muted,
      toolbar,
      iconFilter: solveIconFilter(toolbar).filter,
      background: dark ? rgba(palette.panel, 0.72) : "rgba(255, 255, 255, 0.58)",
      backgroundAccent: dark
        ? rgba(palette.panel, 0.72)
        : "rgba(255, 255, 255, 0.58)",
      border: palette.line,
    },
    typography: {
      primary: palette.text,
      secondary: mixHex(palette.text, palette.muted, 0.44),
      muted: palette.muted,
      subtle: rgba(palette.muted, 0.72),
      disabled: rgba(palette.muted, 0.44),
      heading: dark ? palette.text : mixHex(palette.text, palette.accent, 0.10),
      sidebar: palette.text,
      sidebarMuted: palette.muted,
      suggestion: dark
        ? mixHex(palette.text, palette.muted, 0.32)
        : mixHex(palette.text, palette.accent, 0.18),
      action: toolbar,
      link: dark ? palette.accentAlt : mixHex(palette.text, palette.accent, 0.58),
    },
    colors: {
      accent: palette.accent,
      accentSoft: palette.accentAlt,
      cyan: palette.secondary,
      pink: palette.highlight,
      text: palette.text,
      muted: palette.muted,
      panel: rgba(palette.panel, dark ? 0.72 : 0.64),
      panelStrong: rgba(dark ? palette.panelAlt : palette.panel, dark ? 0.88 : 0.84),
      line: palette.line,
    },
  };
}

async function removeStaleBackgrounds(targetDirectory, keepName) {
  for (const filename of [
    "background.png",
    "background.jpeg",
    "background.webp",
  ]) {
    if (filename === keepName) continue;
    await fs.rm(path.join(targetDirectory, filename), { force: true });
  }
}

async function loadJson(filename) {
  return JSON.parse(await fs.readFile(filename, "utf8"));
}

async function importPreset(sourceRoot, gender, type, infpBase) {
  const sourceDirectory = path.join(sourceRoot, `preset-mbti-${gender}-${type}`);
  const sourceTheme = await loadJson(path.join(sourceDirectory, "theme.json"));
  if (sourceTheme.gender !== gender || sourceTheme.id !== `preset-mbti-${gender}-${type}`) {
    throw new Error(`Source identity mismatch in ${sourceDirectory}`);
  }

  const isDefaultInfp = gender === "boy" && type === "infp";
  const targetName = `mbti-${gender}-${type}`;
  const targetDirectory = path.join(presetsRoot, targetName);
  const theme = isDefaultInfp
    ? {
        ...infpBase,
        id: targetName,
        name: sourceTheme.name,
        background: "background.jpg",
      }
    : generatedTheme(sourceTheme, gender, type);

  await fs.mkdir(targetDirectory, { recursive: true });
  await fs.copyFile(
    path.join(sourceDirectory, "background.jpg"),
    path.join(targetDirectory, "background.jpg"),
  );
  await removeStaleBackgrounds(targetDirectory, "background.jpg");
  await fs.writeFile(
    path.join(targetDirectory, "theme.json"),
    `${JSON.stringify(theme, null, 2)}\n`,
    "utf8",
  );
  return {
    source: sourceTheme.id,
    target: targetName,
    themeId: theme.id,
  };
}

async function main() {
  const { source } = parseArguments(process.argv.slice(2));
  const infpBase = await loadJson(
    path.join(presetsRoot, "mbti-boy-infp", "theme.json"),
  );
  const imported = [];

  for (const gender of genders) {
    for (const type of Object.keys(types).sort()) {
      imported.push(await importPreset(source, gender, type, infpBase));
    }
  }

  console.log(JSON.stringify({
    count: imported.length,
    imported,
    source,
  }, null, 2));
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
