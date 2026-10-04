//  History.swift — 시계열 기록
//
//  데몬이 상주하면서 계속 기록하므로, 앱을 껐다 켜도 지난 몇 시간의 추이를 그대로 볼 수 있다.
//  (원본 Macs Fan Control 에는 없는 기능이다.)
//  메모리만 쓰고 디스크에는 남기지 않는다 — 링 버퍼라 오래된 값부터 자동으로 밀려난다.

import Foundation

public struct HistorySample: Codable, Hashable, Sendable {
    public let timestamp: Double          // Unix epoch 초
    /// 센서 키 → 값. 기록 대상 센서만 담는다.
    public let values: [String: Double]
    public let fanRPM: [Int: Double]

    public init(timestamp: Double, values: [String: Double], fanRPM: [Int: Double]) {
        self.timestamp = timestamp
        self.values = values
        self.fanRPM = fanRPM
    }

    public var date: Date { Date(timeIntervalSince1970: timestamp) }
}

/// 고정 크기 링 버퍼. 가장 오래된 표본부터 덮어쓴다.
public final class HistoryBuffer: @unchecked Sendable {
    private var storage: [HistorySample?]
    private var writeIndex = 0
    private var filled = false
    private let lock = NSLock()
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
        self.storage = Array(repeating: nil, count: self.capacity)
    }

    public func append(_ sample: HistorySample) {
        lock.lock(); defer { lock.unlock() }
        storage[writeIndex] = sample
        writeIndex = (writeIndex + 1) % capacity
        if writeIndex == 0 { filled = true }
    }

    /// 오래된 것부터 시간순으로 돌려준다.
    public func samples(since: Double? = nil, maxCount: Int? = nil) -> [HistorySample] {
        lock.lock(); defer { lock.unlock() }
        var result: [HistorySample] = []
        result.reserveCapacity(filled ? capacity : writeIndex)
        let count = filled ? capacity : writeIndex
        for i in 0..<count {
            let idx = filled ? (writeIndex + i) % capacity : i
            guard let s = storage[idx] else { continue }
            if let since, s.timestamp < since { continue }
            result.append(s)
        }
        if let maxCount, result.count > maxCount {
            // 표본이 너무 많으면 균등 간격으로 솎아낸다. 그래프를 그리는 데는 충분하다.
            let stride = Double(result.count) / Double(maxCount)
            var thinned: [HistorySample] = []
            thinned.reserveCapacity(maxCount)
            var pos = 0.0
            while Int(pos) < result.count && thinned.count < maxCount {
                thinned.append(result[Int(pos)])
                pos += stride
            }
            // 가장 최근 값은 반드시 포함시킨다.
            if let last = result.last, thinned.last?.timestamp != last.timestamp {
                thinned.append(last)
            }
            return thinned
        }
        return result
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return filled ? capacity : writeIndex
    }
}

/// 한 센서에 대한 통계 요약.
public struct SensorStatistics: Codable, Hashable, Sendable {
    public let key: String
    public let minimum: Double
    public let maximum: Double
    public let average: Double
    public let current: Double
    public let sampleCount: Int

    public init(key: String, minimum: Double, maximum: Double,
                average: Double, current: Double, sampleCount: Int) {
        self.key = key
        self.minimum = minimum
        self.maximum = maximum
        self.average = average
        self.current = current
        self.sampleCount = sampleCount
    }

    public static func compute(key: String, samples: [HistorySample]) -> SensorStatistics? {
        let values = samples.compactMap { $0.values[key] }
        guard let first = values.first else { return nil }
        var mn = first, mx = first, sum = 0.0
        for v in values {
            if v < mn { mn = v }
            if v > mx { mx = v }
            sum += v
        }
        return SensorStatistics(key: key, minimum: mn, maximum: mx,
                                average: sum / Double(values.count),
                                current: values.last ?? first,
                                sampleCount: values.count)
    }
}

/// RPM 으로 체감 소음을 어림한다. 실측이 아니라 참고용 지표다.
public enum NoiseEstimator {
    /// 팬 소음은 회전수의 약 5제곱에 비례한다고 알려져 있다(음향 출력 기준).
    /// 최소 회전수를 기준 dB 로 두고 상대적인 증가분만 보여준다.
    public static func estimatedDB(rpm: Double, minRPM: Double, maxRPM: Double) -> Double {
        guard rpm > 0, minRPM > 0 else { return 0 }
        let baseDB = 18.0      // 최소 회전수에서의 대략적인 체감 소음
        let topDB  = 45.0      // 최대 회전수에서의 대략적인 체감 소음
        guard maxRPM > minRPM else { return baseDB }
        let ratio = max(rpm / minRPM, 1.0)
        let maxRatio = maxRPM / minRPM
        // 50·log10(비율) 이 음향 출력의 5제곱 법칙에 해당한다.
        let raw = 50.0 * log10(ratio)
        let rawMax = 50.0 * log10(maxRatio)
        guard rawMax > 0 else { return baseDB }
        return baseDB + (topDB - baseDB) * (raw / rawMax)
    }

    public static func label(forDB db: Double) -> String {
        switch db {
        case ..<22:  return "거의 무음"
        case ..<28:  return "조용함"
        case ..<34:  return "들림"
        case ..<40:  return "뚜렷함"
        default:     return "시끄러움"
        }
    }
}
