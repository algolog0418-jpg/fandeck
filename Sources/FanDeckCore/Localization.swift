//  Localization.swift — 한국어 / 영어 전환
//
//  문자열 파일(.strings)을 쓰면 번들 구조와 빌드 설정이 복잡해지고,
//  언어를 바꿀 때 앱을 다시 켜야 한다. 이 앱은 설정에서 고른 즉시 바뀌어야 해서
//  두 언어를 코드에 나란히 두고 고르는 방식으로 간다.

import Foundation

public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system, korean, english, japanese, chinese

    public var displayName: String {
        switch self {
        case .system:   return "시스템 설정 따름 / System"
        case .korean:   return "한국어 (Korean)"
        case .english:  return "English (영어)"
        case .japanese: return "日本語 (Japanese)"
        case .chinese:  return "简体中文 (Chinese)"
        }
    }

    /// 실제로 적용할 언어. system 이면 맥의 언어 설정을 따른다.
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("ko") { return .korean }
        if preferred.hasPrefix("ja") { return .japanese }
        if preferred.hasPrefix("zh") { return .chinese }
        return .english
    }
}

/// 화면에 보이는 모든 문자열이 지나가는 자리.
///
/// `L.t("저장", "Save")` 처럼 한국어와 영어를 나란히 적는다.
/// 번역을 빠뜨리면 컴파일이 안 되니 한쪽만 남는 일이 없다.
public enum L {
    /// 현재 언어. 설정이 바뀌면 앱이 여기에 반영한다.
    public nonisolated(unsafe) static var language: AppLanguage = .system

    public static var isKorean: Bool { language.resolved == .korean }

    /// 한국어와 영어를 받아, 고른 언어에 맞는 문자열을 돌려준다.
    /// 일본어·중국어는 한국어를 열쇠로 번역표에서 찾고, 없으면 영어로 돌아간다.
    public static func t(_ korean: String, _ english: String) -> String {
        switch language.resolved {
        case .korean:   return korean
        case .japanese: return Translations.japanese[korean] ?? english
        case .chinese:  return Translations.chinese[korean] ?? english
        default:        return english
        }
    }

    private static var table: [String: String]? {
        switch language.resolved {
        case .japanese: return Translations.japanese
        case .chinese:  return Translations.chinese
        default:        return nil
        }
    }

    /// 긴 낱말부터 바꿔야 "CPU 최고 온도" 가 "CPU" 와 "최고" 로 쪼개지지 않는다.
    private nonisolated(unsafe) static var sortedKeysCache: [AppLanguage: [String]] = [:]

    private static func sortedKeys(for language: AppLanguage) -> [String] {
        if let cached = sortedKeysCache[language] { return cached }
        let keys = (table ?? [:]).keys.sorted { $0.count > $1.count }
        sortedKeysCache[language] = keys
        return keys
    }

    /// 센서 이름처럼 번호가 섞인 문자열을 번역한다.
    /// 통째로 찾아보고, 없으면 아는 낱말만 바꿔 끼운다. 그래도 안 바뀌면 영어로 돌아간다.
    public static func translateName(_ korean: String, fallback english: String) -> String {
        let resolved = language.resolved
        if resolved == .korean { return korean }
        guard let table else { return english }
        if let exact = table[korean] { return exact }

        var result = korean
        var replaced = false
        for key in sortedKeys(for: resolved) where result.contains(key) {
            result = result.replacingOccurrences(of: key, with: table[key]!)
            replaced = true
        }
        return replaced ? result : english
    }
}
