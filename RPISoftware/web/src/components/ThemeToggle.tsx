import { useT } from "../i18n";
import { useTheme, type Theme } from "../theme";
import { MoonIcon, SunIcon } from "./Icons";

const OPTIONS: { theme: Theme; label: "theme.dark" | "theme.light"; Icon: typeof MoonIcon }[] = [
  { theme: "dark", label: "theme.dark", Icon: MoonIcon },
  { theme: "light", label: "theme.light", Icon: SunIcon },
];

/** Dark / light segmented switch (top bar and login page). */
export function ThemeToggle() {
  const { theme, setTheme } = useTheme();
  const { t } = useT();
  return (
    <div className="seg theme-toggle" role="group" aria-label={t("theme.label")}>
      {OPTIONS.map(({ theme: o, label, Icon }) => (
        <button
          key={o}
          type="button"
          className={o === theme ? "active" : ""}
          aria-pressed={o === theme}
          aria-label={t(label)}
          title={t(label)}
          onClick={() => setTheme(o)}
        >
          <Icon />
        </button>
      ))}
    </div>
  );
}
