---
name: Canary Operations Console
description: A quiet, two-theme operations console where colour means state and nothing else.
colors:
  accent: "#3b7cf0"
  accent-text: "#7aa9ff"
  on-accent: "#ffffff"
  ground: "#0c0e11"
  rail: "#0f1215"
  panel: "#13161a"
  raised: "#1a1e24"
  well: "#0f1215"
  hairline: "#23282f"
  hairline-strong: "#323943"
  text: "#e8eaed"
  text-secondary: "#b9bfc8"
  muted: "#8b94a1"
  safe: "#2fa84f"
  safe-text: "#56c878"
  attention: "#d4a11e"
  attention-text: "#e3b54a"
  on-attention: "#1c1503"
  alarm: "#d93a40"
  alarm-text: "#ff7b72"
  evacuation: "#a8231f"
  alarm-fill: "#cc363f"
  on-alarm: "#ffffff"
  on-alarm-ok: "#6fdc8f"
  on-alarm-warn: "#f0c458"
  priority: "#7a55e0"
  priority-text: "#b9a2ff"
  series-blue: "#5b93ff"
  series-sky: "#9ccfff"
  series-cyan: "#2fc3d6"
  series-teal: "#4fd1b5"
  series-slate: "#a3adbb"
  hazard-tape-black: "#111111"
  hazard-tape-amber: "#e0aa1c"
  wordmark-dot: "#f2c417"
  safe-fill: "#1c7f39"
typography:
  display:
    fontFamily: "Inter Variable, Inter, ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "40px"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "-0.03em"
  headline:
    fontFamily: "Inter Variable, Inter, ui-sans-serif, system-ui, sans-serif"
    fontSize: "24px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Inter Variable, Inter, ui-sans-serif, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1.45
    letterSpacing: "-0.011em"
  body:
    fontFamily: "Inter Variable, Inter, ui-sans-serif, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.45
    fontFeature: "tabular-nums"
  label:
    fontFamily: "Inter Variable, Inter, ui-sans-serif, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.25
  mono:
    fontFamily: "ui-monospace, SFMono-Regular, Cascadia Mono, Menlo, Consolas, monospace"
    fontSize: "0.92em"
    fontWeight: 400
  mobile-alarm-title:
    fontFamily: "Inter"
    fontSize: "28px"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.02em"
    fontFeature: "tnum"
  mobile-headline:
    fontFamily: "Inter"
    fontSize: "24px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.02em"
    fontFeature: "tnum"
  mobile-banner-title:
    fontFamily: "Inter"
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "-0.015em"
    fontFeature: "tnum"
  mobile-title:
    fontFamily: "Inter"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.4
    letterSpacing: "-0.011em"
    fontFeature: "tnum"
  mobile-body:
    fontFamily: "Inter"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.45
    fontFeature: "tnum"
  mobile-label:
    fontFamily: "Inter"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.25
    fontFeature: "tnum"
  mobile-button:
    fontFamily: "Inter"
    fontSize: "16px"
    fontWeight: 600
    lineHeight: 1.25
rounded:
  sm: "6px"
  md: "8px"
  pill: "999px"
  tag: "4px"
  overlay: "12px"
spacing:
  gap-xs: "6px"
  gap-sm: "10px"
  gap-md: "16px"
  pad: "24px"
  pad-narrow: "16px"
  rail-width: "232px"
  utility-bar-height: "52px"
  mobile-bar-height: "52px"
  mobile-nav-height: "64px"
  mobile-gutter: "16px"
  room-grid-gap: "8px"
  room-tile-min: "150px"
  touch-target: "48px"
components:
  card:
    backgroundColor: "{colors.panel}"
    rounded: "{rounded.md}"
    padding: "16px"
  well:
    backgroundColor: "{colors.well}"
    rounded: "{rounded.md}"
    padding: "10px 12px"
  button:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    rounded: "{rounded.sm}"
    padding: "5px 12px"
    height: "32px"
  button-hover:
    backgroundColor: "{colors.raised}"
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.sm}"
    padding: "5px 12px"
    height: "32px"
  button-danger:
    backgroundColor: "{colors.alarm}"
    textColor: "#ffffff"
    rounded: "{rounded.sm}"
  button-warn:
    backgroundColor: "{colors.attention}"
    textColor: "{colors.on-attention}"
    rounded: "{rounded.sm}"
  button-large:
    padding: "8px 16px"
    height: "40px"
    rounded: "{rounded.sm}"
  input:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    rounded: "{rounded.sm}"
    padding: "6px 10px"
  pill:
    textColor: "{colors.safe-text}"
    rounded: "{rounded.sm}"
    padding: "2px 8px"
  pill-evacuation:
    backgroundColor: "{colors.evacuation}"
    textColor: "#ffffff"
    rounded: "{rounded.sm}"
  scope-chip-selected:
    textColor: "{colors.text}"
    rounded: "{rounded.sm}"
    height: "32px"
  nav-item:
    textColor: "{colors.text-secondary}"
    rounded: "{rounded.sm}"
    height: "34px"
    padding: "0 10px"
  nav-item-active:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.text}"
  state-cell:
    backgroundColor: "{colors.well}"
    textColor: "{colors.muted}"
    rounded: "{rounded.sm}"
    size: "30px"
  incident-banner:
    backgroundColor: "{colors.alarm-fill}"
    textColor: "{colors.on-alarm}"
    rounded: "{rounded.md}"
    padding: "18px 20px"
  incident-banner-detection:
    backgroundColor: "{colors.attention}"
    textColor: "{colors.on-attention}"
    rounded: "{rounded.md}"
    padding: "18px 20px"
  incident-banner-evacuation:
    backgroundColor: "{colors.evacuation}"
    textColor: "{colors.on-alarm}"
    rounded: "{rounded.md}"
    padding: "22px 20px 18px"
  mobile-app-bar:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.text}"
    typography: "{typography.mobile-title}"
    height: "{spacing.mobile-bar-height}"
  mobile-nav-bar:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.muted}"
    typography: "{typography.mobile-label}"
    height: "{spacing.mobile-nav-height}"
  mobile-nav-indicator:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.accent-text}"
    rounded: "{rounded.sm}"
  mobile-button-filled:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    typography: "{typography.mobile-button}"
    rounded: "{rounded.sm}"
    padding: "12px 16px"
    height: "48px"
  mobile-button-outlined:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    rounded: "{rounded.sm}"
    padding: "10px 14px"
    height: "44px"
  status-block:
    textColor: "{colors.text}"
    typography: "{typography.mobile-headline}"
    rounded: "{rounded.md}"
    padding: "16px 16px 18px"
  room-tile:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    rounded: "{rounded.md}"
    padding: "12px"
    width: "{spacing.room-tile-min}"
  safety-sign-disc:
    backgroundColor: "#ffffff"
    rounded: "{rounded.pill}"
    size: "44px"
  where-now-answer:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    rounded: "{rounded.sm}"
    padding: "12px 16px"
    height: "56px"
  check-in-safe:
    backgroundColor: "{colors.safe-fill}"
    textColor: "{colors.on-alarm}"
    rounded: "{rounded.sm}"
    height: "56px"
  check-in-help:
    backgroundColor: "{colors.alarm-fill}"
    textColor: "{colors.on-alarm}"
    rounded: "{rounded.sm}"
    height: "48px"
---

# Design System: Canary Operations Console

## Overview

**Creative North Star: "The Quiet Console"**

A building-safety operations console for a dispatcher under time pressure, with a manager and a technician behind them. Cool near-neutral surfaces, 1px hairlines, one blue accent, precise Inter type with tabular numerals. It sits alongside Linear / Vercel in restraint and UniFi / Home Assistant in device cards and floor maps. Dark is the default; light is a full second theme on the same token names.

Colour means state and nothing else. Green, amber and red appear only as a state dot, a solid fill or a soft tint. Blue marks action and selection. Violet is reserved for priority residents. With every other surface held neutral, an alarm is the loudest thing on any screen. Hazard language is carried by more than hue: shape, text, dash pattern and ISO pictograms always accompany colour.

The shell reports building state on every page: the incident count badge on the Dispatch destination in the rail.

**Key Characteristics:**
- Three surface steps (ground, panel, raised) separated by 1px hairlines, not shadows.
- 8px containers, 6px controls.
- State colour has three steps each: solid (dots, fills, borders), text, soft tint. Text steps are re-tuned per theme to hold contrast.
- Long repeated lists collapse into compact state cells and matrices with the full sentence on tooltip and accessible name.
- Evacuation is the one place the system gets loud: deep red, a slim black-and-amber tape strip, ISO pictograms.

**The phone, same world.** The resident app (`mobile/`, Flutter) runs on these tokens and rules; it is a phone adaptation of the Quiet Console, not a second world. Home is one status block, then the rooms as plain labelled cards, inside three bottom tabs (Home, Household, Settings). Under alarm the whole phone takes the incident-banner language full-screen. Unlike the dashboard, the phone follows the device's light / dark setting by default (Settings can pin light or dark); both themes are complete on the same names.

## Colors

Cool, near-neutral and state-first. Values below are the dark theme (`:root`); the light theme (`:root[data-theme="light"]`) overrides the same names, with its values in the sidecar.

### Primary
- **Action Blue** (#3b7cf0): primary buttons, the selected scope chip, input focus, active tab underline. Light theme #2563eb.
- **Action Blue Text** (#7aa9ff): links, focus ring, active nav icon. Light #1d55cf.

### Secondary (state)
- **Safe Green** (#2fa84f) with text (#56c878): normal, fresh, resolved, connected.
- **Attention Amber** (#d4a11e) with text (#e3b54a) and on-amber ink (#1c1503): warning, stale, suspect, detection.
- **Alarm Red** (#d93a40) with text (#ff7b72): alarm, escalation, lost, danger. The incident banner uses its own **Alarm Fill** (#cc363f, white text at 5:1 or better) for alarm, escalation and any unknown state; Alarm Red stays for other surfaces.
- **Evacuation Deep Red** (#a8231f): evacuation banner and pill only. Owner-pinned.
- **On-alarm status** (ok #6fdc8f, warn #f0c458): status text on the banner chips. Banner scrims are black at 28%, 40% and 78% (`--scrim-1..3`); dividers are white 22% on red and black 20% on amber. Same in both themes.

### Tertiary
- **Priority Violet** (#7a55e0, text #b9a2ff): priority residents panel only.

### Neutral
- **Ground** (#0c0e11): page and utility bar. **Rail** (#0f1215): left rail. **Panel** (#13161a): cards. **Raised** (#1a1e24): hover, active nav, selected segment. **Well** (#0f1215): inset surfaces (tiles, charts, code).
- **Hairline** (#23282f) and **Hairline Strong** (#323943): 1px borders and control outlines.
- **Text** (#e8eaed), **Text Secondary** (#b9bfc8), **Muted** (#8b94a1).

### Data series
Chart series are restricted to Series Blue (#5b93ff), Sky (#9ccfff), Cyan (#2fc3d6), Teal (#4fd1b5) and Slate (#a3adbb), so a series never reads as a state or as a priority resident. Series sharing a chart are separated by dash pattern (for example "10 5"), not hue alone.

### Hazard tape
Black (#111111) and amber (#e0aa1c) 45-degree stripes, 8px each, in one 4px strip along the top edge of the active-evacuation banner only, clipped by the panel radius (no border-image, none at the bottom). The Canary wordmark keeps its yellow dot (#f2c417 dark, #d99a00 light).

### Named Rules
**The State-Only Colour Rule.** Green, amber and red mean state. They never decorate, never mark a category, never fill a series.
**The One Blue Rule.** Blue means "you can act on this" or "this is selected". Motion cells use blue as selection-like info, never as a hazard.
**The Neutral Demo Rule.** The Demo badge is a neutral outlined pill (Text Secondary on Hairline Strong). Demo is not a hazard state.

### Mobile (Flutter)
Same values in both themes, split across two classes in `lib/src/theme.dart`. `CanaryPalette` (a `ThemeExtension`, read as `context.palette`) carries the neutrals, Action Blue and the `-text` steps per theme under the token names above (`ground`, `panel`, `raised`, `well`, `hairline`, `hairlineStrong`, `text`, `textSecondary`, `muted`, `accent`, `accentText`, `safeText`, `attentionText`, `alarmText`, `wordmarkDot`). `HazardColors` carries the solids, identical in both themes: `normal` (Safe Green), `warning` (Attention Amber), `alarm` (Alarm Red), `evacuation`, `alarmFill`, `info` (Action Blue), `unknown` (Muted), `onAlarmOk`, `onAlarmWarn`, `tapeBlack`, `tapeAmber`. `bannerFill(state)` and `onBanner(state)` pick the incident fill and its ink. The Material `ColorScheme` is derived, never seeded: primary is Action Blue, surface is Ground, surfaceContainerLow is Panel, surfaceContainerHigh is Raised, outline is Hairline Strong, outlineVariant is Hairline, error is Alarm Red, surface tint is transparent.

- **Deepened Safe Green** (#1c7f39): the fill of the alarm screen's "I'm out and safe" button only, where white 18px text on Safe Green would fall below 4.5:1.
- **Soft tint and state border, as built:** `palette.tint(solid)` alpha-blends the solid over Panel at 22/255 light, 28/255 dark (pills 34, selected chips and answers 34 to 46); `palette.stateBorder(solid)` is the solid at alpha 140 light, 120 dark. `palette.ink(solid)` returns the theme's `-text` step for any state solid.

**The Shape-And-Colour Mark Rule.** On the phone every state mark is a shape as well as a colour: a dot for normal, a rounded square for attention, a triangle for alarm, evacuation and danger, a 1.6px ring for unknown or offline. The status block, room tiles and scope chips all use it.
**The Needs-A-Look Tint Rule.** Room tiles and reading cells stay on Panel or Well while normal. Only attention and danger take the soft tint, the state border and state-coloured text.

## Typography

**Display, Body and Label Font:** Inter Variable (self-hosted via `@fontsource-variable/inter`), falling back to Inter, ui-sans-serif, system-ui, Segoe UI, Roboto.
**Mono:** the system monospace stack, for device ids, raw JSON and evidence chips only.

**Character:** One family at a tight, functional scale. Tabular numerals are on globally so counts and readings do not jitter as they update. Headings are 600 with slight negative tracking; sentence case everywhere.

### Hierarchy
- **Display** (600, 40px, 1, -0.03em): command-view hero statistic.
- **Headline** (600, 24px, 1.15, -0.02em): incident banner title (20px on narrow), tile values, command values; 32px for dashboard metric counts; 28px for the command-view title.
- **Title** (600, 14px, 1.45): card headings, topbar title, section titles. Page h2 is 20px and shows only when the utility bar drops the page name (640px and below).
- **Body** (400, 14px, 1.45): default text; 13px for secondary lines. Prose caps at 75ch.
- **Label** (500, 12px): muted captions, field labels, table heads, tile labels, in sentence case.

### Named Rules
**The Sentence Case Rule.** Labels are sentence case at 12px muted. No uppercase, no tracked-out eyebrows or kickers.
**The Tabular Rule.** Numbers are tabular everywhere; never swap in a proportional face for a figure.

### Mobile (Flutter)
**Font:** Inter, bundled as static TTFs at 400, 500, 600 and 700 in `mobile/assets/fonts/inter` (OFL licence alongside), declared as family `Inter` in `pubspec.yaml` and set as the theme's `fontFamily`. It ships inside the app, so alarm text renders in Inter with no network. Tabular figures are on every text-theme style; letter-spacing is the console's em value times the size.

Hierarchy as built (`TextTheme`):
- **Alarm title** (700, 28px, 1.15, -0.02em; `displaySmall` at 700): the full-screen alarm's hazard name or evacuation command.
- **Headline** (600, 24px, 1.15, -0.02em; `headlineMedium`): status block title; the manager dashboard's evacuation banner title.
- **Banner title** (600, 20px, 1.2, -0.015em; `headlineSmall`): incident banner title on Home and in lists, the where-now question.
- **Title large** (600, 18px, 1.3; `titleLarge`): dialog titles, the alarm's where-line.
- **Title** (600, 15px, 1.4, -0.011em; `titleMedium`): app bar title, status subtitle, sensor headlines. Room names are 600 at 15px.
- **Section title** (600, 14px, 1.45; `titleSmall`): section heads and panel-row titles.
- **Body** (400, 1.45): 15px `bodyLarge`, 14px `bodyMedium` default, 13px `bodySmall` in Text Secondary for room lines and hints.
- **Label** (500, 12px, Muted; `labelMedium`; 11px `labelSmall`): state lines, captions, the Demo badge. Buttons are 14px at 600 (`labelLarge`), 16px on filled buttons, 17 to 18px on the alarm's answers and check-in.

The phone reads one step larger than the console at body and title (15px against 14px). Display 40 and 32 keep the console's values.

**The Bundled Face Rule.** The phone never falls back to the platform face: every style names Inter, and the four weights ship in the app.

## Layout

A two-column shell: a 232px sticky left rail (wordmark, four destinations with icons, then connection state, building, role and sign out at the foot) and a main column with a sticky 52px utility bar (page name left; Demo badge, Demo / Real switch, language and theme switches right). Content is capped at 1480px with 24px padding and starts directly under the bar. On Dispatch the incident banner is the first block and the Evacuate action stays in the first screen. The apartment / room scope bar pins under the utility bar.

Grids use a 16px gap with 8 to 12px inside cards and rows. Two-column (1.4fr / 1fr), three-column and even two-column grids exist.

Responsive behaviour:
- 1100px and below: 4 and 5 column forms drop to 3; command stats go to 3 columns.
- 1000px and below: grids go to one column; on Dispatch the actions and roster move ahead of the map; the three incident counts stay on one row.
- 900px and below: padding 16px; the rail becomes a two-row top block (brand, connection, sign out; then destinations as a tab row with a 2px accent underline on the active one); the utility bar is no longer sticky; the scope bar pins at the top.
- 760px and below: the command view is full-screen.
- 640px and below: nav icons and the topbar title hide and the in-page title returns; the scope bar becomes one swipeable row (floor | apartment | room) with 40px chips; admin tabs scroll.
- 560px and below: fusion grids, device-health rows and firmware targets stack to one column. Floor-plan tile rows that hold no overlay compact when the plan itself is 560 CSS px wide or less (a width measured in JS from the plan, not a viewport media query).

Scrolling segmented controls fade at the cut-off edge via `data-overflow`.

### Mobile (Flutter)
One column on Ground with 16px gutters under a 52px app bar (Ground, 1px Hairline below, 16px title inset): the 8px wordmark dot and the home's unit title on the left, the neutral Demo badge on the right. A 64px bottom navigation bar (Ground, 1px Hairline above) holds Home, Household and Settings; the tabs stay mounted, so the alarm listener runs on every tab.

Home order: the status block first; while calm, the emergency-profile row 12px below; 20px to the first section. Sections open with a 44px fold header: a 14px/600 title with a chevron that folds the section, and an optional blue text link on the right, capped at half the width. Room cards sit in rows with 8px gaps; the column count is the width over a 150px minimum scaled by the user's text size, from one to three (two on a phone at default text). A room's sensors open inline, full width under its row, with a 200ms ease-out size change. Reading cells pair two to a row with 10px gaps.

With several apartments in scope a header pins under the bar: horizontally scrolling chip rows (52px minimum, grown with text size), 8px between chips, 16px side inset, a Hairline below; the selected chip scrolls into view.

Touch targets are 48px (44px minimum on outlined and text buttons). Button labels and room lines stay on one line (room lines are joined with non-breaking spaces); a button pair sits side by side only when both labels fit at the current width and text size, otherwise both stack full width. This keeps Romanian labels whole.

The alarm screen is full-screen with no tabs: the state fill runs edge to edge behind the status bar; the body follows on Ground (20px top, 16px sides, 24px bottom); a fixed check-in bar sits at the bottom, capped at 48% of the screen height and scrolling inside.

## Elevation & Depth

Flat and tonal. Depth is three surface steps plus 1px hairlines. Shadows are reserved for things that float above the page: popovers and tooltips (`0 8px 24px rgba(0,0,0,.5), 0 1px 2px rgba(0,0,0,.4)`; light `rgba(20,23,28,.12)`), and the command view and dialogs (`0 24px 64px rgba(0,0,0,.6), 0 2px 6px rgba(0,0,0,.4)`; light `.22`). Scrim is rgba(4,6,9,.68), light rgba(20,23,28,.42). Selection is a 1px accent ring, not a glow.

### Named Rules
**The Flat Surface Rule.** Cards, tiles and cells never carry a shadow at rest. Only overlays do.
**The No-Glow Rule.** No glows, no coloured side stripes. A selected item uses the accent border plus a 1px ring.

### Mobile (Flutter)
Cards, the app bar, the navigation bar and all buttons are elevation 0 with surface tint off; depth is tone and hairline. Bottom sheets are Panel with 12px top corners and a Hairline Strong drag handle; dialogs are Panel, 12px, with a Hairline border; popup menus and tooltips are Panel with a Hairline Strong border.

## Shapes

8px (`--radius`) for cards, tiles, banners and wells; 6px (`--radius-sm`) for buttons, inputs, pills, chips, nav items and state cells; 999px for count badges, switches, progress bars and the priority status pill; 4px for small tags and segment buttons. Overlays (command view, dialog) use 12px. Hairlines are 1px; selection rings are 1px; focus rings are 2px offset 2px. The evacuation banner is square (radius 0) with its tape borders.

### Mobile (Flutter)
`CanaryRadius`: `container` 8, `control` 6, `tag` 4 (count tags in scope chips, checkboxes), `overlay` 12 (sheets, dialogs). Pills and every button are 6px; the phone has no fully rounded buttons. ISO signs on red and amber sit on white circles, the sign at 70% of the disc. The incident banner keeps its 8px radius in every state on the phone; the full-screen alarm header is full-bleed and square.

## Components

### Buttons
- **Shape:** 6px, 32px tall (40px large, 28px small), 1px border.
- **Default:** panel fill, Hairline Strong border, Text. Hover raises to Raised with a Muted border.
- **Primary:** Action Blue fill, white text; hover brightens. One primary per panel.
- **Danger / Warn:** solid Alarm Red with white text; solid Amber with on-amber ink. **Danger outline** is transparent with a red border.
- **Disabled:** Raised fill, Hairline border, Muted text.
- Icons are 17 to 18px inline SVG with 6px gap.

### Chips and pills
- **Pills:** 6px, 12px/600, state text on soft tint (green, amber, red); Evacuation is solid deep red with white text; unknown and quiet are muted with an outline; the Demo badge is a neutral outline.
- **Scope chips:** 32px, panel fill; selected is accent border, accent-soft fill and a 1px accent ring.
- **Segmented control:** well track, 2px inset; active segment is Raised with a Hairline Strong ring.

### Cards / Containers
- 8px, Panel fill, 1px Hairline, 16px padding, 14px/600 heading. Insets (tiles, charts) use Well fill. Banner cards for alerts use the state border plus soft tint fill.

### Inputs / Fields
- 6px, Panel fill, Hairline Strong border, 6px 10px padding; hover Muted border; focus Accent border with a 3px accent-soft ring; error red border; disabled 55% opacity. Labels 13px/500 Text Secondary.

### Navigation
- Rail items 34px, 6px radius, 14px/500 Text Secondary; hover and active use Raised; active is 600 with an accent icon. A red count badge on Dispatch shows open incidents. At 900px and below, items become a tab row with a 2px accent underline.

### Incident banner
- One shared component (`IncidentBanner`) used by Dispatch and Manager: a contained panel, 8px radius, overflow clipped. Fill by state: Alarm Fill (#cc363f) for alarm, escalation and any unknown state; amber with dark ink for detection and verification; deep red for evacuation, which alone adds the 4px tape strip along the top.
- Pictograms are one size, 48px (40px at 640px and below), in white circles so prohibition rings stay visible on red. Headline is 24px (20px at 640px and below) 600 with tags inline. Incident-line segments never break internally and use tabular numerals.
- Priority alert and escalation line are chips on a scrim (40% black on red, 78% on amber). Advice signs sit in a darker band (scrim ink mixed 18% into the fill, 10% on amber) in equal cells split by translucent dividers; the cells stack at 640px and below.
- Motion is one calm signal: only the exit pictogram pulses (scale 1.06, opacity 0.88, 1.2s). Background and hazard sign stay still; everything is still under reduced motion.

### Compact state cells and matrices
- The pattern for long repeated lists. A 30px square cell (26px in tables, 16px mark) with a 6px radius and 1px border, one tone via `data-tone`: danger (red), attention (amber), motion (blue), quiet and none (neutral; none is dashed). Each cell carries the full sentence as tooltip and accessible name. Used in device health (one row per apartment, one cell per sensor needing attention), the room-normal matrix (sticky first column, 66px minimum metric columns), and the motion grid of room boxes (150px minimum). A small legend sits below. Evidence is grouped as monospace chips.

### Floor plan and charts
- SVG plan on theme-aware `--fp-*` tokens; affected rooms use a 6 4 dash, common areas 4 4, unavailable motion 3 3; the source is a white-ringed dot with a pulse (static under reduced motion). Tooltips are Panel with a Hairline Strong border.
- Charts sit in Well cards with 13px/600 titles, series limited to the five data colours separated by dash pattern.

### Mobile shell and navigation
- **App bar:** 52px, Ground, Hairline below, no elevation. Wordmark dot (8px, Wordmark Yellow) then the unit title at 15px/600; actions hold the Demo badge (6px, Hairline Strong outline, 12px/500 Text Secondary).
- **Bottom navigation:** 64px, Ground, Hairline above, labels always shown at 12px. Selected: a Raised 6px indicator, Action Blue Text icon (22px, outlined swaps to filled), Text label at 600. Unselected: Muted icon and label at 500.

### Status block
- The first block on Home and on the manager dashboard. Soft state tint over Panel, 1px state border, 8px, padding 16px 16px 18px. A state line (9px state mark and 12px/600 in the state's text step; on Home it says Live or Reconnecting), a 24px/600 headline, an optional 15px/600 subtitle, one 14px line in Text Secondary.
- Green when calm; amber for verifying and attention; red for danger; Muted with the ring mark for unknown and loading. Under an alarm, Home swaps it for the incident banner.
- **Secondary form:** under the dashboard's own block, an all-normal summary collapses to one Panel row (Hairline, state mark, one Text Secondary line), so all clear is said once; any other state shows the full block.

### Room tiles
- Panel, 1px Hairline, 8px, 12px padding. Name at 15px/600 top left, 9px state mark top right, a muted "common area" label when shared, then one 13px line at the foot: the state word and the approximate temperature.
- Normal tiles keep the line Muted. Attention and danger take the soft tint, the state border and the line in the state's text step at 600; an incident in the room thickens the border to 1.5px. Offline rooms take the ring mark.
- Tapping the tile opens the room; a 48px chevron button at the bottom right opens its sensors inline.

### Panel row
- A Card row for one prompt (the emergency-profile hint): 14px/600 title and a 13px Muted line, a small outlined action (36px tall, 6px), a Muted 20px close. Shown only while calm.

### Buttons (mobile)
- **Filled:** Action Blue, white 16px/600, 48px tall, full width by default, 6px. Disabled is Raised with Muted text.
- **Outlined:** Panel fill, Hairline Strong 1px, Text at 14px/600, 44px minimum, 6px.
- **Text:** Action Blue Text, 44px minimum; used for section links, Change and Minimize.
- On a filled banner the action inverts: a white filled button in the fill's colour.

### Status pills (mobile)
- 6px, 8px by 3px, 12px/600, sentence case (state labels are stored lower case for use inside sentences and capitalised when they stand alone). The state's text step on its tint; evacuation alone is solid Evacuation Deep Red with white text.

### Scope chips (mobile)
- 6px, Panel fill, Hairline Strong; selected is a 1.5px Action Blue border over the blue tint with the label at 600. Each chip leads with a state mark (11px when flagged, 9px otherwise), then a 16px label and a 4px Raised count tag at 13px/600 Text Secondary.

### Reading cells
- Divided by a 1px Hairline top rule, not boxed. 13px/600 Muted label, 28px/600 value with a 15px/600 Muted unit, 12px Muted caption. Only readings that need a look take a soft tint (alpha 20); normal and info stay on the inset.

### Incident banner (mobile)
- The same fill logic as the dashboard (`HazardColors.bannerFill` / `onBanner`). 8px, clipped, 16px padding (18px top under the tape). 44px sign discs (exit sign first when evacuating), a 20px/600 title, the where-line at 15px/600, then one line of what not to do; on Home a white filled button leads into the alarm screen.
- The manager dashboard's evacuation banner uses 48px discs and a 24px title; only its exit sign pulses (1.2s, scale 1.06, opacity 0.88), still when the phone asks for reduced motion.

### Full-screen alarm
- **Header on the state fill:** a Live chip on a 28% black scrim (6px; dot in On-alarm ok, the offline icon in On-alarm warn), a Minimize text button, 52px sign discs beside the 28px/700 title, the where-line at 18px/600 and a 15px/500 line saying where the resident is. The tape runs along the top when evacuating.
- **Advice band:** the fill darkened by 18% black, 16px by 14px, 42px advice discs and a 15px/600 line.
- **Where-now card:** Panel, Hairline Strong, 8px, 16px padding; a 20px/600 question and three outlined answers, 56px tall, 17px/600 with Action Blue Text icons. The selected answer takes a 1.5px Action Blue border over the blue tint. Once answered it shows one line with a Change link and the advice for that answer.
- **Check-in bar:** Panel with a Hairline Strong top border. "I'm out and safe" is 56px Deepened Safe Green with white 18px/600 and the assembly-point sign; "I need help" (Alarm Fill, 48px) and "Call 112" (outlined) sit side by side when both fit; a text button covers safe but still inside. After check-in it is one line with a green check and Change.

## Do's and Don'ts

### Do:
- **Do** use green, amber and red only for state, always as a dot or fill plus text, with a soft tint behind it.
- **Do** use the `-text` step of a colour for text and the solid step for dots, fills and borders.
- **Do** keep blue for action and selection, and one primary button per panel.
- **Do** build both themes from the same token names; add a light value whenever a dark one is added.
- **Do** compact long repeated lists into state cells or matrices, keeping the full sentence as tooltip and accessible name.
- **Do** separate chart series by dash pattern as well as by colour, and keep series to the five data colours.
- **Do** honour `prefers-reduced-motion` for every pulse.
- **Do** pair every state colour on the phone with its shape mark: dot, square, triangle, ring.
- **Do** keep room tiles and reading cells neutral while normal; tint only what needs a look.
- **Do** follow the phone's light / dark setting by default, and keep both `CanaryPalette` themes complete.
- **Do** send state text through `palette.ink()` and tints through `palette.tint()`, never a raw solid on Panel.
- **Do** keep tap targets at 48px and let button pairs stack when their labels would not fit on one line.

### Don't:
- **Don't** use state colours to decorate or categorise.
- **Don't** use blue or violet for hazard, or green / amber / red for series.
- **Don't** add glows, coloured side stripes, or shadows at rest.
- **Don't** add uppercase labels, eyebrows or kickers.
- **Don't** treat Demo mode as a hazard state; keep its badge neutral and outlined.
- **Don't** use the black-and-amber tape or deep red outside evacuation.
- **Don't** introduce a fourth surface step or a radius beyond 4, 6, 8 and 12.
- **Don't** let Material defaults back in on the phone: no seeded colour scheme, no surface tint, no resting elevation, no fully rounded buttons.
- **Don't** use Deepened Safe Green outside the check-in button.
