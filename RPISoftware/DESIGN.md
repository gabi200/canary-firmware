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
rounded:
  sm: "6px"
  md: "8px"
  pill: "999px"
spacing:
  gap-xs: "6px"
  gap-sm: "10px"
  gap-md: "16px"
  pad: "24px"
  pad-narrow: "16px"
  rail-width: "232px"
  utility-bar-height: "52px"
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

## Elevation & Depth

Flat and tonal. Depth is three surface steps plus 1px hairlines. Shadows are reserved for things that float above the page: popovers and tooltips (`0 8px 24px rgba(0,0,0,.5), 0 1px 2px rgba(0,0,0,.4)`; light `rgba(20,23,28,.12)`), and the command view and dialogs (`0 24px 64px rgba(0,0,0,.6), 0 2px 6px rgba(0,0,0,.4)`; light `.22`). Scrim is rgba(4,6,9,.68), light rgba(20,23,28,.42). Selection is a 1px accent ring, not a glow.

### Named Rules
**The Flat Surface Rule.** Cards, tiles and cells never carry a shadow at rest. Only overlays do.
**The No-Glow Rule.** No glows, no coloured side stripes. A selected item uses the accent border plus a 1px ring.

## Shapes

8px (`--radius`) for cards, tiles, banners and wells; 6px (`--radius-sm`) for buttons, inputs, pills, chips, nav items and state cells; 999px for count badges, switches, progress bars and the priority status pill; 4px for small tags and segment buttons. Overlays (command view, dialog) use 12px. Hairlines are 1px; selection rings are 1px; focus rings are 2px offset 2px. The evacuation banner is square (radius 0) with its tape borders.

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

## Do's and Don'ts

### Do:
- **Do** use green, amber and red only for state, always as a dot or fill plus text, with a soft tint behind it.
- **Do** use the `-text` step of a colour for text and the solid step for dots, fills and borders.
- **Do** keep blue for action and selection, and one primary button per panel.
- **Do** build both themes from the same token names; add a light value whenever a dark one is added.
- **Do** compact long repeated lists into state cells or matrices, keeping the full sentence as tooltip and accessible name.
- **Do** separate chart series by dash pattern as well as by colour, and keep series to the five data colours.
- **Do** honour `prefers-reduced-motion` for every pulse.

### Don't:
- **Don't** use state colours to decorate or categorise.
- **Don't** use blue or violet for hazard, or green / amber / red for series.
- **Don't** add glows, coloured side stripes, or shadows at rest.
- **Don't** add uppercase labels, eyebrows or kickers.
- **Don't** treat Demo mode as a hazard state; keep its badge neutral and outlined.
- **Don't** use the black-and-amber tape or deep red outside evacuation.
- **Don't** introduce a fourth surface step or a radius beyond 4, 6, 8 and 12.
