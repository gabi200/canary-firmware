import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_client.dart';
import '../services/hub_locator.dart';
import '../services/storage.dart';

class HubState {
  const HubState({this.url, this.searching = false});

  /// The hub's REST base in use, or null while none has been found.
  final String? url;

  /// A search is running (the first one, or a new one after the hub stopped answering).
  final bool searching;
}

/// Owns the hub's address: finds it at start, again whenever the API reports the hub
/// unreachable, and accepts an address typed by hand. Every address found is pushed into
/// the [ApiClient] and saved for the next start.
class HubController extends StateNotifier<HubState> {
  HubController(
    this._storage,
    this._api, {
    required HubLocator Function(String? saved) locatorFor,
    required HubProbe probe,
  })  : _locatorFor = locatorFor,
        _probe = probe,
        super(HubState(url: _storage.hubUrl, searching: true)) {
    // Cold start: use the last address at once (the app opens, the offline check-in queue
    // works) and confirm or replace it in the background.
    final saved = state.url;
    if (saved != null) _api.baseUrl = saved;
    _api.onUnreachable = locate;
    locate();
  }

  final Storage _storage;
  final ApiClient _api;
  final HubLocator Function(String? saved) _locatorFor;
  final HubProbe _probe;
  Future<void>? _running;

  /// Completes when the current search (if any) is over.
  Future<void> get ready => _running ?? Future<void>.value();

  /// Starts a search unless one is running. The current address stays in use meanwhile.
  Future<void> locate() => _running ??= _search().whenComplete(() => _running = null);

  Future<void> _search() async {
    state = HubState(url: state.url, searching: true);
    final found = await _locatorFor(_storage.hubUrl).locate();
    if (!mounted) return;
    if (found != null) {
      await _use(found);
    } else {
      state = HubState(url: state.url);
    }
  }

  /// An address typed by the user: `10.0.0.5`, `10.0.0.5:8000` or `http://10.0.0.5:8000/`.
  /// Used (and saved) only if it answers as the hub.
  Future<bool> useManual(String input) async {
    final url = normalizeHubUrl(input);
    if (url == null || !await _probe(url)) return false;
    await _use(url);
    return true;
  }

  Future<void> _use(String url) async {
    _api.baseUrl = url;
    await _storage.saveHubUrl(url);
    if (mounted) state = HubState(url: url);
  }
}

/// `host`, `host:port` or a URL -> `http://host:port` (port 8000 when none is given).
String? normalizeHubUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  final port = uri.hasPort ? uri.port : 8000;
  return '${uri.scheme}://${uri.host}:$port';
}
