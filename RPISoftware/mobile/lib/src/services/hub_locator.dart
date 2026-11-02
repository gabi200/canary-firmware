import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

/// Answers whether a Canary hub's API is at [baseUrl] (e.g. `http://10.0.0.5:8000`).
typedef HubProbe = Future<bool> Function(String baseUrl);

/// Base URLs of hubs announcing `_canary-hub._tcp`, found within [timeout].
typedef HubBrowse = Future<List<String>> Function(Duration timeout);

/// The phone's own IPv4 address on the Wi-Fi, or null when there is none.
typedef WifiIpv4 = Future<String?> Function();

const hubServiceType = '_canary-hub._tcp';
const _apiPort = 8000;
const _browseTimeout = Duration(seconds: 5);
const _scanParallel = 30;

/// Finds the hub on the local network. The hotspot's subnet can change (a new phone), so
/// the app does not trust a built-in address: it tries, in order, the build-time
/// [override], the last address that worked ([saved]), the hub's own announcement over
/// DNS-SD, and finally every address of the phone's /24. The first that answers
/// `/health` as `canary-backend` wins.
class HubLocator {
  HubLocator({
    required this.probe,
    required this.browse,
    required this.wifiIp,
    this.override = '',
    this.saved,
    HubProbe? scanProbe,
  }) : scanProbe = scanProbe ?? probe;

  final HubProbe probe;

  /// Used for the /24 scan (a short timeout); defaults to [probe].
  final HubProbe scanProbe;
  final HubBrowse browse;
  final WifiIpv4 wifiIp;
  final String override;
  final String? saved;

  /// Default wiring: real network probe, Bonsoir discovery, the phone's interfaces.
  factory HubLocator.network({String override = '', String? saved}) => HubLocator(
        probe: probeHub,
        scanProbe: _scanProbe,
        browse: browseHubs,
        wifiIp: wifiIpv4,
        override: override,
        saved: saved,
      );

  Future<String?> locate() async {
    for (final url in [override, saved]) {
      if (url != null && url.isNotEmpty && await probe(url)) return url;
    }
    for (final url in await browse(_browseTimeout)) {
      if (await probe(url)) return url;
    }
    return _scan();
  }

  Future<String?> _scan() async {
    final own = await wifiIp();
    if (own == null) return null;
    final parts = own.split('.');
    if (parts.length != 4) return null;
    final prefix = parts.take(3).join('.');
    final candidates = [
      for (var host = 1; host <= 254; host++)
        if ('$prefix.$host' != own) 'http://$prefix.$host:$_apiPort',
    ];
    String? found;
    var next = 0;
    Future<void> worker() async {
      while (found == null && next < candidates.length) {
        final url = candidates[next++];
        if (await scanProbe(url)) found ??= url;
      }
    }

    await Future.wait([for (var i = 0; i < _scanParallel; i++) worker()]);
    return found;
  }
}

/// GET `<baseUrl>/health`: true only for a Canary backend.
Future<bool> probeHub(String baseUrl, {Duration timeout = const Duration(seconds: 2)}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(Uri.parse('$baseUrl/health')).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) return false;
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    final json = jsonDecode(body);
    return json is Map && json['service'] == 'canary-backend';
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Scan probe: shorter timeout, many run at once.
Future<bool> _scanProbe(String baseUrl) => probeHub(baseUrl, timeout: const Duration(milliseconds: 600));

/// Browses `_canary-hub._tcp` for [timeout] and returns each hub's API base URL: the `api`
/// TXT value the hub announces (its routable address), else `http://<address>:<port>`.
Future<List<String>> browseHubs(Duration timeout) async {
  final urls = <String>[];
  final discovery = BonsoirDiscovery(type: hubServiceType);
  try {
    await discovery.initialize();
    final sub = discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          discovery.serviceResolver.resolveService(event.service);
        case BonsoirDiscoveryServiceResolvedEvent():
          final service = event.service;
          final api = service.attributes['api'];
          if (api != null && api.startsWith('http')) {
            urls.add(api);
          } else if (service.hostAddresses.isNotEmpty) {
            urls.add('http://${service.hostAddresses.first}:${service.port}');
          }
        default:
          break;
      }
    });
    await discovery.start();
    await Future<void>.delayed(timeout);
    await sub?.cancel();
  } catch (_) {
    // No multicast on this network / platform: the scan still runs.
  } finally {
    try {
      await discovery.stop();
    } catch (_) {}
  }
  return urls.toSet().toList();
}

/// The phone's IPv4 address on the Wi-Fi (interfaces named wlan*/en* first, so mobile data
/// is not scanned), else the first non-loopback, non-link-local one.
Future<String?> wifiIpv4() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    bool wifi(NetworkInterface i) => i.name.startsWith('wlan') || i.name.startsWith('en');
    for (final iface in [...interfaces.where(wifi), ...interfaces.where((i) => !wifi(i))]) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback && !addr.isLinkLocal) return addr.address;
      }
    }
  } catch (_) {}
  return null;
}
