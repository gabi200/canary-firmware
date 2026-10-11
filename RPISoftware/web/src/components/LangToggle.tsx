import { useT, type Lang } from "../i18n";

/** Language names are endonyms: each is written in its own language, never translated. */
const OPTIONS: { lang: Lang; name: string }[] = [
  { lang: "ro", name: "Română" },
  { lang: "en", name: "English" },
];

/** RO / EN segmented switch (Topbar and login page). */
export function LangToggle() {
  const { lang, setLang, t } = useT();
  return (
    <div className="seg lang-toggle" role="group" aria-label={t("lang.label")}>
      {OPTIONS.map((o) => (
        <button
          key={o.lang}
          type="button"
          lang={o.lang}
          className={o.lang === lang ? "active" : ""}
          aria-pressed={o.lang === lang}
          aria-label={o.name}
          title={o.name}
          onClick={() => setLang(o.lang)}
        >
          {o.lang.toUpperCase()}
        </button>
      ))}
    </div>
  );
}
