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
            button.image = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: "FanDeck")
            button.imagePosition = .imageLeading
            button.title = " " + model.menuBarTitle
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item

        // 글자가 실제로 바뀔 때만 갱신한다.
        model.onMenuBarTitleChange = { [weak self] title in
            self?.statusItem?.button?.title = " " + title
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem?.button else { return }

        let popover = NSPopover()
        popover.behavior = .transient
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
