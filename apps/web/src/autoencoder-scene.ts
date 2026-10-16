/** Architecture from the team's ConvAutoencoder illustration. No inference values. */
export const AE_DURATION = 24;
export const AE_STAGES = [
  { name: "Вход", operation: "Input", shape: [1, 32, 64], start: 0, title: "Температурное поле становится входом сети", text: "Один канал, 32 отсчёта времени и 64 точки вдоль волокна. Сетка показывает устройство входа; цвета не являются результатом расчёта.", tone: "input" },
  { name: "Свёртка", operation: "Conv + ReLU", shape: [16, 32, 64], start: 3, title: "Одно окно — несколько карт признаков", text: "Ядро 3 × 3 проходит по сетке. Свёртка формирует 16 каналов признаков, сохраняя размеры по времени и расстоянию.", tone: "encoder" },
  { name: "Pooling", operation: "MaxPool 2 × 2", shape: [16, 16, 32], start: 6, title: "Меньше ячеек в каждой карте", text: "Из каждого окна 2 × 2 остаётся максимальное значение. Время и расстояние уменьшаются вдвое; число каналов остаётся равным 16.", tone: "encoder" },
  { name: "Свёртка", operation: "Conv + ReLU", shape: [32, 16, 32], start: 9, title: "Признаки собираются в 32 канала", text: "Вторая свёртка работает с картами первого блока. Разрешение пока не меняется, а число каналов увеличивается с 16 до 32.", tone: "encoder" },
  { name: "Latent", operation: "MaxPool → Latent", shape: [32, 8, 16], start: 12, title: "Внутреннее представление", text: "После второго pooling остаётся 32 × 8 × 16 = 4096 активаций. Пространственная сетка меньше, но общее число значений больше, чем 2048 на входе.", tone: "latent" },
  { name: "Декодер", operation: "ConvT + ReLU", shape: [16, 16, 32], start: 16, title: "Декодер увеличивает разрешение", text: "Транспонированная свёртка с ядром 2 × 2 и шагом 2 увеличивает обе оси вдвое. На этом этапе остаётся 16 каналов.", tone: "decoder" },
  { name: "Выход", operation: "ConvT → Output", shape: [1, 32, 64], start: 20, title: "Снова один канал и исходная сетка", text: "Выход имеет форму 1 × 32 × 64. Это схема восстановления: реальные значения и качество модели можно показать только вместе с фактическим расчётом.", tone: "decoder" },
] as const;

export function autoencoderFrame(time: number) {
  const t = Number.isFinite(time) ? Math.max(0, Math.min(AE_DURATION, time)) : 0;
  let index = 0;
  for (let i = 1; i < AE_STAGES.length; i++) if (t >= AE_STAGES[i].start) index = i;
  const end = AE_STAGES[index + 1]?.start ?? AE_DURATION;
  return { time: t, index, progress: (t - AE_STAGES[index].start) / (end - AE_STAGES[index].start) };
}

export const AE_NUMBER_Y = 70;
export const AE_BASE_Y = 280;
export const smoothFlow = (value: number) => {
  const p = Math.max(0, Math.min(1, value));
  return p * p * p * (p * (p * 6 - 15) + 10);
};

/** One continuous cursor shared by the diagram, cells and explanation. */
export function autoencoderFlow(time: number) {
  const frame = autoencoderFrame(time);
  const next = Math.min(AE_STAGES.length - 1, frame.index + 1);
  const mix = next === frame.index ? 0 : smoothFlow(frame.progress);
  const weights = AE_STAGES.map((_, i) => i === frame.index ? 1 - mix : i === next ? mix : 0);
  return { ...frame, from: frame.index, to: next, mix, position: frame.index + mix, weights };
}

export function autoencoderNodeBounds(index: number) {
  const [channels, rows, columns] = AE_STAGES[index].shape;
  const w = 9 + channels * 1.1, h = rows * 4.4, d = columns * 1.12;
  const x = 44 + index * 162;
  return { x, w, h, d, top: AE_BASE_Y - h - d * .64, center: x + (w + d) / 2 };
}
export type ScenePalette = {
  background: string; text: string; muted: string; grid: string; accent: string;
  input: string; encoder: string; latent: string; decoder: string;
};
type Point = [number, number];
function polygon(ctx: CanvasRenderingContext2D, points: Point[], fill: string, stroke: string) {
  ctx.beginPath();
  points.forEach(([x, y], i) => i ? ctx.lineTo(x, y) : ctx.moveTo(x, y));
  ctx.closePath(); ctx.fillStyle = fill; ctx.fill(); ctx.strokeStyle = stroke; ctx.lineWidth = 1; ctx.stroke();
}
function label(ctx: CanvasRenderingContext2D, text: string, x: number, y: number, size: number, color: string, mono = false) {
  ctx.font = `${size}px "IBM Plex ${mono ? "Mono" : "Sans"}", sans-serif`;
  ctx.textAlign = "center"; ctx.fillStyle = color; ctx.fillText(text, x, y);
}
function blendColor(a: string, b: string, mix: number) {
  const rgb = (hex: string) => {
    let value = hex.replace("#", "");
    if (value.length === 3) value = [...value].map(c => c+c).join("");
    return [0,2,4].map(i => parseInt(value.slice(i,i+2),16));
  };
  const left=rgb(a), right=rgb(b);
  return `rgb(${left.map((v,i)=>Math.round(v+(right[i]-v)*mix)).join(",")})`;
}

/** Pure drawing: identical time, viewport and palette produce the same frame. */
export function drawAutoencoder(ctx: CanvasRenderingContext2D, width: number, height: number, time: number, palette: ScenePalette, still = false) {
  const flow = autoencoderFlow(time);
  const mobile = height / width > .6;
  const dominant = Math.round(flow.position);
  const mix = (a:number,b:number) => a+(b-a)*flow.mix;
  ctx.save(); ctx.clearRect(0,0,width,height);
  ctx.fillStyle=palette.background; ctx.fillRect(0,0,width,height);
  ctx.scale(width/(mobile?420:1200),height/(mobile?330:350));
  ctx.lineJoin="round";
  if (!mobile) {
    label(ctx,"ENCODER",352,26,14,palette.muted,true);
    label(ctx,"DECODER",984,26,14,palette.muted,true);
    ctx.strokeStyle=palette.grid; ctx.beginPath();ctx.moveTo(44,40);ctx.lineTo(666,40);ctx.moveTo(871,40);ctx.lineTo(1162,40);ctx.stroke();
  }
  for (const i of mobile ? [dominant] : AE_STAGES.map((_,i)=>i)) {
    const stage=AE_STAGES[i];
    const shape=mobile ? AE_STAGES[flow.from].shape.map((v,k)=>mix(v,AE_STAGES[flow.to].shape[k])) : stage.shape;
    const [channels,rows,columns]=shape;
    const weight=mobile?1:flow.weights[i];
    let h=rows*4.4,w=9+channels*1.1,d=columns*1.12;
    if(mobile){const zoom=170/(h+d*.64);h*=zoom;w*=zoom;d*=zoom;}
    const dy=d*.64,x=mobile?(420-w-d)/2:44+i*162,y=mobile?247:AE_BASE_Y;
    const color=mobile?blendColor(palette[AE_STAGES[flow.from].tone],palette[AE_STAGES[flow.to].tone],flow.mix):palette[stage.tone];
    const alpha=still?1:.62+.38*weight;
    ctx.globalAlpha=alpha;
    polygon(ctx,[[x,y],[x,y-h],[x+d,y-h-dy],[x+d,y-dy]],color,palette.text);
    ctx.globalAlpha=alpha*.65;
    polygon(ctx,[[x,y-h],[x+w,y-h],[x+w+d,y-h-dy],[x+d,y-h-dy]],color,palette.text);
    ctx.globalAlpha=alpha;
    polygon(ctx,[[x+w,y],[x+w,y-h],[x+w+d,y-h-dy],[x+w+d,y-dy]],color,palette.text);
    polygon(ctx,[[x,y],[x+w,y],[x+w,y-h],[x,y-h]],color,palette.text);
    ctx.save();ctx.translate(x+w,y-h);ctx.transform(d/16,-dy/16,0,h/8,0,0);
    ctx.strokeStyle=palette.text;ctx.globalAlpha=.09+.14*weight;ctx.lineWidth=.12;
    for(let c=1;c<16;c++){ctx.beginPath();ctx.moveTo(c,0);ctx.lineTo(c,8);ctx.stroke();}
    for(let r=1;r<8;r++){ctx.beginPath();ctx.moveTo(0,r);ctx.lineTo(16,r);ctx.stroke();}
    if(weight>0 && !still){
      // Continuous serpentine scan: no modulo reset at layer boundaries.
      const column=(1-Math.cos(flow.time*1.8))*6.5;
      const row=(1-Math.cos(flow.time*.9))*2.5;
      const size=i===2||i===4?2:3;
      ctx.fillStyle=palette.accent;ctx.globalAlpha=.45*weight;ctx.fillRect(column,row,size,size);
      ctx.strokeStyle=palette.accent;ctx.lineWidth=.24;ctx.globalAlpha=.9*weight;ctx.strokeRect(column,row,size,size);
      // Neighbouring cells respond in a soft wave around the scanning window.
      for(let c=0;c<16;c++){
        const distance=Math.abs(c-column-1);
        ctx.globalAlpha=Math.max(0,1-distance/4)*weight*.14;
        ctx.fillRect(c,0,.7,8);
      }
    }
    ctx.restore();ctx.globalAlpha=1;
    const center=x+(w+d)/2;
    if(mobile)ctx.globalAlpha=smoothFlow(Math.abs(2*flow.mix-1)/.24);
    label(ctx,String(i+1).padStart(2,"0"),center,mobile?26:AE_NUMBER_Y,14,blendColor(palette.muted,palette.accent,weight),true);
    if(mobile)ctx.globalAlpha=smoothFlow(Math.abs(2*flow.mix-1)/.24);
    label(ctx,stage.shape.join(" × "),center,mobile?286:310,mobile?22:16,palette.text,true);
    label(ctx,stage.operation,center,mobile?311:333,mobile?16:14,palette.muted);
    ctx.globalAlpha=1;
    if(!mobile && i<AE_STAGES.length-1){
      const from=x+w+d+10,to=44+(i+1)*162-12;
      ctx.strokeStyle=palette.grid;ctx.lineWidth=1.5;ctx.beginPath();ctx.moveTo(from,210);ctx.lineTo(to,210);ctx.lineTo(to-5,206);ctx.moveTo(to,210);ctx.lineTo(to-5,214);ctx.stroke();
    }
  }
  if(!mobile && !still && flow.from!==flow.to){
    const a=autoencoderNodeBounds(flow.from),b=autoencoderNodeBounds(flow.to);
    // A small train of cells carries the signal across the actual gap.
    for(let n=0;n<5;n++){
      const p=Math.max(0,Math.min(1,flow.mix*1.25-n*.06));
      const x=a.center+(b.center-a.center)*p;
      const y=AE_BASE_Y-(a.h+a.d*.64)/2+((a.h+a.d*.64)-(b.h+b.d*.64))/2*smoothFlow(p);
      ctx.globalAlpha=Math.sin(Math.PI*p)*(.7-n*.1);
      ctx.fillStyle=palette.accent;ctx.fillRect(x-2.5,y-2.5,5,5);
    }
    // The wireframe keeps its shape and position at both ends of a handoff.
    const x=mix(a.x,b.x),y=AE_BASE_Y,w=mix(a.w,b.w),h=mix(a.h,b.h),d=mix(a.d,b.d),dy=d*.64;
    ctx.globalAlpha=.35*Math.sin(Math.PI*flow.mix);ctx.strokeStyle=palette.accent;ctx.lineWidth=1.4;
    ctx.beginPath();ctx.moveTo(x,y);ctx.lineTo(x,y-h);ctx.lineTo(x+d,y-h-dy);ctx.lineTo(x+w+d,y-h-dy);ctx.lineTo(x+w+d,y-dy);ctx.lineTo(x+w,y);ctx.closePath();
    ctx.moveTo(x+w,y);ctx.lineTo(x+w,y-h);ctx.lineTo(x,y-h);ctx.moveTo(x+w,y-h);ctx.lineTo(x+w+d,y-h-dy);ctx.stroke();ctx.globalAlpha=1;
  }
  if(mobile){
    label(ctx,"ВРЕМЯ × РАССТОЯНИЕ",210,52,12,palette.muted,true);
    label(ctx,"→",54,170,28,palette.muted);label(ctx,"→",366,170,28,palette.muted);
  }
  ctx.restore();
}
