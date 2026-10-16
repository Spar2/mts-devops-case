/** Illustrative reference reading of one cable. Not a measurement and not a score. */

export const PIPELINE_STAGES = ["field", "median", "background", "contrast", "region"] as const;
export type PipelineStage = (typeof PIPELINE_STAGES)[number];

export const STAGE_MS = 4000;
export const WALK_DURATION_MS = PIPELINE_STAGES.length * STAGE_MS;
export const COLS = 36;
export const ROWS = 12;
export const FIELD_W = 768;
export const ROW_H = 22;
export const GAP_H = 36;
export const PAD = 10;

const GAP_ROWS = new Set([5, 6]);
const HOLES = new Set(["2:10", "8:34"]);
const SPARK = { row: 8, col: 3 };
const PATCH = { c0: 16, c1: 22, r0: 1, r1: 5 };
const BROAD = { c0: 6, c1: 32 };
const MISSING = -1;
const RESIDUAL_HOT = 0.28;

export const STAGE_COPY: readonly { id: PipelineStage; kicker: string; name: string; hint: string; text: string }[] = [
  {
    id: "field",
    kicker: "01",
    name: "Измерение",
    hint: "Температура вдоль волокна",
    text: "Каждая ячейка — температура в одной точке кабеля в один момент. Здесь показаны общий прогрев, локальный нагрев и одиночный выброс. Серые ячейки и разрыв — отсутствие данных.",
  },
  {
    id: "median",
    kicker: "02",
    name: "Сглаживание",
    hint: "Медиана трёх точек",
    text: "Заменяем значение медианой трёх соседних точек вдоль кабеля. В этом примере одиночный выброс исчезает, а более широкий нагретый участок сохраняется. Пропуски не заполняем.",
  },
  {
    id: "background",
    kicker: "03",
    name: "Оценка фона",
    hint: "Сравнение с окружением",
    text: "Для каждой точки оцениваем обычный уровень температуры по более удалённым соседям. Саму точку и ближайшую окрестность исключаем. Рамки слева показывают, откуда берём фон для отмеченной точки.",
  },
  {
    id: "contrast",
    kicker: "04",
    name: "Превышение фона",
    hint: "Что нагрето сильнее",
    text: "Вычитаем фон из сглаженной температуры. Общий прогрев в этом примере почти не даёт превышения, а локально нагретый участок остаётся заметным. Теперь цвет показывает превышение фона, а не температуру.",
  },
  {
    id: "region",
    kicker: "05",
    name: "Проверка участка",
    hint: "Следующий шаг — эксперт",
    text: "Выделяем связный участок с заметным превышением фона. Его положение и длительность помогают эксперту продолжить разбор. По одному температурному отклонению нельзя установить причину нагрева.",
  },
];

export const WALK_INTRO = "Кабель может прогреться целиком, а одна точка — дать случайный выброс. Посмотрите, как обработка помогает выделить локальный нагрев для проверки экспертом.";
export const WALK_NOTE = "Учебный пример на условных данных. Показаны сглаживание и сравнение с фоном, без расчёта Z-оценки и рабочих порогов. Это не результат обработки записи выше.";

export type PipelineFrame = {
  stage: PipelineStage;
  index: number;
  progress: number;
  blend: number;
  box: number;
  revealed: number;
  reducedMotion: boolean;
};

export function smoothstep(value: number) {
  const x = Math.min(1, Math.max(0, value));
  return x * x * (3 - 2 * x);
}

export function pipelineFrame(elapsedMs: number, reducedMotion: boolean): PipelineFrame {
  const t = Number.isFinite(elapsedMs) ? Math.min(WALK_DURATION_MS, Math.max(0, elapsedMs)) : WALK_DURATION_MS;
  const index = Math.min(PIPELINE_STAGES.length - 1, Math.floor(t / STAGE_MS));
  const progress = (t - index * STAGE_MS) / STAGE_MS;
  const blend = reducedMotion ? 1 : smoothstep(progress);
  return {
    stage: PIPELINE_STAGES[index],
    index,
    progress,
    blend,
    box: index === 4 ? (reducedMotion ? 1 : smoothstep(progress / 0.3)) : 0,
    revealed: index + 1,
    reducedMotion,
  };
}

function rawAt(col: number, row: number) {
  if (row < 0 || col < 0 || row >= ROWS || col >= COLS) return MISSING;
  if (GAP_ROWS.has(row) || HOLES.has(`${row}:${col}`)) return MISSING;
  if (row === SPARK.row && col === SPARK.col) return 1;
  if (row >= PATCH.r0 && row < PATCH.r1 && col >= PATCH.c0 && col < PATCH.c1) return 0.92;
  if (col >= BROAD.c0 && col < BROAD.c1) return 0.42;
  return 0.16;
}

function medianOf(values: number[]) {
  const live = values.filter((value) => value >= 0).sort((a, b) => a - b);
  if (!live.length) return MISSING;
  const mid = Math.floor(live.length / 2);
  return live.length % 2 ? live[mid] : (live[mid - 1] + live[mid]) / 2;
}

function medianAt(col: number, row: number) {
  const here = rawAt(col, row);
  if (here < 0) return MISSING;
  return medianOf([rawAt(col - 1, row), here, rawAt(col + 1, row)]);
}

function backgroundAt(col: number, row: number) {
  if (medianAt(col, row) < 0) return MISSING;
  const samples: number[] = [];
  for (let distance = 3; distance <= 8; distance += 1) {
    samples.push(medianAt(col - distance, row), medianAt(col + distance, row));
  }
  return medianOf(samples);
}

const rawGrid = Array.from({ length: ROWS }, (_, row) => Array.from({ length: COLS }, (_, col) => rawAt(col, row)));
const medianGrid = Array.from({ length: ROWS }, (_, row) => Array.from({ length: COLS }, (_, col) => medianAt(col, row)));
const backgroundGrid = Array.from({ length: ROWS }, (_, row) => Array.from({ length: COLS }, (_, col) => backgroundAt(col, row)));

export function rawValue(col: number, row: number) {
  return rawGrid[row][col];
}

export function medianValue(col: number, row: number) {
  return medianGrid[row][col];
}

export function backgroundValue(col: number, row: number) {
  return backgroundGrid[row][col];
}

export function residualValue(col: number, row: number) {
  const median = medianGrid[row][col];
  const background = backgroundGrid[row][col];
  if (median < 0 || background < 0) return MISSING;
  return median - background;
}

function clamp01(value: number) {
  return Math.min(1, Math.max(0, value));
}

function temperatureTone(value: number) {
  if (value >= 0.75) return 1;
  if (value >= 0.3) return 0.5;
  return 0;
}

export function neighborBands() {
  const point = PATCH.c0 + 2;
  return {
    point,
    left0: point - 8,
    left1: point - 2,
    right0: point + 3,
    right1: point + 9,
    r0: 2,
    r1: 3,
  };
}

function residualTone(col: number, row: number) {
  const residual = residualValue(col, row);
  if (!(residual > 0)) return 0;
  const tone = clamp01(residual / 0.5);
  return tone < 0.35 ? 0 : tone;
}

function mix(from: number, to: number, amount: number) {
  return from + (to - from) * amount;
}

export function displayCell(col: number, row: number, frame: PipelineFrame) {
  const raw = rawGrid[row][col];
  if (raw < 0) return { missing: true, tone: 0 };
  const rawTone = temperatureTone(raw);
  const medianTone = temperatureTone(medianGrid[row][col]);
  const backgroundTone = temperatureTone(backgroundGrid[row][col]);
  const contrastTone = residualTone(col, row);
  if (frame.stage === "field") return { missing: false, tone: rawTone };
  if (frame.stage === "median") {
    const cursor = frame.blend * COLS;
    return { missing: false, tone: mix(rawTone, medianTone, smoothstep(cursor - col)) };
  }
  if (frame.stage === "background") return { missing: false, tone: mix(medianTone, backgroundTone, frame.blend) };
  if (frame.stage === "contrast") return { missing: false, tone: mix(backgroundTone, contrastTone, frame.blend) };
  return { missing: false, tone: contrastTone };
}

export function rowTop(row: number) {
  if (GAP_ROWS.has(row)) return null;
  const earlierGaps = [...GAP_ROWS].filter((gap) => gap < row).length;
  const dataIndex = row - earlierGaps;
  return PAD + dataIndex * ROW_H + (earlierGaps ? GAP_H : 0);
}

export const FIELD_H = PAD + (ROWS - GAP_ROWS.size) * ROW_H + GAP_H + PAD;

export function zoneRect() {
  let c0 = COLS;
  let c1 = 0;
  let r0 = ROWS;
  let r1 = 0;
  let count = 0;
  for (let row = 0; row < ROWS; row += 1) {
    for (let col = 0; col < COLS; col += 1) {
      if (residualValue(col, row) < RESIDUAL_HOT) continue;
      count += 1;
      c0 = Math.min(c0, col);
      c1 = Math.max(c1, col + 1);
      r0 = Math.min(r0, row);
      r1 = Math.max(r1, row + 1);
    }
  }
  if (!count) return null;
  return { c0, c1, r0, r1, count };
}
