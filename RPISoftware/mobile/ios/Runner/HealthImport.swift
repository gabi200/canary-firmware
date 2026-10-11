import Flutter
import HealthKit

/// `canary/health`: read-only Apple Health access for the emergency profile
/// ("Importă din Sănătate"). Sends raw values only; turning them into
/// suggested needs happens in Dart (lib/src/logic/health_suggestions.dart).
/// Reads, never writes; nothing is stored here.
///
/// `read` → {"available": Bool, "wheelchairUse": "yes"|"no"|"notSet"?,
///           "walkingSteadiness": Double (0…1)?,
///           "audiogram": [{"hz": Double, "left": Double?, "right": Double?}]?}
final class HealthImportPlugin: NSObject, FlutterPlugin {
  private let store = HKHealthStore()

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "canary/health", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(HealthImportPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(HKHealthStore.isHealthDataAvailable())
    case "read":
      read(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private var readTypes: Set<HKObjectType> {
    var types: Set<HKObjectType> = [HKObjectType.audiogramSampleType()]
    if let wheelchair = HKObjectType.characteristicType(forIdentifier: .wheelchairUse) {
      types.insert(wheelchair)
    }
    if #available(iOS 15.0, *), let steadiness = HKObjectType.quantityType(forIdentifier: .appleWalkingSteadiness) {
      types.insert(steadiness)
    }
    return types
  }

  private func read(_ result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      result(["available": false])
      return
    }
    // Shows the system sheet the first time. iOS never reveals whether read
    // access was granted: refused types simply return no data.
    store.requestAuthorization(toShare: nil, read: readTypes) { _, error in
      if let error = error {
        DispatchQueue.main.async {
          result(FlutterError(code: "authorization", message: error.localizedDescription, details: nil))
        }
        return
      }
      self.collect { values in DispatchQueue.main.async { result(values) } }
    }
  }

  private func collect(_ done: @escaping ([String: Any]) -> Void) {
    let lock = NSLock()
    var out: [String: Any] = ["available": true]
    func put(_ key: String, _ value: Any) {
      lock.lock()
      out[key] = value
      lock.unlock()
    }

    if let wheelchair = try? store.wheelchairUse() {
      switch wheelchair.wheelchairUse {
      case .yes: put("wheelchairUse", "yes")
      case .no: put("wheelchairUse", "no")
      default: put("wheelchairUse", "notSet")
      }
    }

    let group = DispatchGroup()
    if #available(iOS 15.0, *), let steadiness = HKObjectType.quantityType(forIdentifier: .appleWalkingSteadiness) {
      group.enter()
      latest(steadiness) { sample in
        if let quantity = (sample as? HKQuantitySample)?.quantity {
          put("walkingSteadiness", quantity.doubleValue(for: .percent()))
        }
        group.leave()
      }
    }
    group.enter()
    latest(HKObjectType.audiogramSampleType()) { sample in
      if let audiogram = sample as? HKAudiogramSample {
        put("audiogram", audiogram.sensitivityPoints.map(Self.point))
      }
      group.leave()
    }
    group.notify(queue: .global()) {
      lock.lock()
      let values = out
      lock.unlock()
      done(values)
    }
  }

  /// The newest sample of [type], or nil (no data, or read access refused).
  private func latest(_ type: HKSampleType, _ done: @escaping (HKSample?) -> Void) {
    let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
    let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [newestFirst]) { _, samples, _ in
      done(samples?.first)
    }
    store.execute(query)
  }

  /// One frequency's hearing thresholds (dB HL) per ear; a masked air-conduction
  /// test wins over an unmasked one for the same ear.
  private static func point(_ p: HKAudiogramSensitivityPoint) -> [String: Any] {
    let dbHL = HKUnit.decibelHearingLevel()
    var entry: [String: Any] = ["hz": p.frequency.doubleValue(for: .hertz())]
    if #available(iOS 18.1, *) {
      for side in [HKAudiogramSensitivityTestSide.left, .right] {
        let tests = p.tests.filter { $0.side == side && $0.type == .air }
        if let test = tests.first(where: { $0.masked }) ?? tests.first {
          entry[side == .left ? "left" : "right"] = test.sensitivity.doubleValue(for: dbHL)
        }
      }
    } else {
      if let left = p.leftEarSensitivity { entry["left"] = left.doubleValue(for: dbHL) }
      if let right = p.rightEarSensitivity { entry["right"] = right.doubleValue(for: dbHL) }
    }
    return entry
  }
}
