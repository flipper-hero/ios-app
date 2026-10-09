# AGENTS.md

Guidance for anyone, human or AI, changing FlipperHero.

## The parity rule

**Every function the UI offers must also be available to the chat agent as a tool.**
When you add or change something a user can do in the app, add or update the matching tool in the
same change, with a test. "The agent can't do X but the button can" is a bug.

Exactly one class of exceptions, and it is deliberate:

- **The agent must never silently loosen its own permissions.** Turning on YOLO mode, turning on
  auto-approve for medium risk, and turning off "still ask after reading Flipper content" are tools,
  but they are marked `requiresExplicitConsent` and always show the user a permission dialog, even
  when YOLO or auto-approve is already on. Tightening (turning any of these off) needs no dialog.
- **Credentials are out of reach.** No tool reads or writes provider API keys.
  `get_app_settings` only reports whether one is stored.
- Connecting to and disconnecting from a Flipper is not a tool: the agent only exists while connected.

Current mapping, keep it up to date:

| UI | Tool |
|---|---|
| Device: name, firmware, commit, battery, SD card | `get_device_info`, `get_power_info`, `get_storage_info` |
| Device: rename | `set_device_name` |
| Device: restart | `restart_device` |
| Device: firmware distribution and update notice | `check_firmware` |
| Device: install firmware update, progress, cancel | `install_firmware_update`, `firmware_update_status`, `cancel_firmware_update` |
| Device: inventory, rescan | `refresh_device_knowledge` (inventory is also in the system prompt) |
| Files: browse, open | `list_directory`, `read_file` |
| Settings: YOLO, ask-after-reading, auto-approve medium | `set_yolo_mode`, `set_yolo_asks_after_reading`, `set_auto_approve_medium` (consent dialog when loosening) |
| Settings: engagement mode arm dialog, banner, Live Activity | `set_engagement_mode` (consent dialog when arming) |
| Settings: auto-connect, provider, model, regional API base URL | `set_auto_connect`, `set_ai_provider`, `set_model` |
| Settings: model catalog, connection test | `list_models`, `test_model_connection` (uses a stored key; saving/removing keys remains credential-only UI) |
| Settings: audit log | `get_audit_log` |
| Settings: audit log report export | `generate_engagement_report` |
| Settings: read the current values | `get_app_settings` |
| Chat menu: read replies aloud | `set_read_aloud` |
| Remote: live screen | `look_at_screen` |
| Remote: buttons (tap, hold) | `press_buttons` (`long_` prefix for a long press) |
| Shortcuts: ask the agent | the chat itself |
| Shortcuts: battery | `get_power_info` |
| Shortcuts: emulate a card or key | `emulate_nfc`, `emulate_rfid`, `emulate_ibutton` |
| Shortcuts: send a signal | `transmit_subghz`, `transmit_infrared` |
| Shortcuts and Live Activity: stop | `stop_app` |
| Live Activity: cancel firmware update | `cancel_firmware_update` |

Siri and Shortcuts run every action that changes something through `AppModel.runShortcut`, which
builds a `ToolExecutor` with the normal policy. Only plain reads like the battery may go to the
device directly; anything else would skip the risk check and the audit log.

Tools without a UI counterpart (transmit, emulate, Bad KB, payload generation, FapHub, GitHub) are
fine; parity only has to hold in the UI-to-agent direction.

## Safety rules that are not negotiable

- Risk is computed in `RiskAssessor` from the parsed, validated tool call. Never let the model
  supply or influence the risk level.
- Everything read from the device or the internet (file contents, file names, search results, the
  inventory, the audit log) goes through `Untrusted.wrap` and taints the turn.
- `/int`, key and secret files, `..` paths and recursive deletes of top-level folders stay blocked.
  YOLO does not change that. Only engagement mode armed with `raw_rpc` reaches past the path
  guards, and only through `rpc_raw`, which the operator arms in a dialog of its own.
- No general raw CLI tool. The one escape hatch is `rpc_raw`, gated behind an explicit
  engagement-mode capability, so the risk model is bypassed only when the operator says so.
- What the user approves is exactly what gets executed: generated payloads and downloads are
  prepared during approval and reused, never generated or fetched a second time.

## Engagement mode

For authorized engagements the operator can pre-approve a session instead of confirming every
step. The invariants:

- Arming is a permission change (`set_engagement_mode` with `enabled: true`), so it always shows
  the consent dialog, even under YOLO or an armed engagement. The agent can only ask.
- The state lives in `EngagementState` (AgentKit), is session-only, never persisted, and the app
  disarms on disconnect. The UI arm path is `AppModel.applyEngagement(audit: true)`; the agent
  path goes through `AppControlsBridge` and is audited by the executor as usual.
- Capabilities (`EngagementProfile`): `auto_approvals` skips per-action prompts (blocked levels
  stay blocked), `raw_rpc` unlocks `rpc_raw`, `auto_badusb` unlocks `badusb_execute`. The executor
  refuses capability-gated tools while the capability is not armed.
- Auto-approved actions under an armed engagement are audited with the `engaged` decision.
- The operator's scope note is shown on the banner, the Live Activity and in the system prompt.
  It is free text from a human, but still fenced like other content before it reaches the model.

## Editions

There are two editions of the same sources, split at compile time by `FLIPPERHERO_STORE`:

- **Open source edition** (default; `Debug`, `Release`, `swift test`): everything.
- **Store edition** (`DebugStore`, `ReleaseStore`, the `FlipperHeroStore` scheme): compiles the
  red team capabilities out entirely. Stripped: `badusb_execute`, `rpc_raw`, `gpio`,
  `set_engagement_mode`, `generate_engagement_report`, the badusb kind of `forge_payload`, the
  engagement UI (arm sheet, banner, Live Activity, disarm intent) and the operator persona in
  `AgentPrompts` (the store prompt is the neutral assistant). What remains is in line with what
  the official Flipper app already offers on the App Store.

Rules that are not negotiable:

- The flag reaches the SwiftPM packages only through the command line, so a store build must go
  through `scripts/build-store.sh`. Building the `FlipperHeroStore` scheme without the script
  produces the full open source edition in store clothes; never upload that.
- The store edition must not contain a runtime switch that re-enables anything. Capabilities are
  removed by `#if`, not hidden by a setting. If you add a red team capability, extend the `#if`
  guards and the stripped-string check in the same change.
- The store listing describes the store edition. The readme says plainly that the open source
  build has more.

Verify a store build by scanning the products: `strings FlipperHero.debug.dylib | grep
badusb_execute` must come up empty, and `swift build -Xswiftc -D -Xswiftc FLIPPERHERO_STORE` must
compile. CI runs that compile check.

## Localization

FlipperHero ships in English, German, French, Spanish, Portuguese (Brazil), Italian, Russian,
Ukrainian, Polish, Turkish, Arabic, Hindi, Simplified Chinese, Japanese and Korean.

- All user-facing text goes through String Catalogs (`*.xcstrings`). SwiftUI literals are picked up
  automatically. Computed strings use `String(localized:)` in the app and `L(...)` in FlipperKit and
  AgentKit, which reads the module's own catalog.
- Approval summaries, risk reasons and errors are user-facing and must be localized. What goes to
  the model as tool output can stay English.
- `LocalizationTests` fails when a key is missing a language or its placeholders differ from English.
  Build once so Xcode adds new keys to the catalogs, then translate them in Xcode, or with
  `xcodebuild -exportLocalizations` and `-importLocalizations`.
- Do not build sentences by concatenation, and avoid "3 file(s)" plurals: Arabic has six plural
  forms. Show a number next to an icon, or use the catalog's plural variations.
- The Flipper's screen mirror and D-pad stay left-to-right in right-to-left languages, because they
  represent the physical device.

## Layout

- `Sources/FlipperProto`: generated protobuf Swift (`scripts/gen-proto.sh`). Do not edit by hand.
- `Sources/FlipperKit`: framing, `FlipperRPCClient`, device API, CoreBluetooth transport.
- `Sources/AgentKit`: tools, risk, approval, executor, session, provider APIs, catalogs.
- `App/`: SwiftUI app, intents (`Intents.swift`). `project.yml` is the XcodeGen spec; the `.xcodeproj` is generated.
- `Widgets/`: widget extension with the Live Activity. `Shared/`: compiled into app and extension;
  code that needs the app is behind `#if !WIDGET_EXTENSION`.

## Build and test

```sh
swift test                                    # needs full Xcode for XCTest
cp Config/Local.xcconfig.example Config/Local.xcconfig   # once, then fill in your team
xcodegen generate
xcodebuild test -project FlipperHero.xcodeproj -scheme FlipperHero \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

A new agent tool needs a sample call in `ToolSweepTests.samples`; the sweep fails otherwise. New UI
belongs in `FlipperHeroUITests` (demo mode, no hardware).

Debug builds understand `FH_DEMO=1` (sample data, no Flipper needed), `FH_DEMO_APPROVAL=1`,
`FH_DEMO_YOLO=1`, `FH_DEMO_ACTIVITY=1` (sample Live Activity), `FH_TAB=0..4` and the launch argument `-noSplash`. Use them for screenshots.

Bluetooth only works on a real iPhone. When testing against hardware, run the app with
`xcrun devicectl device process launch --console ...`; debug builds print BLE and app events.

## Hardware facts learned the hard way

- Never write to the serial service's RPC status characteristic (`...228E64FE0000`). A `0` there
  makes the firmware restart its Bluetooth profile and drops the link.
- Flow control is a big-endian UInt32 of free buffer bytes on the Flipper.
- Over RPC, power info keys use underscores: `charge_level`, `charge_state`, not dotted names.
- The custom device name lives in `/ext/dolphin/name.settings` (Momentum), max 8 characters,
  and only applies after a restart.
- Bad KB is opened with a script loaded. The firmware's work scene starts the script on the OK
  input event (`bad_usb_scene_work_on_event`), which is how `badusb_execute` runs it: open with
  the file, send OK over RPC, confirm with a screen capture. Without engagement mode the script
  is only loaded and the operator presses Run.
- App control over RPC: start the app with args `"RPC"`, then `app_load_file`, then button
  press/release. NFC, RFID and iButton start emulating on load.

## Conventions

- Keep changes small and tested. `swift test` must stay green.
- Tests use `SimulatedFlipper` (FlipperKit), `FakeFlipper`, `ScriptedGate`, `ScriptedLLM` and
  `StubURLProtocol` (AgentKit); no network, no device.
- Do not commit `Config/Local.xcconfig` or anything with a team id, key or personal bundle id.
