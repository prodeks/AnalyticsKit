# AnalyticsKit

Swift package (iOS 16+, swift-tools 5.9) that gives the aweb apps one entry point for analytics, purchases, paywalls and remote config. The package also ships as a binary `AnalyticsKit.xcframework`.

## Layout

- `Sources/AnalyticsKit/PurchasesAndAnalytics.swift` - the public facade (`PurchasesAndAnalytics.shared`). It wires the services and runs the cold-start sequence. Read its doc comment first.
- `Analytics/` - `AnalyticsService` (fan-out to Firebase, Facebook, AppsFlyer, Mixpanel, Adjust) and `AdjustInstallGate`.
- `Analytics/Events/` - event types. Each event conforms to `EventProtocol` (`name`, `params`).
- `Purchases/` - `PurchaseService`, the Adapty and StoreKit paths, subscription status.
- `Paywalls/` - `AdaptyPaywallService` and the paywall UI (`PaywallController`, `WebViewController`).
- `RemoteConfig.swift`, `Keys.swift`, `Log.swift`, `Strings.swift`, `Extensions.swift` - shared support code.
- `Scripts/build-xcframework.sh` - builds the xcframework.
- `ANALYTICS_EVENTS.md` (Russian) - event list for the analytics team.
- `paywall_events_mapping_note.md` - old-to-new event name mapping from version 2.0.7.

There is no test target.

## Build

Build the package:

```bash
swift build
```

Build the xcframework and print the SPM checksum:

```bash
Scripts/build-xcframework.sh
```

The script checks the exact toolchain: Xcode 26.6 (build 17F109) and Swift 6.3.3. It sets `DEVELOPER_DIR` to `/Applications/Xcode-26.6.0-Release.Candidate.app` by default. The script fails on any other version. It also strips foreign objects from the static library, so do not remove that step.

## Rules for events

- Every event goes to all backends through `AnalyticsService.log(e:)`.
- Keep `name` stable. A name change breaks the historical dashboards.
- Keep names at 40 characters or fewer (Firebase limit).
- Use snake_case parameter keys. Use only `String`, `Int`, `Double`, `Float` and `Bool` values. Do not nest objects.
- Do not put the purchase engine in the event name. Since 2.0.7 the events use the `purchase_service` parameter (`adapty` or `storekit`) and not the `adapty_` or `storekit_` prefixes.
- Paywall events share `presentation_id`. Purchase result events carry `placement_id`, `paywall_id`, `variation_id` and `presentation_id`.
- When you add, rename or change an event, update `ANALYTICS_EVENTS.md`. If you rename an event, update `paywall_events_mapping_note.md` too.

## Conventions

- Dependencies in `Package.swift` use exact versions. Keep that style when you add or bump one.
- Public API is the contract with the host apps. Do not change a `public` signature without a reason. Keep internal types `internal`.
- Each host app sets `Keys.mixPanelRegion` to the data residency of its Mixpanel project. The default is `.eu`. A token sent to the wrong region gets HTTP 200 and the events are dropped.
- Use `Task.sleep` for timeouts in async code (see `AdjustInstallGate`). Inject the clock, token provider and HTTP client so the code stays testable.
- Commit messages are short, in the imperative, and have no prefix (for example "Add placement to all sale_confirmation events").
- Do not commit `.build/`, `build/`, `xcuserdata/` or `.netrc`. They are in `.gitignore`.

## Migrated settings

The old Cursor project file `.cursor/settings.json` was empty (`{}`), so it had nothing to migrate. The project has no Cursor rules, `AGENTS.md` or other AI rule files. The Cursor global rules in `~/.cursor/rules` (`argent.md`, `pstack-models.mdc`) are user-level settings. They do not belong in this repository.
