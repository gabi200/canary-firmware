import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/sensor_series.dart';
import '../models/history.dart';
import 'providers.dart';

/// Which history a sensor sheet shows: node, its kind (air | water) and window.
typedef HistoryKey = ({String nodeId, String kind, int minutes});

/// Window choices on the sensor sheet: last hour / 24 hours / 7 days.
const historyRanges = [60, 1440, 10080];

/// Sensor sheet history. Only fetched while a sheet shows it (autoDispose);
/// refreshes itself every 30 s while watched, keeping the last data on screen.
final nodeHistoryProvider =
    FutureProvider.autoDispose.family<NodeHistory, HistoryKey>((ref, key) {
  final timer = Timer(const Duration(seconds: 30), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(apiClientProvider).nodeHistory(
        key.nodeId,
        minutes: key.minutes,
        fields: key.kind == 'water' ? HistoryFields.water : HistoryFields.air,
      );
});

/// Latest temperature / humidity of an air node for the home room cards: a
/// short window, fetched only for cards on screen, refreshed every 60 s.
final latestClimateProvider =
    FutureProvider.autoDispose.family<NodeHistory, String>((ref, nodeId) {
  final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(apiClientProvider).nodeHistory(
        nodeId,
        minutes: 15,
        fields: HistoryFields.climate,
      );
});
