import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../logic/sensor_series.dart';
import '../../models/history.dart';
import '../../models/summary.dart';
import '../../state/history_providers.dart';
import '../../theme.dart';

// Home-Assistant-style sensor tiles for residents: a big value, one plain word,
// a small chart of the window. Units are symbols, not words, so they are not
// translated; raw device counts (gas / water probe ADC) are never shown.

const _unitC = '°C';
const _unitPercent = '%';
const _unitUgm3 = 'µg/m³';
const _unitPpm = 'ppm';

Color toneColor(Tone? tone) => switch (tone) {
      Tone.ok => HazardColors.normal,
      Tone.info => HazardColors.info,
      Tone.attention => const Color(0xFFB26A00), // amber dark enough for text on white
      Tone.danger => HazardColors.alarm,
      null => HazardColors.unknown,
    };

IconData toneIcon(Tone? tone) => switch (tone) {
      Tone.ok => Icons.check_circle,
      Tone.info => Icons.info,
      Tone.attention => Icons.error,
      Tone.danger => Icons.warning_rounded,
      null => Icons.help,
    };

/// Hub analysis level (ok | attention | danger | unknown) as a [Tone].
Tone? toneForLevel(String level) => switch (level) {
      'ok' => Tone.ok,
      'attention' => Tone.attention,
      'danger' => Tone.danger,
      _ => null,
    };

// ---------------------------------------------------------------------------
// Charts (CustomPainter, no chart package)

/// Area sparkline over the window. Nulls and long silences are gaps (see
/// [Series.runs]). A dashed line marks the warning [threshold]; the parts of
/// the line above [amberFrom] / [redFrom] are redrawn amber / red, so a spike
/// past a limit stands out even when the latest value (and [color]) is calm.
class SparklinePainter extends CustomPainter {
  SparklinePainter({
    required this.series,
    required this.maxGap,
    required this.color,
    this.threshold,
    this.amberFrom,
    this.redFrom,
    this.zeroBased = true,
    this.minSpan = 1,
  });

  final Series series;
  final Duration maxGap;
  final Color color;
  final double? threshold;
  final double? amberFrom;
  final double? redFrom;
  final bool zeroBased;
  final double minSpan;

  static const amber = Color(0xFFE08600);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = chartBounds(series, threshold: threshold, zeroBased: zeroBased, minSpan: minSpan);
    final startMs = series.start.millisecondsSinceEpoch;
    final spanMs = math.max(1, series.end.millisecondsSinceEpoch - startMs);
    final ySpan = bounds.max - bounds.min;
    double x(DateTime t) => ((t.millisecondsSinceEpoch - startMs) / spanMs).clamp(0.0, 1.0) * size.width;
    double y(double v) =>
        size.height - 1 - ((v - bounds.min) / (ySpan == 0 ? 1 : ySpan)).clamp(0.0, 1.0) * (size.height - 2);

    canvas.drawLine(
        Offset(0, size.height - 0.5),
        Offset(size.width, size.height - 0.5),
        Paint()
          ..color = const Color(0x33808080) // a faint baseline on light and dark tiles
          ..strokeWidth = 1);

    void dashed(double value, Color c) {
      if (value > bounds.max) return;
      final ty = y(value);
      final dash = Paint()
        ..color = c
        ..strokeWidth = 1.2;
      for (var dx = 0.0; dx < size.width; dx += 7) {
        canvas.drawLine(Offset(dx, ty), Offset((dx + 4).clamp(0, size.width), ty), dash);
      }
    }

    if (threshold case final double t) dashed(t, amber.withAlpha(190));
    if (redFrom case final double d when d != threshold) dashed(d, HazardColors.alarm.withAlpha(150));

    final lines = <Path>[];
    final areas = <Path>[];
    final dots = <Offset>[];
    for (final run in series.runs(maxGap: maxGap)) {
      final first = Offset(x(run.first.ts), y(run.first.value!));
      if (run.length == 1) {
        dots.add(first);
        continue;
      }
      final line = Path()..moveTo(first.dx, first.dy);
      for (final p in run.skip(1)) {
        line.lineTo(x(p.ts), y(p.value!));
      }
      lines.add(line);
      areas.add(Path.from(line)
        ..lineTo(x(run.last.ts), size.height)
        ..lineTo(first.dx, size.height)
        ..close());
    }

    void draw(Color c) {
      final fill = Paint()..color = c.withAlpha(46);
      final stroke = Paint()
        ..color = c
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      for (final a in areas) {
        canvas.drawPath(a, fill);
      }
      for (final l in lines) {
        canvas.drawPath(l, stroke);
      }
      for (final d in dots) {
        canvas.drawCircle(d, 2, Paint()..color = c);
      }
    }

    draw(color);
    // Re-ink only what lies above each limit (y grows downwards).
    for (final (limit, c) in [(amberFrom, amber), (redFrom, HazardColors.alarm)]) {
      if (limit == null || limit > bounds.max) continue;
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(0, 0, size.width, y(limit)));
      draw(c);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(SparklinePainter old) =>
      old.series != series ||
      old.color != color ||
      old.threshold != threshold ||
      old.amberFrom != amberFrom ||
      old.redFrom != redFrom;
}

/// Dry / leak band over the window; grey where there is no data.
class LeakTimelinePainter extends CustomPainter {
  LeakTimelinePainter({required this.history, required this.maxGap});

  final NodeHistory history;
  final Duration maxGap;

  @override
  void paint(Canvas canvas, Size size) {
    const band = 18.0;
    final top = (size.height - band) / 2;
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, top, size.width, band), const Radius.circular(6));
    canvas.drawRRect(track, Paint()..color = const Color(0x40808080));

    final startMs = history.start.millisecondsSinceEpoch;
    final endMs = history.end.millisecondsSinceEpoch;
    final spanMs = math.max(1, endMs - startMs);
    double x(int ms) => ((ms - startMs) / spanMs).clamp(0.0, 1.0) * size.width;

    canvas.save();
    canvas.clipRRect(track);
    // Each reading holds until the next one (or maxGap of silence); touching
    // readings with the same state merge into one bar, so no seams show.
    final bars = <({bool wet, int from, int to})>[];
    final points = history.points;
    for (var i = 0; i < points.length; i++) {
      final wet = isWet(points[i]);
      if (wet == null) continue;
      final from = points[i].ts.millisecondsSinceEpoch;
      final next = i + 1 < points.length ? points[i + 1].ts.millisecondsSinceEpoch : endMs;
      final to = math.min(next, from + maxGap.inMilliseconds);
      final last = bars.isEmpty ? null : bars.last;
      if (last != null && last.wet == wet && from <= last.to) {
        bars[bars.length - 1] = (wet: wet, from: last.from, to: to);
      } else {
        bars.add((wet: wet, from: from, to: to));
      }
    }
    for (final pass in [false, true]) {
      for (final bar in bars.where((b) => b.wet == pass)) {
        final left = x(bar.from);
        // A leak gets at least 2 px so a short one stays visible in a long window.
        final right = bar.wet && (x(bar.to) - left) < 2 ? left + 2 : x(bar.to);
        canvas.drawRect(
          Rect.fromLTRB(left, top, right, top + band),
          Paint()..color = bar.wet ? HazardColors.alarm : const Color(0xFF9CCC9F),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(LeakTimelinePainter old) => old.history != history;
}

// ---------------------------------------------------------------------------
// Tiles

/// One reading: label, big value (+ unit) or a big word, the plain-language
/// word with an icon (color is never the only signal), optional chart and a
/// small footer. [semantics] replaces everything for screen readers.
class SensorTile extends StatelessWidget {
  const SensorTile({
    super.key,
    required this.label,
    required this.word,
    required this.tone,
    required this.semantics,
    this.value,
    this.unit,
    this.caption,
    this.chart,
    this.footer,
    this.wordIcon,
    this.onTap,
  });

  final String label;

  /// Big number; when null the [word] is shown big instead.
  final String? value;
  final String? unit;
  final String? caption;
  final String word;
  final Tone? tone;
  final IconData? wordIcon;
  final Widget? chart;
  final String? footer;
  final String semantics;

  /// Opens the full-screen chart for this reading.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = context.palette.ink(toneColor(tone));
    final icon = wordIcon ?? toneIcon(tone);
    return Semantics(
      container: true,
      button: onTap != null,
      label: semantics,
      onTap: onTap,
      child: ExcludeSemantics(
        child: _Tappable(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: context.palette.tile,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.palette.tileBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.palette.muted)),
                const SizedBox(height: 2),
                if (value != null)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text.rich(TextSpan(children: [
                      TextSpan(
                          text: value,
                          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: context.palette.text)),
                      if (unit != null)
                        TextSpan(
                            text: ' $unit',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: context.palette.muted)),
                    ])),
                  ),
                if (caption != null) Text(caption!, style: TextStyle(fontSize: 12, color: context.palette.muted)),
                const SizedBox(height: 2),
                Row(children: [
                  Icon(icon, size: value == null ? 22 : 16, color: color),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(word,
                        style: TextStyle(fontSize: value == null ? 22 : 15, fontWeight: FontWeight.w800, color: color)),
                  ),
                ]),
                if (chart != null) ...[
                  const SizedBox(height: 8),
                  SizedBox(height: 40, width: double.infinity, child: chart),
                ],
                if (footer != null) ...[
                  const SizedBox(height: 4),
                  Text(footer!, style: TextStyle(fontSize: 12, color: context.palette.muted)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tappable extends StatelessWidget {
  const _Tappable({required this.onTap, required this.child});
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => onTap == null
      ? child
      : Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, child: child),
        );
}

/// One air measurement, with everything needed to draw it: used by the sheet
/// tiles and by the full-screen chart.
class MetricSpec {
  const MetricSpec({
    required this.key,
    required this.label,
    required this.series,
    required this.unit,
    required this.digits,
    required this.verdictOf,
    required this.spoken,
    required this.explain,
    this.approx = false,
    this.warn,
    this.danger,
    this.amberFrom,
    this.redFrom,
    this.zeroBased = true,
    this.minSpan = 1,
    this.caption,
  });

  /// temperature | humidity | pm25 | pm10 | co | gas
  final String key;
  final String label;
  final bool approx;
  final Series series;
  final String unit;
  final int digits;
  final Verdict Function(double v) verdictOf;
  final String Function(String value) spoken;

  /// "Ce înseamnă?" text.
  final String explain;

  /// Warning / danger levels drawn as labelled lines (null: none).
  final double? warn;
  final double? danger;

  /// Line turns amber / red above these.
  final double? amberFrom;
  final double? redFrom;
  final bool zeroBased;
  final double minSpan;
  final String? caption;

  String get displayLabel => approx ? '$label ≈' : label;
}

/// Air node measurements for [h]: temperature ≈, humidity ≈, fine particles,
/// particles, CO, gas level (% of the warning level; only if the device sent it).
List<MetricSpec> airMetrics(AppLocalizations l10n, NodeHistory h) {
  final coWarn = lastValue(h, HistoryFields.coWarn) ?? 50;
  final coDanger = lastValue(h, HistoryFields.coDanger) ?? 100;
  final gasWarn = lastValue(h, HistoryFields.gasWarn);
  final pm25Warn = lastValue(h, HistoryFields.pm25Warn) ?? 35;
  final pm25Danger = lastValue(h, HistoryFields.pm25Danger) ?? 150;
  final pm10Warn = lastValue(h, HistoryFields.pm10Warn) ?? 100;
  final pm10Danger = lastValue(h, HistoryFields.pm10Danger) ?? 250;
  String withUnit(double v, String unit) => '${l10n.count(v.round())} $unit';
  return [
    MetricSpec(
        key: 'temperature',
        label: l10n.tileTemperature,
        approx: true,
        series: Series.of(h, HistoryFields.temperature),
        unit: _unitC,
        digits: 1,
        verdictOf: temperatureVerdict,
        spoken: l10n.spokenTemperature,
        explain: l10n.explainTemperature,
        zeroBased: false,
        minSpan: 2),
    MetricSpec(
        key: 'humidity',
        label: l10n.tileHumidity,
        approx: true,
        series: Series.of(h, HistoryFields.humidity),
        unit: _unitPercent,
        digits: 1,
        verdictOf: humidityVerdict,
        spoken: l10n.spokenHumidity,
        explain: l10n.explainHumidity,
        zeroBased: false,
        minSpan: 10),
    MetricSpec(
        key: 'pm25',
        label: l10n.tileFineParticles,
        series: Series.of(h, HistoryFields.pm25),
        unit: _unitUgm3,
        digits: 0,
        verdictOf: (v) => pm25Verdict(v, warn: pm25Warn, danger: pm25Danger),
        spoken: l10n.spokenParticles,
        explain: l10n.explainPm25(withUnit(pm25Warn, _unitUgm3)),
        warn: pm25Warn,
        danger: pm25Danger,
        amberFrom: pm25Warn,
        redFrom: pm25Danger,
        minSpan: 10),
    MetricSpec(
        key: 'pm10',
        label: l10n.tileParticles,
        series: Series.of(h, HistoryFields.pm10),
        unit: _unitUgm3,
        digits: 0,
        verdictOf: (v) => pm10Verdict(v, warn: pm10Warn, danger: pm10Danger),
        spoken: l10n.spokenParticles,
        explain: l10n.explainPm10(withUnit(pm10Warn, _unitUgm3)),
        warn: pm10Warn,
        danger: pm10Danger,
        amberFrom: pm10Warn,
        redFrom: pm10Danger,
        minSpan: 10),
    MetricSpec(
        key: 'co',
        label: l10n.indicatorCo,
        series: Series.of(h, HistoryFields.co),
        unit: _unitPpm,
        digits: 0,
        verdictOf: (v) => coVerdict(v, warn: coWarn, danger: coDanger),
        spoken: l10n.spokenCo,
        explain: l10n.explainCo(withUnit(coWarn, _unitPpm)),
        warn: coWarn,
        danger: coDanger,
        amberFrom: coWarn,
        redFrom: coDanger,
        minSpan: 10),
    // The MQ-5 count is uncalibrated: shown only as % of the device's warning level.
    if (gasWarn != null && gasWarn > 0)
      MetricSpec(
          key: 'gas',
          label: l10n.tileGas,
          series: Series.of(h, HistoryFields.gasAdc, map: (v) => gasPercent(v, gasWarn)),
          unit: _unitPercent,
          digits: 0,
          verdictOf: gasVerdict,
          spoken: l10n.spokenGas,
          explain: l10n.explainGas,
          caption: l10n.gasOfWarning,
          // Same limits as the words: elevated from 60 %, danger above 100 %.
          warn: 100,
          amberFrom: 60,
          redFrom: 100,
          minSpan: 10),
  ];
}

/// A measured series as a tile: latest value, word, sparkline, min – max.
SensorTile metricTile(AppLocalizations l10n, MetricSpec m, int minutes, {VoidCallback? onTap}) {
  final series = m.series;
  String fmt(double v) => l10n.decimal(v, digits: m.digits);
  final latest = series.latest;
  final verdict = latest == null ? null : m.verdictOf(latest);
  final range = series.range;
  final word = series.warmingUp
      ? l10n.warmingUpShort
      : verdict == null
          ? '—'
          : l10n.verdictWord(verdict);
  final tone = series.warmingUp ? Tone.info : verdict?.tone;
  final String semantics;
  if (latest == null) {
    semantics = '${m.label}: ${series.warmingUp ? l10n.warmingUp : '—'}.';
  } else if (range == null) {
    semantics = '${m.label}: ${m.spoken(fmt(latest))}, $word.';
  } else {
    semantics = l10n.tileSemantics(
        m.label, m.spoken(fmt(latest)), word, fmt(range.min), fmt(range.max), l10n.inWindow(minutes));
  }
  return SensorTile(
    label: m.displayLabel,
    value: latest == null ? '—' : fmt(latest),
    unit: latest == null ? null : m.unit,
    caption: m.caption,
    word: word,
    tone: tone,
    wordIcon: series.warmingUp ? Icons.hourglass_top : null,
    semantics: semantics,
    onTap: onTap,
    chart: CustomPaint(
      painter: SparklinePainter(
        series: series,
        maxGap: maxGapFor(minutes: minutes, kind: 'air'),
        color: toneColor(tone),
        threshold: m.warn,
        amberFrom: m.amberFrom,
        redFrom: m.redFrom,
        zeroBased: m.zeroBased,
        minSpan: m.minSpan,
      ),
    ),
    footer: range == null ? null : '${fmt(range.min)} – ${fmt(range.max)} ${m.unit}',
  );
}

/// Air node tiles; [onOpen] gets the tapped metric's key.
List<Widget> airTiles(AppLocalizations l10n, NodeHistory h, {void Function(String key)? onOpen}) => [
      for (final m in airMetrics(l10n, h))
        metricTile(l10n, m, h.minutes, onTap: onOpen == null ? null : () => onOpen(m.key)),
    ];

/// Water node: dry / leak timeline, and the valve state from the hub analysis.
List<Widget> waterTiles(AppLocalizations l10n, NodeHistory h, NodeAnalysis node, {VoidCallback? onOpenLeak}) {
  final points = h.points;
  final latest = points.isEmpty ? null : isWet(points.last);
  DateTime? lastLeak;
  for (final p in points.reversed) {
    if (isWet(p) ?? false) {
      lastLeak = p.ts;
      break;
    }
  }
  final warming = points.isNotEmpty && latest == null;
  final verdict = latest == null ? null : (latest ? Verdict.leak : Verdict.dry);
  final word = warming
      ? l10n.warmingUpShort
      : verdict == null
          ? '—'
          : l10n.verdictWord(verdict);
  final footer = lastLeak != null ? l10n.lastLeak(l10n.clockTime(lastLeak)) : l10n.noLeakIn(l10n.inWindow(h.minutes));
  final valve = node.indicator('valve');
  return [
    SensorTile(
      label: l10n.tileLeak,
      word: word,
      tone: warming ? Tone.info : verdict?.tone,
      wordIcon: warming
          ? Icons.hourglass_top
          : (latest ?? false)
              ? Icons.water_damage
              : Icons.water_drop_outlined,
      semantics: '${l10n.tileLeak}: ${warming ? l10n.warmingUp : word}. $footer.',
      chart: CustomPaint(
        painter: LeakTimelinePainter(history: h, maxGap: maxGapFor(minutes: h.minutes, kind: 'water')),
      ),
      footer: footer,
      onTap: onOpenLeak,
    ),
    if (valve != null)
      SensorTile(
        label: l10n.tileValve,
        word: valve.value,
        tone: toneForLevel(valve.level),
        wordIcon: Icons.plumbing,
        semantics: '${l10n.tileValve}: ${valve.value}.',
      ),
  ];
}

/// Tiles two per row; rows grow with the text size instead of overflowing.
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.tiles});
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < tiles.length; i += 2)
          Padding(
            padding: EdgeInsets.only(bottom: i + 2 < tiles.length ? 10 : 0),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: tiles[i]),
                  const SizedBox(width: 10),
                  Expanded(child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox.shrink()),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Placeholder grid while the history loads.
class TileSkeletonGrid extends StatelessWidget {
  const TileSkeletonGrid({super.key, required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: MaterialLocalizations.of(context).refreshIndicatorSemanticLabel,
      child: ExcludeSemantics(
        child: TileGrid(tiles: [
          for (var i = 0; i < count; i++)
            Container(
              height: 132,
              decoration: BoxDecoration(
                color: const Color(0xFFECEEF1),
                borderRadius: BorderRadius.circular(14),
              ),
            ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Home room card: a row of big "vital" chips

/// Temperature ≈, humidity ≈ (latest air reading), the hub's air-quality word
/// and, for rooms with a water sensor, "No leaks". Tapping a chip opens its
/// sensor. Only live sensors get chips; the card says when one is offline.
class RoomVitals extends ConsumerWidget {
  const RoomVitals({super.key, required this.zone, required this.onOpen});
  final ZoneSummary zone;
  final void Function(NodeAnalysis node) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    NodeAnalysis? air;
    NodeAnalysis? water;
    for (final n in zone.nodes) {
      if (n.kind == 'air' && n.isLive) air ??= n;
      if (n.kind == 'water' && n.isLive) water ??= n;
    }
    final chips = <Widget>[];
    if (air != null) {
      final airNode = air;
      final climate = ref.watch(latestClimateProvider(airNode.nodeId));
      Widget climateChip(String field, String label, String unit, String Function(String) spoken) {
        final series = climate.valueOrNull == null ? null : Series.of(climate.valueOrNull!, field);
        final v = series?.latest;
        final text = v == null ? null : l10n.decimal(v);
        return VitalChip(
          label: '$label ≈',
          value: text ?? (series?.warmingUp ?? false ? l10n.warmingUpShort : '—'),
          unit: text == null ? null : unit,
          semantics:
              text == null ? '$label: ${series?.warmingUp ?? false ? l10n.warmingUp : '—'}' : '$label ${spoken(text)}',
          onTap: () => onOpen(airNode),
        );
      }

      chips.add(climateChip(HistoryFields.temperature, l10n.tileTemperature, _unitC, l10n.spokenTemperature));
      chips.add(climateChip(HistoryFields.humidity, l10n.tileHumidity, _unitPercent, l10n.spokenHumidity));
      final airState = airChipState(airNode);
      if (airState != null) {
        final text = switch (airState.source) {
          'co' => airState.tone == Tone.danger ? l10n.chipCoDanger : l10n.chipCoHigh,
          'gas' => airState.tone == Tone.danger ? l10n.chipGasDanger : l10n.chipGasHigh,
          _ => airState.word,
        };
        chips.add(VitalChip(
          label: l10n.chipAir,
          value: text,
          tone: airState.tone,
          icon: switch (airState.source) {
            'co' => Icons.cloud,
            'gas' => Icons.local_fire_department,
            _ => toneIcon(airState.tone),
          },
          semantics: '${l10n.chipAir}: $text',
          onTap: () => onOpen(airNode),
        ));
      }
    }
    if (water != null) {
      final waterNode = water;
      final leak = waterNode.indicator('leak');
      final tone = leak == null ? Tone.ok : toneForLevel(leak.level);
      final text = leak == null || leak.level == 'ok' ? l10n.noLeaks : leak.value;
      chips.add(VitalChip(
        label: l10n.chipWater,
        value: text,
        tone: tone,
        icon: tone == Tone.ok ? Icons.water_drop_outlined : Icons.water_damage,
        semantics: '${l10n.chipWater}: $text',
        onTap: () => onOpen(waterNode),
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    // Up to 3 in one row; 4 as two rows of two so each stays big.
    final perRow = chips.length == 4 ? 2 : chips.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        children: [
          for (var i = 0; i < chips.length; i += perRow)
            Padding(
              padding: EdgeInsets.only(bottom: i + perRow < chips.length ? 8 : 0),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var j = i; j < i + perRow && j < chips.length; j++) ...[
                      if (j > i) const SizedBox(width: 8),
                      Expanded(child: chips[j]),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What the room card's "Air" chip shows: the worst of the air node's
/// indicators. CO or gas that isn't ok wins (CO on a tie); otherwise the hub's
/// air-quality word. [source] is 'co', 'gas' or 'air_quality'.
({String source, String word, Tone? tone})? airChipState(NodeAnalysis node) {
  int rank(String level) => switch (level) { 'danger' => 3, 'attention' => 2, 'ok' => 1, _ => 0 };
  Indicator? worst;
  for (final key in const ['co', 'gas']) {
    final i = node.indicator(key);
    if (i == null || rank(i.level) < 2) continue;
    if (worst == null || rank(i.level) > rank(worst.level)) worst = i;
  }
  final pick = worst ?? node.indicator('air_quality');
  if (pick == null) return null;
  return (source: pick.key, word: pick.value, tone: toneForLevel(pick.level));
}

/// One big, tappable reading on a room card.
class VitalChip extends StatelessWidget {
  const VitalChip({
    super.key,
    required this.label,
    required this.value,
    required this.semantics,
    this.unit,
    this.tone,
    this.icon,
    this.onTap,
  });

  final String label;
  final String value;
  final String? unit;

  /// Colors the value (always paired with [icon] and the word itself).
  final Tone? tone;
  final IconData? icon;
  final String semantics;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = tone == null ? context.palette.text : context.palette.ink(toneColor(tone));
    return Semantics(
      button: onTap != null,
      label: semantics,
      excludeSemantics: true,
      child: Material(
        color: tone == null ? context.palette.tile : context.palette.tint(toneColor(tone), 20),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(label,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.palette.muted)),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[
                      Icon(icon, size: 18, color: color),
                      const SizedBox(width: 4),
                    ],
                    Text.rich(TextSpan(children: [
                      TextSpan(text: value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
                      if (unit != null)
                        TextSpan(
                            text: ' $unit',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.palette.muted)),
                    ])),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
