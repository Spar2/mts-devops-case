export type ColorTheme = "light" | "dark";
export const THEME_STORAGE_KEY = "dts-ui-theme";
export function parseTheme(value: string | null): ColorTheme | null {
  return value === "light" || value === "dark" ? value : null;
}
export function resolveTheme(preference: ColorTheme | null, systemDark: boolean): ColorTheme {
  return preference ?? (systemDark ? "dark" : "light");
}
export function readTheme(storage: Pick<Storage, "getItem">): ColorTheme | null {
  try {
    return parseTheme(storage.getItem(THEME_STORAGE_KEY));
  }
  catch {
    return null;
  }
}
export function saveTheme(storage: Pick<Storage, "setItem">, theme: ColorTheme): boolean {
  try {
    storage.setItem(THEME_STORAGE_KEY, theme);
    return true;
  }
  catch {
    return false;
  }
}
