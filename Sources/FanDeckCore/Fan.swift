//  Fan.swift — 팬 하나의 상태 읽기와 목표 RPM 쓰기
//
//  Apple Silicon 에서 팬 제어는 F{n}Tg(목표 RPM, flt) 에 값을 쓰는 것으로 이뤄진다.
//  F{n}Md(수동 모드 플래그)는 이 맥에서 0 인 채로도 F{n}Tg 가 그대로 반영되지만,
//  모델에 따라 Md=1 을 요구하는 경우가 있어 "쓰고 나서 확인" 전략을 쓴다.
//  일부 M3/M4 모델은 thermalmonitord 가 쓰기를 되돌리는데, 그때는 Ftst 로
//  잠금을 풀어야 한다. 이 맥엔 Ftst 키가 없어서 해당하지 않지만,
//  키가 있으면 자동으로 쓰도록 분기를 남겨둔다.

import Foundation

public struct FanInfo: Identifiable, Sendable, Codable, Hashable {
    public let index: Int
    public var name: String
    public var currentRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double
    public var mode: Int

    public var id: Int { index }

    /// 최소~최대 사이에서 현재 속도가 차지하는 비율(0~1).
    public var loadFraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(max((currentRPM - minRPM) / (maxRPM - minRPM), 0), 1)
    }
}

public final class FanController: @unchecked Sendable {
    public static let shared = FanController()
    private let smc = SMCService.shared
    private init() {}

    private func key(_ index: Int, _ suffix: String) -> String { "F\(index)\(suffix)" }

    public func fanCount() -> Int {
        guard let n = smc.read("FNum") else { return 0 }
        return Int(n)
    }

    /// Mac mini 처럼 SMC 에 팬 이름 키가 없는 모델이 많아서, 개수로 이름을 정한다.
    private func defaultName(index: Int, total: Int) -> String {
        if total == 1 { return L.t("배기 팬", "Exhaust") }
        return L.t("팬 \(index + 1)", "Fan \(index + 1)")
    }

    public func readFan(_ index: Int) -> FanInfo? {
        guard let current = smc.read(key(index, "Ac")) else { return nil }
        let minR = smc.read(key(index, "Mn")) ?? 0
        let maxR = smc.read(key(index, "Mx")) ?? 0
        let target = smc.read(key(index, "Tg")) ?? current
        let mode = Int(smc.read(key(index, "Md")) ?? 0)
        return FanInfo(index: index,
                       name: defaultName(index: index, total: fanCount()),
                       currentRPM: current, minRPM: minR, maxRPM: maxR,
                       targetRPM: target, mode: mode)
    }

    public func readAllFans() -> [FanInfo] {
        (0..<fanCount()).compactMap { readFan($0) }
    }

    // MARK: 쓰기 (root 전용)

    /// 일부 모델에서 팬 쓰기를 막는 진단 잠금. 키가 있을 때만 건드린다.
    private var hasForceTestKey: Bool { smc.keyExists("Ftst") }

    private func unlockIfNeeded() {
        guard hasForceTestKey else { return }
        try? smc.writeUInt8("Ftst", 1)
    }

    private func relockIfNeeded() {
        guard hasForceTestKey else { return }
        try? smc.writeUInt8("Ftst", 0)
    }

    /// 목표 RPM 을 설정한다. 범위를 벗어난 값은 팬의 최소/최대로 잘린다.
    @discardableResult
    public func setTarget(_ index: Int, rpm: Double) throws -> Double {
        guard let fan = readFan(index) else { throw SMCError.keyNotFound("F\(index)Ac") }
        let clamped = min(max(rpm, fan.minRPM), fan.maxRPM)

        unlockIfNeeded()
        defer { relockIfNeeded() }

        // 수동 모드 플래그가 있는 모델을 위해 먼저 1 을 시도한다. 실패해도 계속 진행한다.
        try? smc.writeUInt8(key(index, "Md"), 1)
        try smc.writeFloat(key(index, "Tg"), Float(clamped))
        return clamped
    }

    /// 시스템 자동 제어로 되돌린다.
    public func setAutomatic(_ index: Int) throws {
        unlockIfNeeded()
        defer { relockIfNeeded() }
        try? smc.writeUInt8(key(index, "Md"), 0)
        // 모드 키가 없는 모델에서는 목표를 최소값으로 낮춰야 시스템이 다시 가져간다.
        if let fan = readFan(index) {
            try? smc.writeFloat(key(index, "Tg"), Float(fan.minRPM))
        }
    }

    /// 쓰기가 실제로 먹히는지 확인한다. 설치 직후 1회 진단에 쓴다.
    public func verifyWritable(_ index: Int) -> Bool {
        guard let fan = readFan(index) else { return false }
        let original = fan.targetRPM
        // 최소보다 200rpm 높은 값으로 시험한다. 올리는 방향이라 과열 위험이 없다.
        let probe = min(fan.minRPM + 200, fan.maxRPM)
        guard (try? setTarget(index, rpm: probe)) != nil else { return false }
        Thread.sleep(forTimeInterval: 0.4)
        let readback = smc.read(key(index, "Tg")) ?? -1
        _ = try? setTarget(index, rpm: original)
        return abs(readback - probe) < 50
    }
}
