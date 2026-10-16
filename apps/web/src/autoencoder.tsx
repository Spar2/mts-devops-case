import { useEffect, useRef, useState } from "react";
import { useInView } from "motion/react";
import { useAppTheme } from "./theme";
import { AE_DURATION, AE_STAGES, autoencoderFrame, autoencoderFlow, drawAutoencoder, smoothFlow, type ScenePalette } from "./autoencoder-scene";
import "./autoencoder.scss";

export default function Autoencoder() {
  const root = useRef<HTMLElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const range = useRef<HTMLInputElement>(null);
  const clockLabel = useRef<HTMLOutputElement>(null);
  const stageStrip = useRef<HTMLDivElement>(null);
  const stageTrack = useRef<HTMLDivElement>(null);
  const indicator = useRef<HTMLSpanElement>(null);
  const copy = useRef<HTMLDivElement>(null);
  const detailNumber = useRef<HTMLDivElement>(null);
  const detailShape = useRef<HTMLDivElement>(null);
  const seekAnimation = useRef<{ stop: () => void } | null>(null);
  const time = useRef(0);
  const selected = useRef(0);
  const render = useRef<() => void>(() => {});
  const [index, setIndex] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [visible, setVisible] = useState(() => !document.hidden);
  const [reduced, setReduced] = useState(() => window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  const inView = useInView(root, { amount: .15 });
  const { theme } = useAppTheme();
  useEffect(() => {
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const changed = () => { setReduced(media.matches); if (media.matches) { setPlaying(false); seekAnimation.current?.stop(); } };
    media.addEventListener("change", changed);
    return () => media.removeEventListener("change", changed);
  }, []);
  useEffect(() => () => seekAnimation.current?.stop(), []);
  useEffect(() => { if (!inView || !visible) seekAnimation.current?.stop(); }, [inView, visible]);
  useEffect(() => {
    const changed = () => setVisible(!document.hidden);
    document.addEventListener("visibilitychange", changed);
    return () => document.removeEventListener("visibilitychange", changed);
  }, []);
  useEffect(() => {
    const el = canvas.current;
    if (!el) return;
    const ctx = el.getContext("2d");
    if (!ctx) return;
    const styles = getComputedStyle(el);
    const color = (name: string) => styles.getPropertyValue(`--ae-${name}`).trim();
    const palette = Object.fromEntries(["background","text","muted","grid","accent","input","encoder","latent","decoder"].map(key => [key,color(key)])) as ScenePalette;
    let width = 0, height = 0, stripWidth = 0;
    let cells: { x: number; width: number }[] = [];
    const panels = Array.from(copy.current?.children ?? []) as HTMLElement[];
    let disposed = false;
    const paint = () => {
      if (disposed) return;
      const ratio = Math.min(window.devicePixelRatio || 1,2);
      const w = Math.max(1,Math.round(width*ratio)), h = Math.max(1,Math.round(height*ratio));
      if (el.width!==w || el.height!==h) {el.width=w;el.height=h;}
      ctx.setTransform(ratio,0,0,ratio,0,0);
      drawAutoencoder(ctx,width,height,time.current,palette,!!reduced);
      if (range.current) range.current.value=String(time.current);
      if (clockLabel.current) clockLabel.current.value=`${time.current.toFixed(1)} / ${AE_DURATION} с`;
      const flow = autoencoderFlow(time.current);
      if (indicator.current && cells.length === AE_STAGES.length) {
        const x = cells[flow.from].x + (cells[flow.to].x-cells[flow.from].x)*flow.mix;
        const w = cells[flow.from].width + (cells[flow.to].width-cells[flow.from].width)*flow.mix;
        indicator.current.style.transform = `translateX(${x}px)`;
        indicator.current.style.width = `${w}px`;
        const strip = stageStrip.current;
        if (strip) strip.scrollLeft = Math.max(0, x+w/2-stripWidth/2);
      }
      panels.forEach((panel,i) => {
        const opacity = reduced ? Number(i === Math.round(flow.position)) : smoothFlow((flow.weights[i]-.5)/.12);
        panel.style.opacity = String(opacity);
        panel.style.visibility = opacity > .001 ? "visible" : "hidden";
      });
      const fade = reduced ? 1 : smoothFlow(Math.abs(flow.mix*2-1)/.24);
      if (detailNumber.current) detailNumber.current.style.opacity = String(fade);
      if (detailShape.current) detailShape.current.style.opacity = String(fade);
      const next = Math.round(flow.position);
      if (selected.current!==next) {selected.current=next;setIndex(next);}
    };
    render.current=paint;
    const measure = () => {
      const bounds = el.getBoundingClientRect(); width = bounds.width; height = bounds.height;
      stripWidth = stageStrip.current?.clientWidth ?? 0;
      const trackLeft = stageTrack.current?.getBoundingClientRect().left ?? 0;
      cells = Array.from(stageTrack.current?.querySelectorAll("button") ?? []).map(button => {
        const bounds = button.getBoundingClientRect();
        return { x: bounds.left-trackLeft, width: bounds.width };
      });
      paint();
    };
    const observer=new ResizeObserver(measure);observer.observe(el);
    if(stageTrack.current) observer.observe(stageTrack.current);
    measure();
    void document.fonts.ready.then(paint);
    return () => {disposed=true;observer.disconnect();render.current=()=>{};};
  }, [theme,reduced]);
  useEffect(() => {
    if (!playing || !inView || !visible || reduced) return;
    let request=0;
    let previous: number|null=null;
    const tick=(now:number)=>{
      if(previous!==null) time.current=Math.min(AE_DURATION,time.current+(now-previous)/1000);
      previous=now;render.current();
      if(time.current>=AE_DURATION){setPlaying(false);return;}
      request=requestAnimationFrame(tick);
    };
    request=requestAnimationFrame(tick);
    return ()=>cancelAnimationFrame(request);
  }, [playing,inView,visible,reduced]);
  const seek=(value:number, smoothly=false)=>{
    seekAnimation.current?.stop();
    const target = autoencoderFrame(value).time;
    if(smoothly && !reduced && Math.abs(target-time.current)>.01){
      const source = time.current;
      const duration = Math.min(900, 450+Math.abs(target-source)*20);
      let origin: number | null = null, request = 0;
      const tick = (now: number) => {
        if (document.hidden) return;
        if (origin === null) origin = now;
        const progress = smoothFlow((now-origin)/duration);
        time.current = progress >= 1 ? target : source+(target-source)*progress;
        render.current();
        if (progress < 1) request = requestAnimationFrame(tick);
      };
      seekAnimation.current = { stop: () => cancelAnimationFrame(request) };
      request = requestAnimationFrame(tick);
    }else{time.current=target;render.current();}
  };
  const stage=AE_STAGES[index];
  return <section className="ae lp-wrap" id="autoencoder" ref={root} aria-labelledby="ae-title">
    <div className="ae-heading"><div><p className="lp-kicker">ВНУТРИ МОДЕЛИ</p><h2 id="ae-title">Как устроен автоэнкодер</h2></div><span className="ae-badge">ConvAutoencoder <span>1 × 32 × 64</span></span></div>
    <p className="ae-intro">От входной сетки к картам признаков и обратно. Пройдите по слоям сети из схемы команды.</p>
    <div className="ae-player">
      <div className="ae-canvas-wrap"><canvas ref={canvas} role="img" aria-label="Архитектура автоэнкодера: вход, две свёртки с pooling, внутреннее представление и декодер. Размерности и пояснения доступны ниже."/><span className="ae-axis">C × T × X <span>каналы · время · расстояние</span></span></div>
      <div className="ae-transport">
        <button className="ae-play" type="button" disabled={!!reduced} onClick={()=>{seekAnimation.current?.stop();if(time.current>=AE_DURATION)seek(0);setPlaying(!playing);}} aria-label={playing?"Пауза анимации":"Воспроизвести анимацию"}><span aria-hidden="true">{playing?"Ⅱ":"▶"}</span>{playing?"Пауза":"Смотреть"}</button>
        <button className="ae-reset" type="button" onClick={()=>{setPlaying(false);seek(0,true);}} aria-label="Вернуться к началу анимации">↺</button>
        <label className="ae-timeline"><span className="ae-sr-only">Время анимации, секунды</span><input ref={range} type="range" min="0" max={AE_DURATION} step="0.05" defaultValue="0" onChange={e=>{setPlaying(false);seek(Number(e.target.value));}}/></label>
        <output ref={clockLabel} className="ae-time" aria-live="off">0.0 / 24 с</output>
      </div>
      <div className="ae-stages" ref={stageStrip} role="group" aria-label="Выберите слой автоэнкодера"><div className="ae-stage-track" ref={stageTrack}><span className="ae-stage-indicator" ref={indicator} aria-hidden="true"/>{AE_STAGES.map((s,i)=><button type="button" key={i} aria-pressed={index===i} onClick={()=>{setPlaying(false);seek(s.start,true);}}><span>{String(i+1).padStart(2,"0")}</span>{s.name}</button>)}</div></div>
      <div className="ae-detail"><div className="ae-detail-number" ref={detailNumber}>{String(index+1).padStart(2,"0")}<span>/ 07</span></div><div className="ae-copy" ref={copy}>{AE_STAGES.map((s,i)=><div key={i} data-active={i===index} aria-hidden={i!==index}><h3>{s.title}</h3><p>{s.text}</p></div>)}</div><div className="ae-shape" ref={detailShape}><span>C × T × X</span><strong>{stage.shape.join(" × ")}</strong></div></div>
    </div>
    <p className="ae-note">{reduced?"Анимация отключена по настройке уменьшения движения. Слои можно выбирать вручную. ":""}Схема по иллюстрации команды. Движение и сетки поясняют архитектуру; вывод модели и качество обнаружения здесь не показаны.</p>
  </section>;
}
