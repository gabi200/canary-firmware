import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../i18n.dart';
import '../logic/chart_math.dart' as cm;
import '../logic/chart_math.dart' show SeriesStats, readingAt;
import '../logic/sensor_series.dart';
import '../models/history.dart';
import '../models/summary.dart';
import '../state/history_providers.dart';
import '../theme.dart';
import 'widgets/sensor_tiles.dart';

/// Windows offered on the full-screen chart: 1 h / 6 h / 24 h / 7 days.
const chartRanges = [60, 360, 1440, 10080];

/// Full-screen chart for one sensor's measurements: swipe (or the arrows)
/// between them, touch-and-drag for the exact value, stats for the window and a
/// plain "what does it mean?" box. Works in landscape (wider chart).
class SensorChartPage extends ConsumerStatefulWidget {
  const SensorChartPage({super.key, required this.node, required this.initialKey, this.initialMinutes = 60});
  final NodeAnalysis node;

  /// Metric to open on (see [MetricSpec.key]; 'leak' for water sensors).
  final String initialKey;
  final int initialMinutes;

  @override
  ConsumerState<SensorChartPage> createState() => _SensorChartPageState();
}

class _SensorChartPageState extends ConsumerState<SensorChartPage> {
  late int _minutes = chartRanges.contains(widget.initialMinutes) ? widget.initialMinutes : 60;
  PageController? _pages;
  int _index = 0;

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  void _go(int delta, int count) {
    final target = (_index + delta).clamp(0, count - 1);
    _pages?.animateToPage(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final water = widget.node.kind == 'water';
    final key = (nodeId: widget.node.nodeId, kind: widget.node.kind, minutes: _minutes);
    final async = ref.watch(nodeHistoryProvider(key));
    final history = async.valueOrNull;
    final metrics = history == null || water ? const <MetricSpec>[] : airMetrics(l10n, history);
    final count = water ? 1 : metrics.length;
    if (_pages == null && (water || metrics.isNotEmpty)) {
      _index = water ? 0 : math.max(0, metrics.indexWhere((m) => m.key == widget.initialKey));
      _pages = PageController(initialPage: _index);
    }
    final title = water
        ? l10n.tileLeak
        : metrics.isEmpty
            ? widget.node.name
            : metrics[_index.clamp(0, metrics.length - 1)].displayLabel;

    final Widget body;
    if (history == null) {
      body = async.hasError
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(l10n.historyFailed, textAlign: TextAlign.center),
                  TextButton(onPressed: () => ref.invalidate(nodeHistoryProvider(key)), child: Text(l10n.retry)),
                ]),
              ),
            )
          : const Center(child: CircularProgressIndicator());
    } else {
      body = PageView.builder(
        controller: _pages,
        itemCount: count,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => _MetricView(
          node: widget.node,
          history: history,
          metric: water ? null : metrics[i],
          minutes: _minutes,
          onRange: (m) => setState(() => _minutes = m),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (count > 1) ...[
            IconButton(
              tooltip: l10n.chartPrevMetric,
              icon: const Icon(Icons.chevron_left),
              onPressed: _index > 0 ? () => _go(-1, count) : null,
            ),
            IconButton(
              tooltip: l10n.chartNextMetric,
              icon: const Icon(Icons.chevron_right),
              onPressed: _index < count - 1 ? () => _go(1, count) : null,
            ),
          ],
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}

/// One metric's page (or the leak page when [metric] is null).
class _MetricView extends StatelessWidget {
  const _MetricView({
    required this.node,
    required this.history,
    required this.metric,
    required this.minutes,
    required this.onRange,
  });

  final NodeAnalysis node;
  final NodeHistory history;
  final MetricSpec? metric;
  final int minutes;
  final ValueChanged<int> onRange;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final m = metric;
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final height = MediaQuery.sizeOf(context).height;
    final chartHeight = landscape ? math.max(200.0, height * 0.62) : math.min(320.0, math.max(220.0, height * 0.34));

    final header = m == null ? _LeakHeader(history: history) : _ValueHeader(metric: m);
    final range = SizedBox(
      width: double.infinity,
      child: SegmentedButton<int>(
        showSelectedIcon: false,
        segments: [
          for (final r in chartRanges)
            ButtonSegment(
              value: r,
              label: Text(l10n.windowShort(r), semanticsLabel: l10n.windowName(r)),
              tooltip: l10n.windowName(r),
            ),
        ],
        selected: {minutes},
        onSelectionChanged: (s) => onRange(s.first),
      ),
    );
    final chart = m == null
        ? SizedBox(
            height: 64,
            child: CustomPaint(
              painter: LeakTimelinePainter(history: history, maxGap: maxGapFor(minutes: minutes, kind: 'water')),
            ),
          )
        : _InteractiveChart(metric: m, minutes: minutes, height: chartHeight);
    final explain = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFEFF4FB), borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.lightbulb_outline, color: HazardColors.info),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l10n.chartWhatMeans, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 4),
            Text(m?.explain ?? l10n.explainLeak, style: const TextStyle(fontSize: 15)),
          ]),
        ),
      ]),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        header,
        const SizedBox(height: 12),
        range,
        const SizedBox(height: 12),
        chart,
        if (m != null) ...[
          const SizedBox(height: 8),
          _Legend(metric: m),
          const SizedBox(height: 12),
          _StatsRow(metric: m),
        ],
        const SizedBox(height: 12),
        explain,
      ],
    );
  }
}

class _ValueHeader extends StatelessWidget {
  const _ValueHeader({required this.metric});
  final MetricSpec metric;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = metric.series;
    final latest = s.latest;
    final verdict = latest == null ? null : metric.verdictOf(latest);
    final tone = s.warmingUp ? Tone.info : verdict?.tone;
    final word = s.warmingUp
        ? l10n.warmingUp
        : verdict == null
            ? '—'
            : l10n.verdictWord(verdict);
    return Semantics(
      container: true,
      label: latest == null
          ? '${metric.label}: $word'
          : '${metric.label}: ${metric.spoken(l10n.decimal(latest, digits: metric.digits))}, $word',
      excludeSemantics: true,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(TextSpan(children: [
              TextSpan(
                text: latest == null ? '—' : l10n.decimal(latest, digits: metric.digits),
                style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: context.palette.text),
              ),
              if (latest != null)
                TextSpan(
                  text: ' ${metric.unit}',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: context.palette.muted),
                ),
            ])),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Icon(s.warmingUp ? Icons.hourglass_top : toneIcon(tone), color: context.palette.ink(toneColor(tone))),
              const SizedBox(width: 4),
              Flexible(
                child: Text(word,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: context.palette.ink(toneColor(tone)))),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _LeakHeader extends StatelessWidget {
  const _LeakHeader({required this.history});
  final NodeHistory history;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final points = history.points;
    final latest = points.isEmpty ? null : isWet(points.last);
    DateTime? lastLeak;
    for (final p in points.reversed) {
      if (isWet(p) ?? false) {
        lastLeak = p.ts;
        break;
      }
    }
    final verdict = latest == null ? null : (latest ? Verdict.leak : Verdict.dry);
    final word = verdict == null ? '—' : l10n.verdictWord(verdict);
    final footer =
        lastLeak != null ? l10n.lastLeak(l10n.clockTime(lastLeak)) : l10n.noLeakIn(l10n.inWindow(history.minutes));
    return Semantics(
      container: true,
      label: '${l10n.tileLeak}: $word. $footer.',
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(latest ?? false ? Icons.water_damage : Icons.water_drop_outlined,
              size: 36, color: context.palette.ink(toneColor(verdict?.tone))),
          const SizedBox(width: 8),
          Flexible(
            child: Text(word,
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: context.palette.ink(toneColor(verdict?.tone)))),
          ),
        ]),
        Text(footer, style: TextStyle(fontSize: 15, color: context.palette.muted)),
      ]),
    );
  }
}

/// Now / min / average / max for the window (nulls ignored).
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.metric});
  final MetricSpec metric;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final stats = SeriesStats.of(metric.series);
    String fmt(double? v) => v == null ? '—' : l10n.decimal(v, digits: metric.digits);
    final cells = [
      (l10n.chartNow, stats.now),
      (l10n.chartMin, stats.min),
      (l10n.chartMean, stats.mean),
      (l10n.chartMax, stats.max),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final perRow = constraints.maxWidth < 300 || MediaQuery.textScalerOf(context).scale(16) > 21 ? 2 : 4;
      final width = (constraints.maxWidth - 8 * (perRow - 1)) / perRow;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (label, value) in cells)
            Semantics(
              label: '$label: ${fmt(value)} ${value == null ? '' : metric.unit}',
              excludeSemantics: true,
              child: Container(
                width: width,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: context.palette.tile,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: TextStyle(fontSize: 13, color: context.palette.muted)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text('${fmt(value)}${value == null ? '' : ' ${metric.unit}'}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                ]),
              ),
            ),
        ],
      );
    });
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.metric});
  final MetricSpec metric;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String level(double v) => '${l10n.decimal(v, digits: metric.digits)} ${metric.unit}';
    Widget item(Widget swatch, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          swatch,
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: const TextStyle(fontSize: 13))),
        ]);
    Widget dash(Color c) => SizedBox(width: 22, height: 10, child: CustomPaint(painter: _DashSwatch(c)));
    return Wrap(spacing: 14, runSpacing: 6, children: [
      if (metric.warn != null) item(dash(SparklinePainter.amber), l10n.chartThresholdWarn(level(metric.warn!))),
      if (metric.danger != null) item(dash(HazardColors.alarm), l10n.chartThresholdDanger(level(metric.danger!))),
      item(
        Container(
            width: 22,
            height: 12,
            decoration: BoxDecoration(color: context.palette.chip, border: Border.all(color: context.palette.divider))),
        l10n.chartNoData,
      ),
    ]);
  }
}


class _DashSwatch extends CustomPainter {
  _DashSwatch(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, size.height / 2), Offset(math.min(x + 4, size.width), size.height / 2), p);
    }
  }

  @override
  bool shouldRepaint(_DashSwatch old) => old.color != color;
}

/// The big chart with a touch-and-drag crosshair. The reading under the finger
/// is shown above the chart and announced (live region); it stays after release.
class _InteractiveChart extends StatefulWidget {
  const _InteractiveChart({required this.metric, required this.minutes, required this.height});
  final MetricSpec metric;
  final int minutes;
  final double height;

  @override
  State<_InteractiveChart> createState() => _InteractiveChartState();
}

class _InteractiveChartState extends State<_InteractiveChart> {
  DateTime? _at;

  @override
  void didUpdateWidget(_InteractiveChart old) {
    super.didUpdateWidget(old);
    if (old.minutes != widget.minutes) _at = null;
  }

  void _pick(Offset local, ChartGeometry g) {
    final s = widget.metric.series;
    final f = ((local.dx - g.plot.left) / g.plot.width).clamp(0.0, 1.0);
    final span = s.end.difference(s.start).inMilliseconds;
    setState(() => _at = s.start.add(Duration(milliseconds: (span * f).round())));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final m = widget.metric;
    final maxGap = maxGapFor(minutes: widget.minutes, kind: 'air');
    final at = _at;
    final reading = at == null ? null : readingAt(m.series, at, maxGap: maxGap);
    final timeFmt = widget.minutes > 1440 ? DateFormat.MMMd(l10n.localeName).add_Hm() : DateFormat.Hm(l10n.localeName);
    final readingText = reading == null
        ? l10n.chartHint
        : l10n.chartAt(
            timeFmt.format((reading.value == null ? at! : reading.ts).toLocal()),
            reading.value == null ? l10n.chartNoData : '${l10n.decimal(reading.value!, digits: m.digits)} ${m.unit}',
          );
    final range = m.series.range;
    final summary = range == null
        ? '${m.label}: ${l10n.noReadings(l10n.inWindow(widget.minutes))}'
        : l10n.tileSemantics(
            m.label,
            m.series.latest == null ? '—' : m.spoken(l10n.decimal(m.series.latest!, digits: m.digits)),
            m.series.latest == null ? '—' : l10n.verdictWord(m.verdictOf(m.series.latest!)),
            l10n.decimal(range.min, digits: m.digits),
            l10n.decimal(range.max, digits: m.digits),
            l10n.inWindow(widget.minutes),
          );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
        liveRegion: true,
        child: Text(readingText,
            style: TextStyle(
                fontSize: 15,
                fontWeight: reading == null ? FontWeight.w400 : FontWeight.w700,
                color: reading == null ? context.palette.muted : context.palette.text)),
      ),
      const SizedBox(height: 6),
      Semantics(
        label: summary,
        child: SizedBox(
          height: widget.height,
          child: LayoutBuilder(builder: (context, constraints) {
            final size = Size(constraints.maxWidth, widget.height);
            final scaler = MediaQuery.textScalerOf(context);
            final g = ChartGeometry.of(m, size, scaler, l10n, widget.minutes);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _pick(d.localPosition, g),
              onHorizontalDragStart: (d) => _pick(d.localPosition, g),
              onHorizontalDragUpdate: (d) => _pick(d.localPosition, g),
              child: CustomPaint(
                size: size,
                painter: FullChartPainter(
                    geometry: g, metric: m, maxGap: maxGap, crosshair: at, reading: reading, palette: context.palette),
              ),
            );
          }),
        ),
      ),
    ]);
  }
}

/// Where everything goes on the big chart; shared by the painter and the
/// gesture handler so the crosshair lands where the finger is.
class ChartGeometry {
  ChartGeometry._(this.plot, this.min, this.max, this.valueTicks, this.timeTicks, this.valueLabels, this.timeLabels,
      this.scaler, this.start, this.end, this.thresholdLabels);

  final Rect plot;
  final double min;
  final double max;
  final List<double> valueTicks;
  final List<DateTime> timeTicks;
  final List<String> valueLabels;
  final List<String> timeLabels;
  final TextScaler scaler;
  final DateTime start;
  final DateTime end;
  final List<(double, String, Color)> thresholdLabels;

  factory ChartGeometry.of(MetricSpec m, Size size, TextScaler scaler, AppLocalizations l10n, int minutes) {
    final b = chartBounds(m.series, threshold: m.warn, zeroBased: m.zeroBased, minSpan: m.minSpan);
    final max = m.danger != null && m.series.range != null && m.series.range!.max >= m.danger! * 0.9
        ? math.max(b.max, m.danger! * 1.05)
        : b.max;
    final vt = cm.valueTicks(b.min, max, count: 4);
    final digits = (vt.length > 1 && (vt[1] - vt[0]) < 1) ? 1 : 0;
    final vLabels = [for (final v in vt) l10n.decimal(v, digits: digits)];
    const style = TextStyle(fontSize: 12); // measuring only
    double width(String s) {
      final tp =
          TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, textScaler: scaler)
            ..layout();
      final w = tp.width;
      tp.dispose();
      return w;
    }

    final left = (vLabels.map(width).fold<double>(0, math.max)) + 10;
    final bottom = scaler.scale(12) * 1.4 + 8;
    final plot = Rect.fromLTRB(left, 8, size.width - 8, size.height - bottom);
    final tt = cm.timeTicks(m.series.start, m.series.end, count: math.max(2, (plot.width / 80).floor()));
    final fmt = minutes > 1440 ? DateFormat.MMMd(l10n.localeName) : DateFormat.Hm(l10n.localeName);
    String level(double v) => '${l10n.decimal(v, digits: m.digits)} ${m.unit}';
    return ChartGeometry._(
      plot,
      b.min,
      max,
      vt,
      tt,
      vLabels,
      [for (final t in tt) fmt.format(t)],
      scaler,
      m.series.start,
      m.series.end,
      [
        if (m.warn != null) (m.warn!, l10n.chartThresholdWarn(level(m.warn!)), SparklinePainter.amber),
        if (m.danger != null && m.danger! <= max)
          (m.danger!, l10n.chartThresholdDanger(level(m.danger!)), HazardColors.alarm),
      ],
    );
  }

  double x(DateTime t) {
    final span = math.max(1, end.millisecondsSinceEpoch - start.millisecondsSinceEpoch);
    final f = (t.millisecondsSinceEpoch - start.millisecondsSinceEpoch) / span;
    return plot.left + f.clamp(0.0, 1.0) * plot.width;
  }

  double y(double v) {
    final span = max - min == 0 ? 1 : max - min;
    return plot.bottom - ((v - min) / span).clamp(0.0, 1.0) * plot.height;
  }
}

class FullChartPainter extends CustomPainter {
  FullChartPainter(
      {required this.geometry,
      required this.metric,
      required this.maxGap,
      this.crosshair,
      this.reading,
      this.palette = CanaryPalette.light});
  final ChartGeometry geometry;
  final MetricSpec metric;
  final Duration maxGap;
  final DateTime? crosshair;
  final SeriesPoint? reading;

  /// Light / dark neutrals for the grid, labels and the crosshair.
  final CanaryPalette palette;

  void _text(Canvas canvas, String s, Offset at,
      {Color? color,
      double size = 12,
      FontWeight weight = FontWeight.w400,
      Alignment align = Alignment.topLeft,
      Color? background}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color ?? palette.muted, fontWeight: weight)),
      textDirection: TextDirection.ltr,
      textScaler: geometry.scaler,
    )..layout();
    final dx = at.dx - (align.x + 1) / 2 * tp.width;
    final dy = at.dy - (align.y + 1) / 2 * tp.height;
    if (background != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(dx - 4, dy - 2, tp.width + 8, tp.height + 4), const Radius.circular(4)),
        Paint()..color = background,
      );
    }
    tp.paint(canvas, Offset(dx, dy));
    tp.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    final plot = g.plot;
    final series = metric.series;

    // Gaps (no valid reading): light bands across the plot.
    final gap = Paint()..color = palette.chip;
    final runs = series.runs(maxGap: maxGap);
    var cursor = series.start;
    for (final run in [...runs, <SeriesPoint>[]]) {
      final until = run.isEmpty ? series.end : run.first.ts;
      if (until.difference(cursor) > maxGap) {
        canvas.drawRect(Rect.fromLTRB(g.x(cursor), plot.top, g.x(until), plot.bottom), gap);
      }
      if (run.isNotEmpty) cursor = run.last.ts;
    }

    // Grid + axis labels.
    final grid = Paint()
      ..color = palette.divider
      ..strokeWidth = 1;
    for (var i = 0; i < g.valueTicks.length; i++) {
      final y = g.y(g.valueTicks[i]);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _text(canvas, g.valueLabels[i], Offset(plot.left - 6, y), align: Alignment.centerRight);
    }
    for (var i = 0; i < g.timeTicks.length; i++) {
      final x = g.x(g.timeTicks[i]);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      _text(canvas, g.timeLabels[i], Offset(x, plot.bottom + 4), align: Alignment.topCenter);
    }
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, Paint()..color = palette.faint);

    // Threshold lines, labelled.
    for (final (value, label, color) in g.thresholdLabels) {
      final y = g.y(value);
      final dash = Paint()
        ..color = color
        ..strokeWidth = 1.5;
      for (var x = plot.left; x < plot.right; x += 8) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, plot.right), y), dash);
      }
      _text(canvas, label, Offset(plot.right - 2, y - 2),
          color: color, weight: FontWeight.w700, align: Alignment.bottomRight, background: palette.surface.withAlpha(210));
    }

    // Data: base color, re-inked amber / red above the limits.
    final latest = series.latest;
    final base = toneColor(latest == null ? null : metric.verdictOf(latest).tone);
    final lines = <Path>[];
    final areas = <Path>[];
    final dots = <Offset>[];
    for (final run in runs) {
      final first = Offset(g.x(run.first.ts), g.y(run.first.value!));
      if (run.length == 1) {
        dots.add(first);
        continue;
      }
      final line = Path()..moveTo(first.dx, first.dy);
      for (final p in run.skip(1)) {
        line.lineTo(g.x(p.ts), g.y(p.value!));
      }
      lines.add(line);
      areas.add(Path.from(line)
        ..lineTo(g.x(run.last.ts), plot.bottom)
        ..lineTo(first.dx, plot.bottom)
        ..close());
    }
    void draw(Color c) {
      for (final a in areas) {
        canvas.drawPath(a, Paint()..color = c.withAlpha(40));
      }
      final stroke = Paint()
        ..color = c
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      for (final l in lines) {
        canvas.drawPath(l, stroke);
      }
      for (final d in dots) {
        canvas.drawCircle(d, 3, Paint()..color = c);
      }
    }

    canvas.save();
    canvas.clipRect(plot.inflate(2));
    draw(base);
    for (final (limit, c) in [(metric.amberFrom, SparklinePainter.amber), (metric.redFrom, HazardColors.alarm)]) {
      if (limit == null || limit > g.max) continue;
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(plot.left - 2, plot.top - 2, plot.right + 2, g.y(limit)));
      draw(c);
      canvas.restore();
    }
    canvas.restore();

    // Crosshair.
    final at = crosshair;
    if (at != null) {
      final x = g.x(reading?.value == null ? at : reading!.ts);
      canvas.drawLine(
          Offset(x, plot.top),
          Offset(x, plot.bottom),
          Paint()
            ..color = palette.text
            ..strokeWidth = 1.2);
      final v = reading?.value;
      if (v != null) {
        final y = g.y(v);
        canvas.drawCircle(Offset(x, y), 6, Paint()..color = palette.surface);
        canvas.drawCircle(Offset(x, y), 4.5, Paint()..color = palette.text);
      }
    }
  }

  @override
  bool shouldRepaint(FullChartPainter old) =>
      old.metric != metric ||
      old.crosshair != crosshair ||
      old.geometry.plot != geometry.plot ||
      old.palette != palette;
}

/// Opens the full-screen chart for [metricKey] of [node].
void openSensorChart(BuildContext context, NodeAnalysis node, String metricKey, int minutes) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => SensorChartPage(node: node, initialKey: metricKey, initialMinutes: minutes),
  ));
}
