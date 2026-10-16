import { createContext, useContext, useEffect, useLayoutEffect, useState, type ReactNode } from "react";
import { GlobalTheme } from "@carbon/react";
import {
  readTheme, resolveTheme, saveTheme, THEME_STORAGE_KEY, type ColorTheme,
} from "./theme-model";

const ThemeContext = createContext<{
  theme: ColorTheme;
  setTheme: (theme: ColorTheme) => void;
} | null>(null);

function preference() {
  try {
    return readTheme(localStorage);
  } catch {
    return null;
  }
}

export function AppTheme({ children }: { children: ReactNode }) {
  const [chosen, setChosen] = useState<ColorTheme | null>(preference);
  const [systemDark, setSystemDark] = useState(
    () => matchMedia("(prefers-color-scheme: dark)").matches,
  );
  const theme = resolveTheme(chosen, systemDark);

  useLayoutEffect(() => {
    document.documentElement.dataset.theme = theme;
    document.querySelector('meta[name="theme-color"]')?.setAttribute(
      "content", theme === "dark" ? "#161616" : "#ffffff",
    );
  }, [theme]);

  useEffect(() => {
    const media = matchMedia("(prefers-color-scheme: dark)");
    const changed = () => setSystemDark(media.matches);
    const stored = (event: StorageEvent) => {
      if (event.key === THEME_STORAGE_KEY || event.key === null) {
        setChosen(preference());
      }
    };
    changed();
    media.addEventListener("change", changed);
    window.addEventListener("storage", stored);
    return () => {
      media.removeEventListener("change", changed);
      window.removeEventListener("storage", stored);
    };
  }, []);

  const setTheme = (value: ColorTheme) => {
    setChosen(value);
    try {
      saveTheme(localStorage, value);
    } catch {
      // A blocked localStorage getter must not prevent switching in this tab.
    }
  };
  return (
    <ThemeContext.Provider value={{ theme, setTheme }}>
      <GlobalTheme theme={theme === "dark" ? "g100" : "white"}>
        {children}
      </GlobalTheme>
    </ThemeContext.Provider>
  );
}

export function useAppTheme() {
  const value = useContext(ThemeContext);
  if (!value) throw new Error("AppTheme is required");
  return value;
}

export function ThemeSwitch() {
  const { theme, setTheme } = useAppTheme();
  const dark = theme === "dark";
  return (
    <button
      className="theme-switch"
      type="button"
      role="switch"
      aria-checked={dark}
      aria-label="Тёмная тема"
      title={dark ? "Включить светлую тему" : "Включить тёмную тему"}
      onClick={(event) => {
        if (event.detail === 0) return;
        setTheme(dark ? "light" : "dark");
      }}
      onKeyDown={(event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        setTheme(dark ? "light" : "dark");
      }}
    >
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none"
        stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
        {dark ? (
          <>
            <circle cx="12" cy="12" r="4" />
            <path d="M12 1v3m0 16v3M1 12h3m16 0h3M4.2 4.2l2.1 2.1m11.4 11.4 2.1 2.1M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1" />
          </>
        ) : (
          <path d="M20.7 13.5A9 9 0 0 1 10.5 3.3a9 9 0 1 0 10.2 10.2Z" />
        )}
      </svg>
    </button>
  );
}

/** Canvas renderers need resolved colors, not CSS var() strings. */
export function chartColors() {
  const css = getComputedStyle(document.documentElement);
  const token = (name: string) => css.getPropertyValue(name).trim();
  return {
    axis: token("--cds-text-secondary"),
    grid: token("--dts-chart-grid"),
    series: token("--dts-chart-series"),
    raw: token("--cds-text-secondary"),
    threshold: token("--dts-chart-error"),
    background: token("--dts-chart-background"),
  };
}
