import { useEffect, useRef, useState } from "react";
import { useInView } from "motion/react";
import {
  COLS, displayCell, FIELD_H, FIELD_W, GAP_H, WALK_DURATION_MS, neighborBands,
  PAD, pipelineFrame, ROWS, rowTop, ROW_H, STAGE_COPY, STAGE_MS,
  WALK_INTRO, WALK_NOTE, zoneRect, type PipelineFrame,
} from "./pipeline-frame";

const CELLS = Array.from({ length: ROWS }, (_, row) =>
  Array.from({ length: COLS }, (_, col) => ({ row, col })),
).flat();
const TITLES = ["Исходное поле", "После сглаживания", "Оценка температурного фона", "Превышение фона", "Участок для проверки"];
const INITIAL = pipelineFrame(0, false);
const ZONE = zoneRect();
const BANDS = neighborBands();
const BREAK_TOP = ((rowTop(4)! + ROW_H + GAP_H / 2) / FIELD_H) * 100;
const cellX = (col: number) => col * FIELD_W / COLS;
const CELL_W = FIELD_W / COLS;
const reducedPreference = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function cellFill(missing: boolean, tone: number) {
  if (missing) return "url(#walk-missing)";
  const low = tone < .5 ? "var(--walk-paper)" : "var(--walk-warm)";
  const high = tone < .5 ? "var(--walk-warm)" : "var(--walk-hot)";
  return `color-mix(in srgb, ${high} ${Math.min(100, Math.max(0, (tone < .5 ? tone * 2 : (tone-.5)*2) * 100))}%, ${low})`;
}

function cells(frame: PipelineFrame) {
  return CELLS.map(({ row, col }) => {
    const y = rowTop(row);
    if (y === null) return null;
    const cell = displayCell(col, row, frame);
    return <rect key={`${row}-${col}`} x={cellX(col)+.6} y={y} width={CELL_W-1.2} height={ROW_H-1.2} fill={cellFill(cell.missing, cell.tone)} />;
  });
}
const ORIGINAL_CELLS = cells(INITIAL);

function Field({ scene, original = false }: { scene: PipelineFrame; original?: boolean }) {
  const background = scene.stage === "background";
  const windowCol = Math.max(0, Math.min(COLS-3, scene.blend*COLS-1));
  return <div className="lp-walk-frame">
    <svg className="lp-walk-svg" viewBox={`0 0 ${FIELD_W} ${FIELD_H}`} preserveAspectRatio="none" role="img"
      aria-label={original ? "Исходное учебное поле. Горизонталь — расстояние, вертикаль — время." : TITLES[scene.index]}>
      {original && <defs><pattern id="walk-missing" width="8" height="8" patternUnits="userSpaceOnUse"><rect width="8" height="8" fill="var(--walk-gap)"/><path d="M-2 2L2-2M0 8L8 0M6 10L10 6" stroke="var(--dts-page-background)" strokeWidth="2"/></pattern></defs>}
      {original ? ORIGINAL_CELLS : cells(scene)}
      {original && background && <g className="lp-walk-halo" stroke="var(--cds-text-primary)" strokeWidth="3">
        <rect x={cellX(BANDS.left0)} y={rowTop(BANDS.r0)!-2} width={CELL_W*(BANDS.left1-BANDS.left0)} height={ROW_H+3} fill="var(--walk-selection)"/>
        <rect x={cellX(BANDS.right0)} y={rowTop(BANDS.r0)!-2} width={CELL_W*(BANDS.right1-BANDS.right0)} height={ROW_H+3} fill="var(--walk-selection)"/>
        <rect x={cellX(BANDS.left1)} y={rowTop(BANDS.r0)!-2} width={CELL_W*(BANDS.right0-BANDS.left1)} height={ROW_H+3} fill="none" strokeDasharray="5 4"/>
        <circle cx={cellX(BANDS.point+.5)} cy={rowTop(BANDS.r0)!+ROW_H/2} r="5" fill="var(--cds-text-primary)"/>
      </g>}
      {!original && scene.stage === "median" && !scene.reducedMotion && <rect x={cellX(windowCol)} y={PAD} width={CELL_W*3} height={FIELD_H-PAD*2} fill="var(--walk-selection)" stroke="var(--cds-text-primary)" strokeWidth="2"/>}
      {!original && ZONE && scene.box > 0 && <rect x={cellX(ZONE.c0)-2} y={rowTop(ZONE.r0)!-3} width={CELL_W*(ZONE.c1-ZONE.c0)+3} height={rowTop(ZONE.r1-1)!+ROW_H-rowTop(ZONE.r0)!+5} fill="none" stroke="var(--cds-text-primary)" strokeWidth="3" opacity={scene.box}/>}
    </svg>
    <span className="lp-walk-break" style={{ top: `${BREAK_TOP}%` }}>Нет данных во времени</span>
  </div>;
}

export default function PipelineWalk() {
  const playbackArea = useRef<HTMLElement>(null);
  const [reduced, setReduced] = useState(reducedPreference);
  const [elapsed, setElapsed] = useState(() => reducedPreference() ? WALK_DURATION_MS : 0);
  const clock = useRef(elapsed);
  const [playing, setPlaying] = useState(() => !reducedPreference());
  const [visible, setVisible] = useState(() => !document.hidden);
  const inView = useInView(playbackArea, { amount: .5 });

  useEffect(() => {
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const changed = () => { setReduced(media.matches); if (media.matches) setPlaying(false); };
    const visibility = () => setVisible(!document.hidden);
    media.addEventListener("change", changed);
    document.addEventListener("visibilitychange", visibility);
    return () => { media.removeEventListener("change", changed); document.removeEventListener("visibilitychange", visibility); };
  }, []);

  useEffect(() => {
    if (!playing || reduced || !inView || !visible) return;
    let raf = 0, last: number | null = null;
    const tick = (now: number) => {
      if (last !== null) clock.current = Math.min(WALK_DURATION_MS, clock.current+now-last);
      last = now;
      setElapsed(clock.current);
      if (clock.current >= WALK_DURATION_MS) { setPlaying(false); return; }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [playing, reduced, inView, visible]);

  const choose = (index: number) => {
    setPlaying(false);
    clock.current = (index+1)*STAGE_MS-.001;
    setElapsed(clock.current);
  };
  const replay = () => { clock.current=0; setElapsed(0); setPlaying(!reduced); };
  const scene = pipelineFrame(elapsed, reduced);
  const excess = scene.index >= 3;
  const active = STAGE_COPY[scene.index];

  return <section id="signal-processing" className="lp-walk lp-wrap" data-pipeline-walk data-stage={scene.stage} data-playing={playing && !reduced && inView && visible} aria-labelledby="pipeline-walk-title">
    <p className="lp-kicker">ОБРАБОТКА СИГНАЛА</p>
    <h2 id="pipeline-walk-title">Как выделить локальный нагрев</h2>
    <p className="lp-section-intro">{WALK_INTRO}</p>
    <div className="lp-walk-board">
      <ol className="lp-walk-steps" aria-label="Этапы обработки учебного поля">
        {STAGE_COPY.map((step,index) => <li key={step.id}>
          <button type="button" aria-current={index === scene.index ? "step" : undefined} onClick={() => choose(index)}>
            <span className="lp-walk-number">{step.kicker}</span><span><strong>{step.name}</strong><small>{step.hint}</small></span>
          </button>
        </li>)}
      </ol>
      <div className="lp-walk-workspace">
        <div className="lp-walk-toolbar"><span>УЧЕБНОЕ ПОЛЕ · 5 ЭТАПОВ</span><div>
          {!reduced && <button type="button" className="lp-walk-play" onClick={() => elapsed >= WALK_DURATION_MS ? replay() : setPlaying(v=>!v)}>{playing ? "Пауза" : elapsed >= WALK_DURATION_MS ? "Повторить" : "Продолжить"}</button>}
          <button type="button" onClick={replay}>Сначала</button>
          {reduced && <span>Пошаговый просмотр</span>}
        </div></div>
        <div className="lp-walk-comparison">
          <figure><figcaption><span>01 / ИСХОДНИК</span><strong>До обработки</strong></figcaption><Field scene={scene} original/><div className="lp-walk-axis"><span>Время ↓</span><span>Расстояние →</span></div><p className="lp-walk-scale"><i/>Температура: ниже → выше</p></figure>
          <figure ref={playbackArea}><figcaption><span>{active.kicker} / ТЕКУЩИЙ ЭТАП</span><strong>{TITLES[scene.index]}</strong></figcaption><Field scene={scene}/><div className="lp-walk-axis"><span>Время ↓</span><span>Расстояние →</span></div><p className="lp-walk-scale"><i/>{excess ? "Превышение фона: нет → больше" : "Температура: ниже → выше"}</p></figure>
        </div>
        <div className="lp-walk-explanation"><span className="lp-walk-counter">{active.kicker} / 05</span><div className="lp-walk-copy">{STAGE_COPY.map((step,index) => <div key={step.id} data-active={index === scene.index} aria-hidden={index !== scene.index}><h3>{step.name}</h3><p>{step.text}</p></div>)}</div></div>
        <p className="lp-walk-key"><i/>Штриховка — нет измерения. Разрыв между строками — перерыв в записи.</p>
      </div>
    </div>
    <p className="lp-chart-note">{WALK_NOTE}</p>
  </section>;
}
