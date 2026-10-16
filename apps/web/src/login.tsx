import { FormEvent, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { Button, InlineNotification, TextInput } from "@carbon/react";
import { ThemeSwitch } from "./theme";

function safeNext(value: string | null): string {
  if (value === "/service") return value;
  return "/service";
}

export function Login() {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const next = safeNext(params.get("next"));

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy || !username.trim() || password.length < 12) return;
    setBusy(true);
    setError("");
    try {
      const response = await fetch("/api/v1/auth/login", {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password }),
      });
      if (!response.ok) {
        if (response.status === 429) throw new Error("Слишком много попыток входа. Подождите минуту и повторите.");
        if (response.status === 401) throw new Error("Не удалось войти. Проверьте логин и пароль.");
        throw new Error("Сервер временно недоступен. Повторите вход позже.");
      }
      setPassword("");
      navigate(next, { replace: true });
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Проверьте логин и пароль.");
      setBusy(false);
    }
  }

  return (
    <main className="page">
      <div className="auth-theme-tools">
        <Link to="/">← На главную</Link>
        <ThemeSwitch />
      </div>
      <h1>Единая аналитическая платформа сенсорных данных · вход</h1>
      <p>Стенд пускает в одну службу. Учётная запись задаётся при запуске и описана в README.</p>
      <form className="review-form" onSubmit={(event) => void submit(event)}>
        <TextInput
          id="login-name"
          autoComplete="username"
          maxLength={100}
          labelText="Логин"
          value={username}
          onChange={(event) => setUsername(event.target.value)}
        />
        <TextInput
          id="login-password"
          type="password"
          autoComplete="current-password"
          maxLength={512}
          labelText="Пароль"
          helperText={
            password.length > 0 && password.length < 12
              ? "Минимум 12 символов. Пока введено меньше — кнопка входа недоступна."
              : "Пароль аккаунта — минимум 12 символов."
          }
          value={password}
          onChange={(event) => setPassword(event.target.value)}
        />
        <Button type="submit" disabled={busy || !username.trim() || password.length < 12}>
          Войти
        </Button>
        {error && (
          <InlineNotification kind="error" title="Вход не выполнен" subtitle={error} hideCloseButton />
        )}
      </form>
    </main>
  );
}
