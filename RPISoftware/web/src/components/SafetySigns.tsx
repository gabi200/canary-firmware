/**
 * Standard emergency pictograms (ISO 7010 style), drawn as inline SVG so they stay
 * crisp at any size, need no assets/deps, and inherit the dark theme.
 *   - RunningManExit  → ISO 7010 E002 (emergency exit / evacuate)
 *   - HazardTriangle  → ISO 7010 W-series warning triangle, glyph per hazard
 *   - AssemblyPoint   → ISO 7010 E007 (evacuation assembly point)
 */

interface SignProps {
  size?: number;
  className?: string;
  title?: string;
}

const GREEN = "#0a8f3c";
const AMBER = "#f5c518";
const INK = "#14181d";

/** ISO 7010 E002 — white running figure + door + arrow on a green square. */
export function RunningManExit({ size = 48, className, title = "Emergency exit" }: SignProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 64 64"
      role="img"
      aria-label={title}
      className={className}
    >
      <title>{title}</title>
      <rect width="64" height="64" rx="10" fill={GREEN} />
      {/* door frame + arrow (egress direction) */}
      <rect x="45" y="12" width="11" height="40" rx="2" fill="none" stroke="#fff" strokeWidth="3" />
      <path d="M40 32 h12 M47 26 l6 6 -6 6" fill="none" stroke="#fff" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" />
      {/* running figure */}
      <circle cx="23" cy="14" r="5.5" fill="#fff" />
      <g stroke="#fff" strokeWidth="4.6" strokeLinecap="round" strokeLinejoin="round" fill="none">
        <path d="M25 21 L29 38" />
        {/* arms */}
        <path d="M26 25 L37 22" />
        <path d="M26 26 L16 32" />
        {/* legs mid-stride */}
        <path d="M29 38 L39 45" />
        <path d="M29 38 L21 50" />
      </g>
    </svg>
  );
}

function HazardGlyph({ hazard }: { hazard: string }) {
  switch (hazard) {
    case "combustible_gas":
      // flame
      return (
        <path
          d="M33 21 C 41 30, 43 37, 38 43 C 41 42, 42 39, 42 37 C 47 43, 44 53, 34 53 C 25 53, 21 45, 27 39 C 28 42, 30 43, 32 43 C 27 37, 30 27, 33 21 Z"
          fill={INK}
        />
      );
    case "water_leak":
      // droplet (all-Bézier teardrop — avoids degenerate-arc rendering issues)
      return (
        <path
          d="M32 17 C 32 17 44 34 44 44 C 44 50.6 38.6 56 32 56 C 25.4 56 20 50.6 20 44 C 20 34 32 17 32 17 Z"
          fill={INK}
        />
      );
    case "co":
      // toxic gas — labelled CO
      return (
        <text x="32" y="49" textAnchor="middle" fontSize="19" fontWeight="800" fill={INK} fontFamily="ui-sans-serif, system-ui, sans-serif">
          CO
        </text>
      );
    case "particulate":
      // smoke cloud with rising wisps
      return (
        <g fill={INK}>
          <circle cx="24" cy="45" r="7" />
          <circle cx="32" cy="40" r="9" />
          <circle cx="40" cy="45" r="7" />
          <rect x="24" y="44" width="16" height="8" />
          <path d="M29 30 c-3 -4 3 -6 0 -10 M35 30 c-3 -4 3 -6 0 -10" fill="none" stroke={INK} strokeWidth="2.4" strokeLinecap="round" />
        </g>
      );
    default:
      // generic exclamation
      return (
        <g fill={INK}>
          <rect x="29" y="24" width="6" height="16" rx="3" />
          <circle cx="32" cy="48" r="3.6" />
        </g>
      );
  }
}

/** ISO 7010 W-series — amber warning triangle with a black hazard glyph. */
export function HazardTriangle({ size = 48, className, title, hazard = "" }: SignProps & { hazard?: string }) {
  const label = title ?? "Hazard warning";
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 64 64"
      role="img"
      aria-label={label}
      className={className}
    >
      <title>{label}</title>
      <path d="M32 5 L61 57 H3 Z" fill={AMBER} stroke={INK} strokeWidth="3.5" strokeLinejoin="round" />
      <HazardGlyph hazard={hazard} />
    </svg>
  );
}

/** ISO 7010 E007 — green square, white figures gathering with inward arrows. */
export function AssemblyPoint({ size = 48, className, title = "Assembly point" }: SignProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 64 64"
      role="img"
      aria-label={title}
      className={className}
    >
      <title>{title}</title>
      <rect width="64" height="64" rx="10" fill={GREEN} />
      {/* inward arrows from the corners */}
      <g stroke="#fff" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" fill="none">
        <path d="M10 10 l8 0 M10 10 l0 8 M10 10 l9 9" />
        <path d="M54 10 l-8 0 M54 10 l0 8 M54 10 l-9 9" />
        <path d="M10 54 l8 0 M10 54 l0 -8 M10 54 l9 -9" />
        <path d="M54 54 l-8 0 M54 54 l0 -8 M54 54 l-9 -9" />
      </g>
      {/* a small group of people */}
      <g fill="#fff">
        <circle cx="26" cy="28" r="4" />
        <path d="M20 46 c0 -7 12 -7 12 0 Z" />
        <circle cx="38" cy="28" r="4" />
        <path d="M32 46 c0 -7 12 -7 12 0 Z" />
      </g>
    </svg>
  );
}
