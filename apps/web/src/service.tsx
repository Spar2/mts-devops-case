import { useEffect, useState } from "react";
import { Navigate } from "react-router-dom";
import { Button, InlineNotification, Loading, Tag } from "@carbon/react";
import { ThemeSwitch } from "./theme";

type Account = { username: string; display_name: string; role: string };
type Reading = { distance_m: number; temperature_c: number; quality: string; note?: string };
type Service = {
  name: string;
  version: string;
  status: string;
  uptime_s: number;
  requests: number;
  last_probe_ms: number | null;
  reading: Reading;
};

async function readJson<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, { credentials: "include", ...init });
  if (response.status === 401) throw Object.assign(new Error("auth"), { status: 401 });
  if (!response.ok) throw new Error("Служба не ответила");
  return response.json() as Promise<T>;
}

export function ServiceDesk() {
  const [account, setAccount] = useState<Account | null>();
  const [service, setService] = useState<Service | null>(null);
  const [error, setError] = useState("");
  const [probe, setProbe] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let stop = false;
    const loadAccount = readJson<Account>("/api/v1/auth/me")
      .then((value) => { if (!stop) setAccount(value); })
      .catch((reason: { status?: number }) => {
        if (stop) return;
        if (reason?.status === 401) setAccount(null);
        else {
          setError("Сервер временно недоступен.");
          setAccount(null);
        }
      });
    return () => { stop = true; void loadAccount; };
  }, []);

  useEffect(() => {
    if (!account) return;
    let stop = false;
    const tick = () => {
      readJson<Service>("/api/v1/service")
        .then((value) => { if (!stop) { setService(value); setError(""); } })
        .catch((reason: { status?: number }) => {
          if (stop) return;
          if (reason?.status === 401) setAccount(null);
          else setError("Не удалось прочитать состояние службы.");
        });
    };
    tick();
    const timer = window.setInterval(tick, 5000);
    return () => { stop = true; window.clearInterval(timer); };
  }, [account]);

  if (account === undefined) {
    return <main className="page"><Loading description="Проверяем доступ" withOverlay={false} /></main>;
  }
  if (account === null) return <Navigate to="/login?next=/service" replace />;

  async function check() {
    setBusy(true);
    setProbe("");
    setError("");
    try {
      const result = await readJson<{ ok: boolean; latency_ms: number }>("/api/v1/service/probe", { method: "POST" });
      setProbe(`Проверка выполнена за ${result.latency_ms.toFixed(1)} мс`);
      setService(await readJson<Service>("/api/v1/service"));
    } catch (reason) {
      if ((reason as { status?: number }).status === 401) setAccount(null);
      else setError("Проверка службы не выполнена.");
    } finally {
      setBusy(false);
    }
  }

  async function leave() {
    await fetch("/api/v1/auth/logout", { method: "POST", credentials: "include" });
    location.assign("/");
  }

  return (
    <>
      <header className="shell">
        <a className="brand" href="/">Единая аналитическая платформа сенсорных данных</a>
        <nav aria-label="Основная навигация">
          <a className="active" href="/service" aria-current="page">Служба</a>
        </nav>
        <span className="local-label">Демо-стенд</span>
        <span className="account-actions">
          {account.display_name} · {account.role}
          <button type="button" onClick={() => void leave()}>Выйти</button>
        </span>
        <ThemeSwitch />
      </header>
      <main className="page">
        <div className="page-title">
          <h1>Служба</h1>
          <Tag type="blue">Один микросервис</Tag>
        </div>
        <p>
          Окно читает JSON службы <code>sensor-gateway</code>. Показание синтетическое:
          оно нужно, чтобы у стенда был живой ответ, а не архив измерений.
        </p>
        {error && <InlineNotification kind="error" title="Действие не выполнено" subtitle={error} hideCloseButton />}
        {!service && !error && <Loading description="Читаем службу" withOverlay={false} />}
        {service && (
          <section className="region-panel">
            <h2>{service.name}</h2>
            <p>Версия {service.version}. Состояние обновляется каждые 5 секунд.</p>
            <div className="evidence-strip">
              <div><span>Состояние</span><strong>{service.status}</strong></div>
              <div><span>Время работы, с</span><strong>{Math.floor(service.uptime_s)}</strong></div>
              <div><span>Запросы окна</span><strong>{service.requests}</strong></div>
            </div>
            <dl className="readings">
              <dt>Дистанция</dt>
              <dd>{service.reading.distance_m.toFixed(1)} м</dd>
              <dt>Температура</dt>
              <dd>{service.reading.temperature_c.toFixed(1)} °C</dd>
              <dt>Качество</dt>
              <dd>{service.reading.quality}</dd>
              <dt>Последняя проверка</dt>
              <dd>{service.last_probe_ms === null ? "ещё не было" : `${service.last_probe_ms.toFixed(1)} мс`}</dd>
            </dl>
            <div className="action-row">
              <Button disabled={busy} onClick={() => void check()}>Проверить службу</Button>
              {probe && <p role="status">{probe}</p>}
            </div>
          </section>
        )}
      </main>
    </>
  );
}
