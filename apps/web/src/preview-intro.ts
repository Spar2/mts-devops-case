import { useEffect, useLayoutEffect, useRef, type RefObject } from "react";

/** A single short interaction hint over recorded data, never a simulated feed. */
export function usePreviewIntro({ ready, inspector, distance, time, point, row, maxPoint, maxRow, select }: {
  ready: boolean;
  inspector: RefObject<HTMLElement | null>;
  distance: RefObject<HTMLInputElement | null>;
  time: RefObject<HTMLInputElement | null>;
  point: number; row: number; maxPoint: number; maxRow: number;
  select: (point: number, row: number) => void;
}) {
  const consumed = useRef(false);
  const running = useRef(false);
  const cancel = useRef<() => void>(() => {});
  const latest = useRef({ point, row, select });

  useLayoutEffect(() => {
    latest.current = { point, row, select };
    if (!running.current) {
      if (distance.current) distance.current.value = String(point);
      if (time.current) time.current.value = String(row);
    }
  }, [point, row, select, distance, time]);

  useEffect(() => {
    const stop = () => { consumed.current = true; cancel.current(); };
    const pointer = (event: PointerEvent) => {
      if (running.current || event.target === distance.current || event.target === time.current) stop();
    };
    const picked = (event: MouseEvent) => {
      if (event.target instanceof Element && event.target.closest(".lp-field-plot svg")) stop();
    };
    const wheel = () => { if (running.current) stop(); };
    const hidden = () => { if (document.hidden) stop(); };
    const focused = (event: FocusEvent) => {
      if (event.target === distance.current || event.target === time.current) stop();
    };
    const motion = matchMedia("(prefers-reduced-motion: reduce)");
    const changed = () => { if (motion.matches) stop(); };
    document.addEventListener("pointerdown", pointer, true);
    document.addEventListener("click", picked, true);
    document.addEventListener("keydown", stop, true);
    document.addEventListener("wheel", wheel, { capture: true, passive: true });
    document.addEventListener("focusin", focused);
    document.addEventListener("visibilitychange", hidden);
    motion.addEventListener("change", changed);
    return () => {
      cancel.current();
      document.removeEventListener("pointerdown", pointer, true);
      document.removeEventListener("click", picked, true);
      document.removeEventListener("keydown", stop, true);
      document.removeEventListener("wheel", wheel, true);
      document.removeEventListener("focusin", focused);
      document.removeEventListener("visibilitychange", hidden);
      motion.removeEventListener("change", changed);
    };
  }, [distance, time]);

  useEffect(() => {
    if (!ready || !inspector.current || consumed.current) return;
    const motion = matchMedia("(prefers-reduced-motion: reduce)");
    if (motion.matches || document.hidden) { consumed.current = true; return; }
    let request = 0;
    let stopped = false;
    let started = false;
    let origin: number | null = null;
    const startPoint = latest.current.point, startRow = latest.current.row;
    const amplitudeX = Math.min(24, startPoint, maxPoint-startPoint);
    const amplitudeY = Math.min(10, startRow, maxRow-startRow);
    let chosenPoint = startPoint, chosenRow = startRow;
    const panel = inspector.current;
    panel.dataset.previewIntro = "waiting";
    const finish = (reason = "complete") => {
      if (stopped) return;
      panel.dataset.previewIntro = reason;
      stopped = true;
      running.current = false;
      cancelAnimationFrame(request);
      distance.current?.setAttribute("step", "1");
      time.current?.setAttribute("step", "1");
      if (distance.current) distance.current.value = String(chosenPoint);
      if (time.current) time.current.value = String(chosenRow);
    };
    cancel.current = () => finish("interaction");
    const tick = (now: number) => {
      if (stopped) return;
      if (origin === null) origin = now;
      const elapsed = now-origin;
      // Give the first frame time to settle, then ease into and out of the sweep.
      const p = Math.max(0, Math.min(1, (elapsed-220)/2600));
      const eased = p*p*p*(p*(p*6-15)+10);
      const wave = Math.sin(2*Math.PI*eased);
      const x = startPoint+amplitudeX*wave;
      const y = startRow-amplitudeY*wave;
      if (distance.current) distance.current.value = String(x);
      if (time.current) time.current.value = String(y);
      const nextPoint = Math.round(x), nextRow = Math.round(y);
      if (nextPoint !== chosenPoint || nextRow !== chosenRow) {
        chosenPoint = nextPoint; chosenRow = nextRow;
        latest.current.select(nextPoint, nextRow);
      }
      if (p >= 1) { finish(); return; }
      request = requestAnimationFrame(tick);
    };
    const observer = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting || entry.intersectionRatio < .75) {
        if (started) finish("outside");
        return;
      }
      if (started || consumed.current || stopped) return;
      started = true; consumed.current = true; running.current = true;
      panel.dataset.previewIntro = "running";
      distance.current?.setAttribute("step", "any");
      time.current?.setAttribute("step", "any");
      request = requestAnimationFrame(tick);
    }, { threshold: [0, .75] });
    observer.observe(inspector.current);
    return () => { observer.disconnect(); finish("cleanup"); cancel.current = () => {}; };
  }, [ready, inspector, distance, time, maxPoint, maxRow]);
}
