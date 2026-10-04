//  SMCService.swift — smc.c 위에 올린 Swift 래퍼
//
//  읽기는 누구나 할 수 있지만 쓰기는 root 프로세스(fandeckd)에서만 성공한다.
//  앱에서 write 를 부르면 .permissionDenied 가 나오는 게 정상이고, 앱은
//  대신 데몬에게 소켓으로 요청한다.

import Foundation

public enum SMCError: Error, CustomStringConvertible {
    case cannotOpen
    case callFailed
    case keyNotFound(String)
    case unsupportedType(String)
    case permissionDenied

    public init(code: Int32, key: String = "") {
        switch code {
        case -1: self = .cannotOpen
        case -2: self = .callFailed
        case -3: self = .keyNotFound(key)
        case -4: self = .unsupportedType(key)
        case -5: self = .permissionDenied
        default: self = .callFailed
        }
    }

    public var description: String {
        switch self {
        case .cannotOpen:            return "AppleSMC 서비스를 열 수 없습니다"
        case .callFailed:            return "SMC 호출이 실패했습니다"
        case .keyNotFound(let k):    return "SMC 키를 찾을 수 없습니다: \(k)"
        case .unsupportedType(let k):return "지원하지 않는 SMC 데이터 타입: \(k)"
        case .permissionDenied:      return "SMC 쓰기 권한이 없습니다 (root 필요)"
        }
    }
}

public final class SMCService: @unchecked Sendable {
    public static let shared = SMCService()

    private let lock = NSLock()
    private var isOpen = false
    /// 키 목록은 부팅 후 바뀌지 않으므로 한 번만 훑고 캐시한다(1300여 개라 훑는 데 1초 가까이 걸린다).
    private var cachedKeys: [String]?

    private init() {}

    public func open() throws {
        lock.lock(); defer { lock.unlock() }
        guard !isOpen else { return }
        let rc = fd_smc_open()
        guard rc == 0 else { throw SMCError(code: rc) }
        isOpen = true
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return }
        fd_smc_close()
        isOpen = false
    }

    /// SMC 가 가진 전체 키를 훑는다. 결과는 캐시된다.
    public func allKeys() throws -> [String] {
        if let cached = cachedKeys { return cached }
        try open()
        var count: UInt32 = 0
        let rc = fd_smc_key_count(&count)
        guard rc == 0 else { throw SMCError(code: rc) }

        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<count {
            guard fd_smc_key_at(i, &buf) == 0 else { continue }
            let name = String(cString: buf)
            // 공백 패딩이나 깨진 이름은 버린다.
            if name.count == 4, name.allSatisfy({ $0.isASCII && !$0.isWhitespace }) {
                keys.append(name)
            }
        }
        lock.lock(); cachedKeys = keys; lock.unlock()
        return keys
    }

    /// 숫자형 키 하나를 읽는다. 읽을 수 없으면 nil.
    public func read(_ key: String) -> Double? {
        guard isOpen || (try? open()) != nil else { return nil }
        var value: Double = 0
        let rc = key.withCString { fd_smc_read_number($0, &value) }
        return rc == 0 ? value : nil
    }

    public func keyExists(_ key: String) -> Bool {
        guard isOpen || (try? open()) != nil else { return false }
        return key.withCString { fd_smc_key_exists($0) }
    }

    public func keyType(_ key: String) -> String? {
        guard isOpen || (try? open()) != nil else { return nil }
        var info = fd_smc_keyinfo()
        let rc = key.withCString { fd_smc_key_info($0, &info) }
        guard rc == 0 else { return nil }
        return withUnsafeBytes(of: &info.type) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    // MARK: 쓰기 (root 전용)

    public func writeFloat(_ key: String, _ value: Float) throws {
        try open()
        let rc = key.withCString { fd_smc_write_float($0, value) }
        guard rc == 0 else { throw SMCError(code: rc, key: key) }
    }

    public func writeUInt8(_ key: String, _ value: UInt8) throws {
        try open()
        let rc = key.withCString { fd_smc_write_u8($0, value) }
        guard rc == 0 else { throw SMCError(code: rc, key: key) }
    }

    // MARK: 센서 읽기

    /// 설명자 하나의 값을 구한다. 합성 센서는 소스 키들을 모아 집계한다.
    public func value(for descriptor: SensorDescriptor) -> Double? {
        guard descriptor.isSynthetic else { return read(descriptor.key) }
        var values: [Double] = []
        values.reserveCapacity(descriptor.sourceKeys.count)
        for key in descriptor.sourceKeys {
            // 센서가 꺼져 있을 때 0 이 올라오는데, 평균에 섞이면 값이 망가진다.
            if let v = read(key), v > 0, v < 150 { values.append(v) }
        }
        guard !values.isEmpty else { return nil }
        switch descriptor.aggregation {
        case .average: return values.reduce(0, +) / Double(values.count)
        case .maximum: return values.max()
        case .raw:     return values.first
        }
    }

    public func readAll(_ descriptors: [SensorDescriptor]) -> [SensorReading] {
        descriptors.compactMap { d in
            guard let v = value(for: d) else { return nil }
            return SensorReading(descriptor: d, value: v)
        }
    }

    /// 여러 센서를 한 번에 읽는다.
    ///
    /// 설명자마다 따로 읽으면 같은 SMC 키를 몇 번씩 다시 읽게 된다.
    /// 예를 들어 "시스템 최고 온도"는 온도 키 174개를 전부 훑는데,
    /// 그 키들은 개별 센서로도 이미 목록에 들어 있다. 그래서 한 바퀴에
    /// 500번 넘는 IOKit 왕복이 생기고, 메인 스레드에서 돌리면 UI 가 눈에 띄게 끊긴다.
    ///
    /// 여기서는 필요한 원본 키를 먼저 중복 없이 모아 한 번씩만 읽고,
    /// 합성 센서는 그 결과로 계산한다. 왕복 횟수가 1/3 아래로 줄고,
    /// 모든 값이 같은 순간의 스냅샷이라 센서 간 비교도 정확해진다.
    public func snapshot(_ descriptors: [SensorDescriptor]) -> [String: Double] {
        var rawKeys = Set<String>()
        rawKeys.reserveCapacity(descriptors.count * 2)
        for d in descriptors {
            if d.isSynthetic { rawKeys.formUnion(d.sourceKeys) }
            else { rawKeys.insert(d.key) }
        }

        var raw: [String: Double] = [:]
        raw.reserveCapacity(rawKeys.count)
        for key in rawKeys {
            if let v = read(key) { raw[key] = v }
        }

        var result: [String: Double] = [:]
        result.reserveCapacity(descriptors.count)
        for d in descriptors {
            guard d.isSynthetic else {
                if let v = raw[d.key] { result[d.key] = v }
                continue
            }
            // 꺼져 있는 센서가 0 을 올려 보내면 평균이 망가진다.
            let values = d.sourceKeys.compactMap { raw[$0] }.filter { $0 > 0 && $0 < 150 }
            guard !values.isEmpty else { continue }
            switch d.aggregation {
            case .average: result[d.key] = values.reduce(0, +) / Double(values.count)
            case .maximum: result[d.key] = values.max()
            case .raw:     result[d.key] = values.first
            }
        }
        return result
    }
}
