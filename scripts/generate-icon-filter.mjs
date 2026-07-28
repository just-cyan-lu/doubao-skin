#!/usr/bin/env node

const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));

function parseHexColor(value) {
  const match = /^#([0-9a-f]{6})$/i.exec(value);
  if (!match) throw new Error("Expected a six-digit hex color such as #405943");
  return [
    Number.parseInt(match[1].slice(0, 2), 16),
    Number.parseInt(match[1].slice(2, 4), 16),
    Number.parseInt(match[1].slice(4, 6), 16),
  ];
}

function multiply(color, matrix) {
  const [red, green, blue] = color;
  return [
    clamp(red * matrix[0] + green * matrix[1] + blue * matrix[2], 0, 255),
    clamp(red * matrix[3] + green * matrix[4] + blue * matrix[5], 0, 255),
    clamp(red * matrix[6] + green * matrix[7] + blue * matrix[8], 0, 255),
  ];
}

function applyFilter(parameters) {
  const [invert, sepia, saturation, hue, brightness, contrast] = parameters;

  // The emitted filter first normalizes every source pixel to black. This
  // simulation therefore starts at black and models the remaining functions.
  let color = [255 * invert, 255 * invert, 255 * invert];

  const identity = [
    1, 0, 0,
    0, 1, 0,
    0, 0, 1,
  ];
  const sepiaMatrix = [
    0.393, 0.769, 0.189,
    0.349, 0.686, 0.168,
    0.272, 0.534, 0.131,
  ];
  color = multiply(
    color,
    identity.map((entry, index) => entry * (1 - sepia) + sepiaMatrix[index] * sepia),
  );

  color = multiply(color, [
    0.213 + 0.787 * saturation,
    0.715 - 0.715 * saturation,
    0.072 - 0.072 * saturation,
    0.213 - 0.213 * saturation,
    0.715 + 0.285 * saturation,
    0.072 - 0.072 * saturation,
    0.213 - 0.213 * saturation,
    0.715 - 0.715 * saturation,
    0.072 + 0.928 * saturation,
  ]);

  const radians = hue * Math.PI / 180;
  const cosine = Math.cos(radians);
  const sine = Math.sin(radians);
  color = multiply(color, [
    0.213 + cosine * 0.787 - sine * 0.213,
    0.715 - cosine * 0.715 - sine * 0.715,
    0.072 - cosine * 0.072 + sine * 0.928,
    0.213 - cosine * 0.213 + sine * 0.143,
    0.715 + cosine * 0.285 + sine * 0.140,
    0.072 - cosine * 0.072 - sine * 0.283,
    0.213 - cosine * 0.213 - sine * 0.787,
    0.715 - cosine * 0.715 + sine * 0.715,
    0.072 + cosine * 0.928 + sine * 0.072,
  ]);

  color = color.map((channel) => clamp(channel * brightness, 0, 255));
  return color.map((channel) => clamp(
    channel * contrast + 128 * (1 - contrast),
    0,
    255,
  ));
}

function loss(parameters, target) {
  const actual = applyFilter(parameters);
  return actual.reduce((total, channel, index) => {
    const difference = channel - target[index];
    return total + difference * difference;
  }, 0);
}

function seededRandom(seed) {
  let state = seed >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let value = state;
    value = Math.imul(value ^ value >>> 15, value | 1);
    value ^= value + Math.imul(value ^ value >>> 7, value | 61);
    return ((value ^ value >>> 14) >>> 0) / 4294967296;
  };
}

const LIMITS = [
  [0, 1],
  [0, 1],
  [0, 60],
  [-180, 180],
  [0, 2],
  [0, 2],
];

function bounded(parameters) {
  return parameters.map((value, index) => clamp(value, ...LIMITS[index]));
}

export function solveIconFilter(hexColor) {
  const target = parseHexColor(hexColor);
  const seed = target.reduce((value, channel) => (value * 257 + channel) >>> 0, 0x405943);
  const random = seededRandom(seed);
  let best = {
    loss: Number.POSITIVE_INFINITY,
    parameters: [0.4, 0.5, 8, 0, 1, 1],
  };

  const remember = (parameters) => {
    const candidate = bounded(parameters);
    const candidateLoss = loss(candidate, target);
    if (candidateLoss < best.loss) best = { loss: candidateLoss, parameters: candidate };
    return { loss: candidateLoss, parameters: candidate };
  };

  // Deterministic random restarts cover the non-linear filter space; a short
  // annealing pass after each restart converges on muted and saturated colors.
  for (let restart = 0; restart < 24; restart += 1) {
    let current = remember([
      0.08 + random() * 0.72,
      random(),
      0.25 + random() * 35,
      -180 + random() * 360,
      0.45 + random() * 1.35,
      0.45 + random() * 1.35,
    ]);

    for (let iteration = 0; iteration < 3600; iteration += 1) {
      const progress = iteration / 3600;
      const temperature = Math.max(0.008, 1 - progress);
      const scales = [0.11, 0.15, 7, 48, 0.24, 0.24];
      const candidate = bounded(current.parameters.map((value, index) => (
        value + (random() + random() + random() - 1.5) * scales[index] * temperature
      )));
      const candidateLoss = loss(candidate, target);
      const acceptance = Math.exp(
        (Math.sqrt(current.loss) - Math.sqrt(candidateLoss)) / (8 * temperature),
      );
      if (candidateLoss < current.loss || random() < acceptance) {
        current = { loss: candidateLoss, parameters: candidate };
        if (candidateLoss < best.loss) best = current;
      }
    }
  }

  // Coordinate refinement makes the rounded CSS output stable and precise.
  let steps = [0.03, 0.04, 1.5, 8, 0.04, 0.04];
  for (let round = 0; round < 80; round += 1) {
    let improved = false;
    for (let index = 0; index < best.parameters.length; index += 1) {
      for (const direction of [-1, 1]) {
        const candidate = [...best.parameters];
        candidate[index] += direction * steps[index];
        const before = best.loss;
        remember(candidate);
        if (best.loss < before) improved = true;
      }
    }
    if (!improved) steps = steps.map((value) => value * 0.72);
  }

  const rounded = [
    Math.round(best.parameters[0] * 100),
    Math.round(best.parameters[1] * 100),
    Math.round(best.parameters[2] * 100),
    Math.round(best.parameters[3]),
    Math.round(best.parameters[4] * 100),
    Math.round(best.parameters[5] * 100),
  ];
  const filter = [
    "brightness(0%)",
    "saturate(100%)",
    `invert(${rounded[0]}%)`,
    `sepia(${rounded[1]}%)`,
    `saturate(${rounded[2]}%)`,
    `hue-rotate(${rounded[3]}deg)`,
    `brightness(${rounded[4]}%)`,
    `contrast(${rounded[5]}%)`,
  ].join(" ");
  const roundedParameters = [
    rounded[0] / 100,
    rounded[1] / 100,
    rounded[2] / 100,
    rounded[3],
    rounded[4] / 100,
    rounded[5] / 100,
  ];
  const actual = applyFilter(roundedParameters).map(Math.round);
  const error = Math.sqrt(loss(roundedParameters, target));

  return { actual, error, filter, target };
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  try {
    const result = solveIconFilter(process.argv[2] || "");
    console.log(result.filter);
    console.log(
      `target rgb(${result.target.join(", ")}), simulated rgb(${result.actual.join(", ")}), error ${result.error.toFixed(2)}`,
    );
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
