/**
 * Line icons (24px grid, currentColor stroke, 1.75 width). Always decorative: every icon is
 * shown next to a text label, so they are aria-hidden. Size them with CSS (`.icon`: 1.15em);
 * inside another SVG pass x / y / width / height. ISO 7010 safety signs stay in SafetySigns.
 */
import type { ReactNode, SVGProps } from "react";

type IconProps = Omit<SVGProps<SVGSVGElement>, "children">;

function Icon({ children, className, style, ...rest }: IconProps & { children: ReactNode }) {
  // explicit width / height (icons nested in another SVG) must beat the .icon CSS size
  const size = rest.width != null ? { width: rest.width, height: rest.height ?? rest.width } : undefined;
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      className={`icon ${className ?? ""}`}
      style={{ ...size, ...style }}
      {...rest}
    >
      {children}
    </svg>
  );
}

/** International Symbol of Access (ISO 7001) silhouette: seated figure + open wheel. */
export const WheelchairIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="11.5" cy="4" r="1.8" />
    <path d="M11.5 7.5v5.5h4.5l2.2 5.8" />
    <path d="M11.5 10.2h4.2" />
    <path d="M8.3 10.4a5.6 5.6 0 1 0 7.9 7.3" />
  </Icon>
);

/** Walking person with a cane (reduced mobility). */
export const CaneWalkerIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="10" cy="4" r="1.8" />
    <path d="M10 7.5 9 13.2" />
    <path d="M9 13.2 7 20.5" />
    <path d="M9 13.2l2.8 3 .6 4.3" />
    <path d="M9.8 9.2 13.6 11.6" />
    <path d="M13.6 11.6c.7-.9 2-.8 2.4.1L18 20.5" />
  </Icon>
);

/** Bed (bedridden). */
export const BedIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M3 6v13" />
    <path d="M3 15h18v4" />
    <path d="M10.5 15v-5h7.5a3 3 0 0 1 3 3v2" />
    <circle cx="6.8" cy="12" r="1.8" />
  </Icon>
);

/** Ear with a slash (cannot hear the alarm). */
export const EarOffIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M7.5 9.5a4.5 4.5 0 0 1 9 0c0 2.4-1.7 3.4-2.8 4.6-1 1.1-1.1 2.5-2.1 3.6a2.7 2.7 0 0 1-4.4-1.1" />
    <path d="M10 9.8a2 2 0 0 1 4 0" />
    <path d="M3.5 3.5l17 17" />
  </Icon>
);

/** Eye with a slash (blind / low vision). */
export const EyeOffIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M2.5 12s3.5-6.5 9.5-6.5 9.5 6.5 9.5 6.5-3.5 6.5-9.5 6.5S2.5 12 2.5 12z" />
    <circle cx="12" cy="12" r="2.8" />
    <path d="M3.5 3.5l17 17" />
  </Icon>
);

/** Oxygen cylinder with a medical cross (oxygen / medical equipment). */
export const OxygenIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="7.5" y="7" width="9" height="14.5" rx="3" />
    <path d="M10 7V4.2h4V7" />
    <path d="M14 5h3" />
    <path d="M12 11v5.5M9.25 13.75h5.5" />
  </Icon>
);

/** Small child (big head, short body). */
export const ChildIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="6" r="2.6" />
    <path d="M12 9.6v5.4" />
    <path d="M8 12.2l4-1.4 4 1.4" />
    <path d="M12 15l-2.3 5M12 15l2.3 5" />
  </Icon>
);

/** Paw print (pet). */
export const PawIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="6.8" cy="10" r="1.7" />
    <circle cx="10.2" cy="6.2" r="1.7" />
    <circle cx="13.8" cy="6.2" r="1.7" />
    <circle cx="17.2" cy="10" r="1.7" />
    <path d="M12 12.3c-2.8 0-5 2.6-5 4.8 0 1.6 1.2 2.4 2.6 2.4 1 0 1.6-.5 2.4-.5s1.4.5 2.4.5c1.4 0 2.6-.8 2.6-2.4 0-2.2-2.2-4.8-5-4.8z" />
  </Icon>
);

/** Telephone handset. */
export const PhoneIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M5.2 3.8h3.3l1.6 4.1-2.1 1.5a11.5 11.5 0 0 0 6.6 6.6l1.5-2.1 4.1 1.6v3.3a1.6 1.6 0 0 1-1.7 1.6A16.2 16.2 0 0 1 3.6 5.5a1.6 1.6 0 0 1 1.6-1.7z" />
  </Icon>
);

/** Padlock (access is logged). */
export const LockIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="5" y="10.5" width="14" height="10" rx="2" />
    <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" />
    <path d="M12 14.5v2.5" />
  </Icon>
);

/** Check mark (safe). */
export const CheckIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M5 12.5l4.5 4.5L19 7.5" />
  </Icon>
);

/** Warning triangle (needs attention). */
export const WarningIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 3.5 2.5 20h19L12 3.5z" />
    <path d="M12 10v4.5" />
    <path d="M12 17.4h.01" />
  </Icon>
);

/** Clock (waiting for an answer). */
export const ClockIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 7.5V12l3 2" />
  </Icon>
);

/** Close (X). */
export const CloseIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M6 6l12 12M18 6 6 18" />
  </Icon>
);

/** Wind / airflow lines (air node, airflow model). */
export const WindIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M3 8.5h10.5a2.5 2.5 0 1 0-2.5-2.5" />
    <path d="M3 12.5h15a2.5 2.5 0 1 1-2.5 2.5" />
    <path d="M3 16.5h7" />
  </Icon>
);

/** Water drop (water node). */
export const DropletIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 3.5s6 6.4 6 10.6a6 6 0 0 1-12 0c0-4.2 6-10.6 6-10.6z" />
  </Icon>
);

/** Generic sensor device (simulated / legacy devices). */
export const SensorIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="6" y="6" width="12" height="12" rx="3" />
    <circle cx="12" cy="12" r="2.2" />
  </Icon>
);

/** Trend: rising. */
export const TrendUpIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4 17l6-6 4 4 6-7" />
    <path d="M15 8h5v5" />
  </Icon>
);

/** Trend: falling. */
export const TrendDownIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4 7l6 6 4-4 6 7" />
    <path d="M15 16h5v-5" />
  </Icon>
);

/** Trend: steady. A level line ending in a point, like the rising / falling lines, with no
 *  arrowhead (a right arrow reads as "open"). */
export const TrendFlatIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4 12h12" />
    <circle cx="18.5" cy="12" r="1.75" />
  </Icon>
);

/** Play. */
export const PlayIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M8 5.5v13l10.5-6.5L8 5.5z" />
  </Icon>
);

/** Pause. */
export const PauseIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M9 5.5v13M15 5.5v13" />
  </Icon>
);

/** Route / path (evacuation). */
export const RouteIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="6" cy="18" r="2" />
    <circle cx="18" cy="6" r="2" />
    <path d="M8 18h7.5a3.5 3.5 0 0 0 0-7h-7a3.5 3.5 0 0 1 0-7H16" />
  </Icon>
);

/** House (apartment invitation). */
export const HomeIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M3.5 11 12 4l8.5 7" />
    <path d="M5.5 9.5V20h13V9.5" />
    <path d="M10 20v-5.5h4V20" />
  </Icon>
);

/** Copy (two sheets). */
export const CopyIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="8.5" y="8.5" width="11" height="11" rx="2" />
    <path d="M15.5 8.5V6a1.5 1.5 0 0 0-1.5-1.5H6A1.5 1.5 0 0 0 4.5 6v8A1.5 1.5 0 0 0 6 15.5h2.5" />
  </Icon>
);

/** Person (occupancy count). */
export const PersonIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="7" r="3.2" />
    <path d="M5.5 20.5a6.5 6.5 0 0 1 13 0" />
  </Icon>
);

/** Bell (alarm self-test). */
export const BellIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 1.5h-15L6 16.5z" />
    <path d="M10 20.5a2.2 2.2 0 0 0 4 0" />
  </Icon>
);

/** Bell with a slash (silence the alarm). */
export const BellOffIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M8.2 5.9A6 6 0 0 1 18 11v4" />
    <path d="M6 10.6v5.9L4.5 18H16" />
    <path d="M10 20.5a2.2 2.2 0 0 0 4 0" />
    <path d="M3.5 3.5l17 17" />
  </Icon>
);

/** Shut-off valve: pipe with a quarter-turn handle (water valve). */
export const ValveIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M2.5 13.5h4M17.5 13.5h4" />
    <path d="M6.5 10.5h11v6h-11z" />
    <path d="M12 10.5V6.5" />
    <path d="M8.5 5h7" />
  </Icon>
);

/** Counter-clockwise arrow around a clock (history). */
export const HistoryIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3L4.5 9" />
    <path d="M4.5 4.5V9H9" />
    <path d="M12 8.5V12l2.5 1.8" />
  </Icon>
);

/** Plus (add). */
export const PlusIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 5v14M5 12h14" />
  </Icon>
);

/** Pencil (edit). */
export const PencilIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M15.5 4.5l4 4L8.5 19.5H4.5v-4l11-11z" />
    <path d="M13 7l4 4" />
  </Icon>
);

/** Trash can (delete). */
export const TrashIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4.5 6.5h15" />
    <path d="M9.5 6.5V4.5h5v2" />
    <path d="M6.5 6.5l1 13h9l1-13" />
    <path d="M10.5 10.5v6M13.5 10.5v6" />
  </Icon>
);

/** Magnifier (search). */
export const SearchIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="10.5" cy="10.5" r="6" />
    <path d="M15 15l5 5" />
  </Icon>
);

/** Stop (square). */
export const StopIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="6.5" y="6.5" width="11" height="11" rx="1.5" />
  </Icon>
);

/** Four-way arrows (drag to move). */
export const MoveIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 3.5v17M3.5 12h17" />
    <path d="M9.5 6 12 3.5 14.5 6M9.5 18l2.5 2.5 2.5-2.5M6 9.5 3.5 12 6 14.5M18 9.5l2.5 2.5-2.5 2.5" />
  </Icon>
);

/** Info (i in a circle). */
export const InfoIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 11v5.5" />
    <path d="M12 7.6h.01" />
  </Icon>
);

/** Cooking pot (kitchen). */
export const PotIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M3.5 10.5h17" />
    <path d="M5.5 10.5v6a3 3 0 0 0 3 3h7a3 3 0 0 0 3-3v-6" />
    <path d="M9.5 7.5c0-1.3 1-1.5 1-3M13.5 7.5c0-1.3 1-1.5 1-3" />
  </Icon>
);

/** Bathtub (bathroom). */
export const BathIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M3 12h18" />
    <path d="M4.5 12v2.5a4.5 4.5 0 0 0 4.5 4.5h6a4.5 4.5 0 0 0 4.5-4.5V12" />
    <path d="M7 12V6.5a2.5 2.5 0 0 1 4.6-1.4" />
    <path d="M7.5 19 6.5 20.5M16.5 19l1 1.5" />
  </Icon>
);

/** Sofa (living room). */
export const SofaIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M5.5 10V8a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v2" />
    <path d="M3.5 17v-4.5a2 2 0 0 1 4 0V14h9v-1.5a2 2 0 0 1 4 0V17z" />
    <path d="M5.5 17v2M18.5 17v2" />
  </Icon>
);

/** Door (hallway). */
export const DoorIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M6.5 20.5v-16h11v16" />
    <path d="M4 20.5h16" />
    <path d="M14.5 12.5h.01" />
  </Icon>
);

/** Stairs (stairwell). */
export const StairsIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M3.5 19.5h4.5V15h4.5v-4.5H17V6h3.5" />
  </Icon>
);

/** Flame (boiler room). */
export const FlameIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 3.5c3 2.6 5.5 6 5.5 9.5a5.5 5.5 0 0 1-11 0c0-2 .9-3.8 2.3-5.2.2 1.7.9 2.8 1.9 3.3-.2-2.8.3-5.4 1.3-7.6z" />
  </Icon>
);

/** Two stacked server units (a hub Pi). */
export const ServerIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="4" y="4.5" width="16" height="6.5" rx="1.8" />
    <rect x="4" y="13" width="16" height="6.5" rx="1.8" />
    <path d="M7.5 7.75h.01M7.5 16.25h.01" />
    <path d="M11 7.75h5.5M11 16.25h5.5" />
  </Icon>
);

/** Processor chip with pins (the AI HAT+ 2 accelerator). */
export const ChipIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="6.5" y="6.5" width="11" height="11" rx="1.8" />
    <rect x="9.5" y="9.5" width="5" height="5" rx="0.8" />
    <path d="M9.5 3.5v3M14.5 3.5v3M9.5 17.5v3M14.5 17.5v3M3.5 9.5h3M3.5 14.5h3M17.5 9.5h3M17.5 14.5h3" />
  </Icon>
);

export const SunIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="4" />
    <path d="M12 2.5v2.2M12 19.3v2.2M2.5 12h2.2M19.3 12h2.2M5.3 5.3l1.5 1.5M17.2 17.2l1.5 1.5M5.3 18.7l1.5-1.5M17.2 6.8l1.5-1.5" />
  </Icon>
);

export const MoonIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M20 14.2A8 8 0 0 1 9.8 4a8 8 0 1 0 10.2 10.2z" />
  </Icon>
);

export const BuildingIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="5" y="3" width="14" height="18" rx="1.5" />
    <path d="M9 7.5h1.5M13.5 7.5H15M9 11.5h1.5M13.5 11.5H15M10 21v-4.5h4V21" />
  </Icon>
);

export const SirenIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M7 17v-4.5a5 5 0 0 1 10 0V17" />
    <path d="M5 17h14v3.5H5z" />
    <path d="M12 3v1.8M4.2 6.2l1.3 1.3M19.8 6.2l-1.3 1.3" />
  </Icon>
);

export const SlidersIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4 7h9M17 7h3M4 17h3M11 17h9" />
    <circle cx="15" cy="7" r="2" />
    <circle cx="9" cy="17" r="2" />
  </Icon>
);

export const SignOutIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M14 4h4.5A1.5 1.5 0 0 1 20 5.5v13a1.5 1.5 0 0 1-1.5 1.5H14" />
    <path d="M10 8l-4 4 4 4M6 12h9" />
  </Icon>
);

/** Arrow up (higher than usual). */
/** Chevron right: after the label of a link that leads to another page. */
export const ChevronRightIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M9 5.5l6.5 6.5L9 18.5" />
  </Icon>
);

export const ArrowUpIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 19V5.5" />
    <path d="M6 11.5l6-6 6 6" />
  </Icon>
);

/** Arrow down (lower than usual). */
export const ArrowDownIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 5v13.5" />
    <path d="M6 12.5l6 6 6-6" />
  </Icon>
);

/** Dotted ring (still learning: nothing to compare against yet). */
export const DashedCircleIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="7.5" strokeDasharray="1.6 3.3" />
  </Icon>
);

/** Dashed line (no data). */
export const DashedLineIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4.5 12h15" strokeDasharray="2.6 3.4" />
  </Icon>
);

/** Activity pulse (motion detected). */
export const ActivityIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M3 12h4l2.5-6 4 12 2.5-6H21" />
  </Icon>
);
