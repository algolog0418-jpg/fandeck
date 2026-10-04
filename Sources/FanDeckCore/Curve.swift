//  Curve.swift — 팬 커브와 제어 엔진
//
//  원본(Macs Fan Control)은 "센서 온도 A 에서 최소 RPM, B 에서 최대 RPM" 2점 선형만
//  지원한다. 여기서는 점을 원하는 만큼 찍는 다점 커브로 확장하고,
//  소음이 요동치지 않도록 세 겹의 완충을 둔다.
//
//    1) 온도 평활(EMA) — 순간 스파이크로 팬이 튀지 않게
//    2) 히스테리시스   — 온도가 조금 내려갔다고 바로 속도를 낮추지 않게
//    3) 램프 제한      — 초당 변화량을 제한해 소리가 계단식으로 바뀌지 않게

import Foundation

public struct CurvePoint: Codable, Hashable, Identifiable, Sendable, Comparable {
    public var temperature: Double
    public var rpm: Double
    public var id: Double { temperature }

    public init(temperature: Double, rpm: Double) {
        self.temperature = temperature
        self.rpm = rpm
    }

    public static func < (a: CurvePoint, b: CurvePoint) -> Bool {
        a.temperature < b.temperature
    }
}

public struct FanCurve: Codable, Hashable, Sendable {
    public var sensorKey: String
    public var points: [CurvePoint]

    public init(sensorKey: String, points: [CurvePoint]) {
        self.sensorKey = sensorKey
        self.points = points.sorted()
    }

    /// 조용함에 무게를 둔 기본 커브. 45도까지는 최소 회전수를 유지한다.
    public static func defaultCurve(sensorKey: String, minRPM: Double, maxRPM: Double) -> FanCurve {
        FanCurve(sensorKey: sensorKey, points: [
            CurvePoint(temperature: 40, rpm: minRPM),
            CurvePoint(temperature: 55, rpm: minRPM + (maxRPM - minRPM) * 0.18),
            CurvePoint(temperature: 70, rpm: minRPM + (maxRPM - minRPM) * 0.45),
            CurvePoint(temperature: 85, rpm: minRPM + (maxRPM - minRPM) * 0.80),
            CurvePoint(temperature: 95, rpm: maxRPM),
        ])
    }

    /// 온도에 해당하는 RPM 을 선형 보간으로 구한다.
    /// 커브 양 끝 바깥은 끝점 값을 그대로 유지한다.
    public func rpm(at temperature: Double) -> Double {
        guard !points.isEmpty else { return 0 }
        let sorted = points.sorted()
        if temperature <= sorted[0].temperature { return sorted[0].rpm }
        if let last = sorted.last, temperature >= last.temperature { return last.rpm }

        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if temperature >= a.temperature && temperature <= b.temperature {
                let span = b.temperature - a.temperature
                guard span > 0 else { return b.rpm }
                let t = (temperature - a.temperature) / span
                return a.rpm + (b.rpm - a.rpm) * t
            }
        }
        return sorted.last!.rpm
    }
}

public enum FanMode: Codable, Hashable, Sendable {
    case automatic
    case fixed(rpm: Double)
    case curve(FanCurve)

    public var label: String {
        switch self {
        case .automatic:       return "자동"
        case .fixed(let rpm):  return "\(Int(rpm)) rpm 고정"
        case .curve:           return "센서 연동"
        }
    }

    public var shortLabel: String {
        switch self {
        case .automatic: return "자동"
        case .fixed:     return "고정"
        case .curve:     return "커브"
        }
    }
}

/// 팬 하나에 적용할 설정.
public struct FanSetting: Codable, Hashable, Sendable {
    public var fanIndex: Int
    public var mode: FanMode

    public init(fanIndex: Int, mode: FanMode) {
        self.fanIndex = fanIndex
        self.mode = mode
    }
}

/// 과열 방지 장치. 어떤 모드에서도 이 규칙이 최우선으로 적용된다.
public struct SafetySettings: Codable, Hashable, Sendable {
    /// 이 온도를 넘으면 모드와 무관하게 팬을 최대로 돌린다.
    public var criticalTemperature: Double
    /// 임계 상태에서 벗어났다고 판단하는 온도(임계보다 낮게 둬서 깜빡임을 막는다).
    public var recoveryTemperature: Double
    /// 임계 판정에 쓸 센서. 기본은 시스템 전체 최고 온도.
    public var sensorKey: String
    public var enabled: Bool

    public init(criticalTemperature: Double = 95,
                recoveryTemperature: Double = 85,
                sensorKey: String = SensorCatalog.systemMaxKey,
                enabled: Bool = true) {
        self.criticalTemperature = criticalTemperature
        self.recoveryTemperature = recoveryTemperature
        self.sensorKey = sensorKey
        self.enabled = enabled
    }
}

/// 팬 속도가 튀지 않게 다듬는 설정.
public struct SmoothingSettings: Codable, Hashable, Sendable {
    /// 온도 평활 계수(0=완전 평활, 1=평활 없음).
    public var temperatureSmoothing: Double
    /// 속도를 낮추기 전에 온도가 더 떨어져야 하는 폭(°C).
    public var hysteresis: Double
    /// 초당 올릴 수 있는 최대 RPM.
    public var rampUpPerSecond: Double
    /// 초당 내릴 수 있는 최대 RPM.
    public var rampDownPerSecond: Double

    public init(temperatureSmoothing: Double = 0.35,
                hysteresis: Double = 3.0,
                rampUpPerSecond: Double = 400,
                rampDownPerSecond: Double = 120) {
        self.temperatureSmoothing = temperatureSmoothing
        self.hysteresis = hysteresis
        self.rampUpPerSecond = rampUpPerSecond
        self.rampDownPerSecond = rampDownPerSecond
    }
}

/// 팬 하나의 제어 상태를 들고 매 틱 목표 RPM 을 계산한다.
public final class CurveEngine {
    private var smoothedTemperature: Double?
    /// 히스테리시스 기준점. 온도가 이보다 충분히 떨어져야 커브 입력이 내려간다.
    private var effectiveTemperature: Double?
    private var lastAppliedRPM: Double?
    private var inCriticalState = false

    public init() {}

    public func reset() {
        smoothedTemperature = nil
        effectiveTemperature = nil
        lastAppliedRPM = nil
        inCriticalState = false
    }

    public struct Decision: Sendable {
        public let targetRPM: Double?      // nil 이면 시스템 자동에 맡긴다
        public let isCritical: Bool
        public let rawTemperature: Double?
        public let effectiveTemperature: Double?
    }

    /// - Parameters:
    ///   - elapsed: 지난 틱 이후 흐른 시간(초). 램프 제한 계산에 쓴다.
    public func decide(setting: FanSetting,
                       fan: FanInfo,
                       smoothing: SmoothingSettings,
                       safety: SafetySettings,
                       readSensor: (String) -> Double?,
                       elapsed: TimeInterval) -> Decision {

        // 1) 안전장치가 최우선. 임계 온도를 넘으면 즉시 최대 속도로 간다.
        if safety.enabled, let t = readSensor(safety.sensorKey) {
            if t >= safety.criticalTemperature { inCriticalState = true }
            else if t <= safety.recoveryTemperature { inCriticalState = false }
            if inCriticalState {
                lastAppliedRPM = fan.maxRPM
                return Decision(targetRPM: fan.maxRPM, isCritical: true,
                                rawTemperature: t, effectiveTemperature: t)
            }
        }

        switch setting.mode {
        case .automatic:
            reset()
            return Decision(targetRPM: nil, isCritical: false,
                            rawTemperature: nil, effectiveTemperature: nil)

        case .fixed(let rpm):
            let clamped = min(max(rpm, fan.minRPM), fan.maxRPM)
            let limited = applyRamp(target: clamped, smoothing: smoothing, elapsed: elapsed)
            return Decision(targetRPM: limited, isCritical: false,
                            rawTemperature: nil, effectiveTemperature: nil)

        case .curve(let curve):
            guard let raw = readSensor(curve.sensorKey) else {
                // 센서를 못 읽으면 임의로 멈추지 말고 시스템에 돌려준다.
                return Decision(targetRPM: nil, isCritical: false,
                                rawTemperature: nil, effectiveTemperature: nil)
            }

            // 2) 온도 평활
            let alpha = min(max(smoothing.temperatureSmoothing, 0.01), 1.0)
            let smoothed = smoothedTemperature.map { $0 + (raw - $0) * alpha } ?? raw
            smoothedTemperature = smoothed

            // 3) 히스테리시스 — 올라갈 땐 바로 따라가고, 내려갈 땐 폭만큼 버틴다.
            var effective = effectiveTemperature ?? smoothed
            if smoothed > effective {
                effective = smoothed
            } else if smoothed < effective - smoothing.hysteresis {
                effective = smoothed + smoothing.hysteresis
            }
            effectiveTemperature = effective

            let desired = min(max(curve.rpm(at: effective), fan.minRPM), fan.maxRPM)
            // 4) 램프 제한
            let limited = applyRamp(target: desired, smoothing: smoothing, elapsed: elapsed)
            return Decision(targetRPM: limited, isCritical: false,
                            rawTemperature: raw, effectiveTemperature: effective)
        }
    }

    private func applyRamp(target: Double, smoothing: SmoothingSettings,
                           elapsed: TimeInterval) -> Double {
        guard let last = lastAppliedRPM else {
            lastAppliedRPM = target
            return target
        }
        let dt = max(min(elapsed, 5.0), 0.05)
        let maxUp = smoothing.rampUpPerSecond * dt
        let maxDown = smoothing.rampDownPerSecond * dt
        let delta = target - last
        let applied: Double
        if delta > maxUp        { applied = last + maxUp }
        else if delta < -maxDown { applied = last - maxDown }
        else                     { applied = target }
        lastAppliedRPM = applied
        return applied
    }
}
