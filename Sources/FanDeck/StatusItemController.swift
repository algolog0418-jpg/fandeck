//  StatusItemController.swift — 메뉴 막대 아이템 (AppKit)
//
//  처음에는 SwiftUI 의 MenuBarExtra 를 썼는데, 창을 닫아 둔 채로도 CPU 를 계속 쓰고
//  메모리가 1분에 수십 MB 씩 늘었다. 메뉴 막대 글자가 바뀔 때마다 SwiftUI 가
//  내부 창과 뷰를 다시 만드는 것으로 보였다.
//
//  메뉴 막대는 글자 하나만 바꾸면 되는 자리라 AppKit 으로 직접 다루는 편이 훨씬 가볍다.
//  NSStatusItem 의 제목을 바꾸는 건 비용이 거의 없고, 팝오버는 열려 있을 때만 존재한다.

import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        setup()
    }

    private func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
        applyAppearance()

        // 글자가 실제로 바뀔 때만 갱신한다.
        model.onMenuBarTitleChange = { [weak self] title in
            self?.applyTitle(title)
        }
        model.onMenuBarAppearanceChange = { [weak self] in
            self?.applyAppearance()
        }
    }

    /// 두 줄 표시는 NSStatusItem 이 기본으로 지원하지 않아서,
    /// 줄바꿈이 들어오면 작은 글씨의 attributed 문자열로 직접 그린다.
    private func applyTitle(_ title: String) {
        guard let button = statusItem?.button else { return }
        if title.contains("\n") {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineSpacing = -3
            button.attributedTitle = NSAttributedString(string: " " + title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .paragraphStyle: style,
            ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = " " + title
        }
    }

    /// 아이콘 표시 방식을 설정에 맞춘다.
    func applyAppearance() {
        guard let button = statusItem?.button else { return }
        let style = model.config?.menuBarIconStyle ?? .monochrome
        switch style {
        case .hidden:
            button.image = nil
        case .monochrome:
            let image = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: "FanDeck")
            image?.isTemplate = true          // 메뉴 막대 색(흑/백)에 자동으로 맞춰진다
            button.image = image
        case .colored:
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemTeal])
            let image = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: "FanDeck")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
        }
        applyTitle(model.menuBarTitle)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem?.button else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        // 내용이 직접 배경을 칠하므로 팝오버의 반투명 효과는 끈다.
        popover.appearance = NSApp.effectiveAppearance
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarView(model: model))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
        model.isMenuOpen = true
    }

    func popoverDidClose(_ notification: Notification) {
        // 팝오버를 닫으면 뷰까지 버린다. 안 보이는 화면을 계속 갱신할 이유가 없다.
        model.isMenuOpen = false
        popover = nil
    }
}
