/**
 * Official ISO 7010 safety signs, the pictograms the EU mandates through
 * Directive 92/58/EEC and Romania through HG 971/2006 (SR EN ISO 7010).
 *
 * public/signs/<code>.svg are the public-domain `File:ISO_7010_<code>.svg` from
 * Wikimedia Commons, unmodified; the mobile app ships PNG renders of the same files.
 * ISO 7010 signs carry no words; the caption / tooltip shows the name in the active language.
 */

import { useT, type Lang } from "../i18n";

const SIGNS = {
  E002: ["Emergency exit", "Ieșire de urgență"],
  E004: ["Emergency telephone", "Telefon de urgență"],
  E007: ["Evacuation assembly point", "Punct de adunare"],
  P001: ["Prohibited", "Interzis"],
  P003: ["No open flame", "Interzis focul deschis"],
  P020: ["Do not use lift in the event of fire", "Nu folosiți liftul în caz de incendiu"],
  P031: ["Do not alter the state of the switch", "Nu acționați întrerupătorul"],
  W001: ["Warning", "Atenție, pericol"],
  W011: ["Slippery surface", "Atenție, suprafață alunecoasă"],
  W016: ["Toxic material", "Atenție, substanțe toxice"],
  W021: ["Flammable material", "Atenție, materiale inflamabile"],
} as const;

export type SignCode = keyof typeof SIGNS;

/** The ISO 7010 warning sign for a hazard type. */
export function hazardSign(hazard: string): SignCode {
  switch (hazard) {
    case "combustible_gas":
      return "W021";
    case "co":
      return "W016";
    case "water_leak":
      return "W011";
    default:
      // ISO 7010 has no smoke sign; ISO 3864-1 says use the general warning.
      return "W001";
  }
}

/** What residents must (not) do for a hazard, mirroring the mobile app's advice line. */
export function hazardAdviceSigns(hazard: string): SignCode[] {
  switch (hazard) {
    case "combustible_gas":
      return ["P020", "P031", "P003"];
    case "co":
      return ["E002"];
    case "water_leak":
      return ["P031"];
    default:
      return ["P020"];
  }
}

export function signName(code: SignCode, lang: Lang): string {
  const [en, ro] = SIGNS[code];
  return lang === "ro" ? ro : en;
}

export function SafetySign({
  code,
  size = 48,
  className,
  title,
}: {
  code: SignCode;
  size?: number;
  className?: string;
  title?: string;
}) {
  const { lang } = useT();
  const label = title ?? signName(code, lang);
  return (
    <img
      src={`${import.meta.env.BASE_URL}signs/${code}.svg`}
      width={size}
      height={size}
      alt={label}
      title={`${label} (ISO 7010 ${code})`}
      className={className}
    />
  );
}
