//  DriveTemperature.swift — 외장 드라이브 온도
//
//  내장 SSD 는 SMC 가 온도를 그대로 준다(TH0x 등). 하지만 USB·Thunderbolt 로 붙인
//  드라이브는 SMC 가 모르기 때문에, 드라이브 자체의 S.M.A.R.T. 정보를 읽어야 한다.
//  macOS 에는 그걸 읽는 기본 명령이 없어서 smartmontools 의 smartctl 에 의존한다.
//  없으면 이 기능은 조용히 꺼진다 — 설치를 강요하지 않는다.

import Foundation

public struct DriveTemp: Sendable, Hashable {
    public let device: String
    public let name: String
    public let celsius: Double
}

public enum DriveTemperature {

    /// Homebrew 로 설치하면 이 두 곳 중 하나에 있다.
    public static var smartctlPath: String? {
        ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl", "/usr/sbin/smartctl"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isAvailable: Bool { smartctlPath != nil }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// 외장으로 붙은 물리 디스크들의 온도. smartctl 이 없으면 빈 배열.
    ///
    /// smartctl 은 보통 root 권한을 요구하므로, 실제로는 제어 서비스(root)에서 부르는 편이
    /// 안정적이다. 권한이 없으면 그냥 읽히지 않고 빈 결과가 된다.
    public static func externalDrives() -> [DriveTemp] {
        guard let smartctl = smartctlPath else { return [] }
        guard let scan = run(smartctl, ["--scan", "-j"]),
              let data = scan.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [[String: Any]] else { return [] }

        var result: [DriveTemp] = []
        for device in devices {
            guard let name = device["name"] as? String else { continue }
            guard let out = run(smartctl, ["-A", "-i", "-j", name]),
                  let d = out.data(using: .utf8),
                  let info = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }

            // 내장 디스크는 SMC 쪽에서 이미 보여주므로 중복으로 싣지 않는다.
            let isRemovable = (info["device"] as? [String: Any])?["protocol"] as? String == "USB"
                || (info["smart_support"] as? [String: Any]) != nil
                && (info["model_name"] as? String)?.isEmpty == false
                && (info["device"] as? [String: Any])?["type"] as? String != "nvme"

            guard let temp = (info["temperature"] as? [String: Any])?["current"] as? Double
                ?? ((info["temperature"] as? [String: Any])?["current"] as? Int).map(Double.init)
            else { continue }
            guard temp > 0, temp < 120 else { continue }

            let model = (info["model_name"] as? String) ?? name
            if isRemovable {
                result.append(DriveTemp(device: name, name: model, celsius: temp))
            }
        }
        return result
    }
}
