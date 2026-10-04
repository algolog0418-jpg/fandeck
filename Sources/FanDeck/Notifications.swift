//  Notifications.swift — 온도 경고 알림
//
//  임계 온도를 넘으면 한 번 알리고, 충분히 식을 때까지는 다시 알리지 않는다.
//  계속 울리면 알림을 꺼버리게 되므로 한 번만 울리는 게 중요하다.

import Foundation
import UserNotifications
import AppKit

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var authorized = false
    private var isInAlertState = false
    private var lastNotifiedAt: Date?
    /// 같은 경고를 반복하지 않기 위한 최소 간격.
    private let minimumInterval: TimeInterval = 300

    private init() {}

    func requestAuthorizationIfNeeded() {
        // 서명되지 않은 번들에서는 알림 센터를 쓸 수 없다. 그 경우 조용히 포기한다.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorized = granted }
            }
    }

    /// 매 틱 호출된다. 상태 전이가 일어날 때만 알린다.
    func evaluate(temperature: Double?, threshold: Double?, sensorName: String) {
        guard let threshold, let temperature else {
            isInAlertState = false
            return
        }

        if temperature >= threshold {
            guard !isInAlertState else { return }
            // 임계 아래로 충분히 내려갔다 올라온 경우에만 다시 알린다.
            if let last = lastNotifiedAt, Date().timeIntervalSince(last) < minimumInterval { return }
            isInAlertState = true
            lastNotifiedAt = Date()
            deliver(title: "온도가 높습니다",
                    body: String(format: "%@ 가 %.0f°C 입니다 (기준 %.0f°C)",
                                 sensorName, temperature, threshold))
        } else if temperature < threshold - 5 {
            // 기준보다 5도 아래로 내려가야 경고 상태를 푼다. 경계에서 깜빡이는 걸 막는다.
            isInAlertState = false
        }
    }

    private func deliver(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
