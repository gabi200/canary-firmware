import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/household.dart';
import 'providers.dart';

/// The caller's apartment(s) and members (`GET /me/household`).
final householdProvider = FutureProvider.autoDispose<List<HouseholdUnit>>((ref) async {
  if (ref.watch(sessionProvider) == null) return const [];
  return ref.watch(apiClientProvider).household();
});

/// Invites the caller sent that nobody used yet.
final pendingInvitesProvider = FutureProvider.autoDispose<List<PendingInvite>>((ref) async {
  if (ref.watch(sessionProvider) == null) return const [];
  return ref.watch(apiClientProvider).pendingInvites();
});
