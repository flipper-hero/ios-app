import XCTest

/// Drives the app in demo mode (sample data, no Flipper or API key) through every screen.
final class FlipperHeroUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(tab: Int = 0, _ environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-noSplash"]
        app.launchEnvironment = ["FH_DEMO": "1", "FH_TAB": "\(tab)"].merging(environment) { $1 }
        app.launch()
        return app
    }

    private func text(_ app: XCUIApplication, containing value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    func testEveryTabShowsTheBrandHeader() {
        let app = launch()
        for tab in ["Device", "Remote", "Files", "Agent", "Settings"] {
            app.tabBars.buttons[tab].tap()
            let header = app.descendants(matching: .any)["brandHeader"]
            XCTAssertTrue(header.waitForExistence(timeout: 5), "header missing on \(tab)")
            XCTAssertTrue(header.label.contains("FlipperHero"), tab)
            XCTAssertTrue(header.label.contains("Laisear"), "status line on \(tab)")
        }
    }

    func testDeviceShowsCardFirmwareAndActions() {
        let app = launch(tab: 0)
        XCTAssertTrue(text(app, containing: "Momentum mntm-012").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Up to date"].exists || text(app, containing: "Up to date").exists)
        XCTAssertTrue(app.buttons["Reinstall"].exists)
        for action in ["Refresh", "Rescan", "Restart", "Disconnect"] {
            XCTAssertTrue(app.buttons[action].exists, action)
        }
    }

    func testReinstallAsksFirst() {
        let app = launch(tab: 0)
        app.buttons["Reinstall"].tap()
        XCTAssertTrue(app.staticTexts["Reinstall firmware?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Download and reinstall"].exists)
    }

    func testRenameAllowsAtMostEightValidCharacters() {
        let app = launch(tab: 0)
        app.buttons["renameButton"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("!12345")
        XCTAssertEqual(field.value as? String, "Laisear1", "invalid characters dropped, trimmed to 8")
        app.alerts.buttons["Cancel"].tap()
    }

    func testRemoteShowsTheMirrorAndAllKeys() {
        let app = launch(tab: 1)
        XCTAssertTrue(app.staticTexts["LIVE"].waitForExistence(timeout: 5))
        for key in ["up", "down", "left", "right", "ok", "back"] {
            XCTAssertTrue(app.buttons[key].exists || app.descendants(matching: .any)[key].exists, key)
        }
        app.descendants(matching: .any)["ok"].tap()
    }

    func testFilesShowsTheSDCard() {
        let app = launch(tab: 2)
        XCTAssertTrue(app.staticTexts["SD card"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, containing: "free of").exists)
    }

    func testAgentShowsTheConversationAndToolCards() {
        let app = launch(tab: 3)
        XCTAssertTrue(text(app, containing: "Hotel_Room_204.nfc").waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, containing: "/ext/backup").exists)
    }

    func testYoloNeedsConfirmationAndShowsTheBadge() {
        let app = launch(tab: 4)
        let toggle = app.switches["YOLO mode"]
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Enable YOLO mode?"].waitForExistence(timeout: 3))
        app.buttons["Enable YOLO"].tap()
        let header = app.descendants(matching: .any)["brandHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        XCTAssertTrue(header.label.contains("YOLO"), "YOLO badge in the header")
    }

    func testPermissionRequestCanBeDenied() {
        let app = launch(tab: 3, ["FH_DEMO_APPROVAL": "1"])
        let deny = app.buttons["Deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, containing: "Turn on YOLO mode").exists)
        deny.tap()
        XCTAssertTrue(deny.waitForNonExistence(timeout: 3))
    }

    func testPermissionChangeNeedsAHold() {
        let app = launch(tab: 3, ["FH_DEMO_APPROVAL": "1"])
        let hold = app.descendants(matching: .any)["Hold to allow"]
        XCTAssertTrue(hold.waitForExistence(timeout: 5))
        hold.tap()
        XCTAssertTrue(hold.exists, "a tap is not enough")
        hold.press(forDuration: 1.8)
        XCTAssertTrue(hold.waitForNonExistence(timeout: 3))
    }

    func testEngagementBannerShowsAndDisarms() {
        let app = launch(tab: 3, ["FH_DEMO_ENGAGED": "1"])
        XCTAssertTrue(text(app, containing: "ENGAGED").waitForExistence(timeout: 5))
        app.buttons["Disarm"].firstMatch.tap()
        XCTAssertTrue(text(app, containing: "ENGAGED").waitForNonExistence(timeout: 3))
    }

    func testEngagementSectionOpensTheArmSheet() {
        let app = launch(tab: 4)
        let arm = app.buttons["Arm engagement mode..."]
        XCTAssertTrue(arm.waitForExistence(timeout: 5))
        for _ in 0..<5 where !arm.isHittable { app.swipeUp() }
        arm.tap()
        let raw = app.switches["Raw device commands (rpc_raw)"]
        if !raw.waitForExistence(timeout: 5) {
            // A tap right after the swipe can be swallowed by the scroll animation.
            arm.tap()
            XCTAssertTrue(raw.waitForExistence(timeout: 5))
        }
        app.buttons["Cancel"].firstMatch.tap()
    }
}
