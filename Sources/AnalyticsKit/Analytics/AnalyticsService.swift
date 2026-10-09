import Foundation
import FirebaseAnalytics
import FirebaseCore
import AppTrackingTransparency
import FacebookCore
import AdServices
import FirebaseAuth
import AdSupport
import UserNotifications
import Adapty
import FirebaseMessaging
import Combine
import AppsFlyerLib
import PurchaseConnector
import Mixpanel
import FirebaseFirestore
import AdjustSdk
import StoreKit
import Sentry

// MARK: - Protocol

/// The public interface for the analytics and attribution layer.
///
/// Conforming types are responsible for:
/// - Initialising third-party SDKs (Firebase, Facebook, AppsFlyer, Adjust, Mixpanel,
///   Adapty, Firebase Messaging) exactly once.
/// - Forwarding `UIApplicationDelegate` lifecycle calls so each SDK can maintain its
///   own session state.
/// - Logging structured `EventProtocol` events to all active backends simultaneously.
/// - Surfacing a reactive `userID` stream so other services can stay in sync with the
///   Firebase anonymous auth UID.
/// - Exposing the latest `attributionData` from whichever attribution source resolved
///   most recently (Adjust, AppsFlyer, ASA, or deep link).
public protocol AnalyticsServiceProtocol: AnyObject {

    // MARK: App lifecycle

    /// Configures all third-party analytics SDKs the first time it is called;
    /// subsequent calls are no-ops for SDK setup but still invoke `analyticsStarted`.
    ///
    /// Call this from `application(_:didFinishLaunchingWithOptions:)` or as early as
    /// possible in the app lifecycle so attribution tokens are captured before the
    /// first session event fires.
    func setupAnalyticsIfNeeded(options: [UIApplication.LaunchOptionsKey: Any]?)

    /// Convenience wrapper: forwards `didFinishLaunchingWithOptions` to the Facebook
    /// SDK and then calls ``setupAnalyticsIfNeeded(options:)``.
    func didFinishLaunchingWithOptions(application: UIApplication, options: [UIApplication.LaunchOptionsKey: Any]?)

    /// Notifies AppsFlyer and starts the `PurchaseConnector` transaction observer.
    ///
    /// Must be called from `applicationDidBecomeActive(_:)` on every foreground
    /// transition so AppsFlyer sessions are correctly attributed.
    func applicationDidBecomeActive(_ application: UIApplication)

    /// Forwards URL-scheme deep links to Adjust and the Facebook SDK.
    ///
    /// - Returns: `true` if the Facebook SDK handled the URL.
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) -> Bool

    /// Forwards Universal Links to Adjust for deferred deep-link attribution.
    ///
    /// - Returns: `true` (always — the app is responsible for acting on the URL).
    func application(_application: UIApplication, continue userActivity: NSUserActivity) -> Bool

    /// Forwards a remote notification payload to Firebase Messaging.
    func application(_application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) -> Void

    /// Passes the APNS device token to Firebase Messaging for FCM bridging.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data)

    // MARK: Notifications

    /// Requests `.alert`, `.badge`, and `.sound` authorisation and registers the
    /// device for remote notifications.
    func registerForNotifications()

    // MARK: Events

    /// Logs `e` to all active analytics backends simultaneously.
    ///
    /// Backends: Firebase Analytics, Facebook App Events, AppsFlyer, Mixpanel.
    /// Additionally logs a Facebook purchase revenue event for `PurchaseEvent.success`.
    func log(e: EventProtocol)

    /// Sets user-profile properties on Mixpanel People, Firebase Analytics, and Adapty.
    ///
    /// Mixpanel and Adapty keep native types (`Bool`, numeric); Firebase user properties
    /// are always strings. Use this for current-state values that Insights cannot
    /// dedupe from events (e.g. `current_bmi_state`).
    func setUserProperties(_ properties: [String: Any])

    /// Registers bundled Adapty paywall JSON used when placements cannot be fetched.
    ///
    /// Call once at launch with the app's `paywallFallback.json` URL, before paywalls
    /// are requested. Adapty serves this file when the network is unavailable.
    func setPaywallFallback(fileURL: URL)

    /// The assigned Mixpanel feature-flag variant key, or `nil` when the SDK has no assignment.
    ///
    /// `nil` covers a missing flag, a user outside the rollout, and a fetch that failed.
    /// A returned key is a real assignment. Reading it is what makes the Mixpanel SDK send
    /// `$experiment_started` for an experiment-backed flag. That event does not go through
    /// ``log(e:)``.
    func experimentVariant(for flagKey: String) async -> String?

    // MARK: Tracking

    /// Presents the ATT permission dialog and propagates the result to Adapty.
    ///
    /// - Returns: The `ATTrackingManager.AuthorizationStatus` selected by the user.
    func reqeuestATT() async -> ATTrackingManager.AuthorizationStatus

    /// Updates Adapty's refund data consent flag.
    ///
    /// - Parameter granted: `true` to allow Adapty to collect refund data for
    ///   revenue recovery features.
    func updateRefundDataConsent(granted: Bool) async

    // MARK: Publishers

    /// Publishes the Firebase anonymous auth UID, starting with an empty string before
    /// sign-in completes.
    var userID: AnyPublisher<String, Never> { get }

    /// Mutable backing store for the Firebase UID. Exposed so the owning coordinator
    /// can read the current value synchronously without subscribing to the publisher.
    var _userID: String { get set }

    /// Publishes the most recently received attribution dictionary.
    ///
    /// Sources (in priority order, last-write wins):
    /// 1. AppsFlyer conversion data
    /// 2. Adjust attribution callback
    /// 3. Adjust deferred deep link
    /// 4. URL-scheme / Universal Link deep link
    var attributionData: AnyPublisher<[AnyHashable: Any], Never> { get }

    // MARK: Push

    /// The most recently received Firebase Cloud Messaging token, or `nil` if FCM
    /// registration has not completed yet.
    var fcmToken: String? { get }
}

// MARK: - Implementation

/// Central analytics hub that initialises, configures, and proxies to all third-party
/// analytics and attribution SDKs.
///
/// ## SDK responsibilities
///
/// | SDK | Role |
/// |---|---|
/// | Firebase Analytics | Event logging and user identification |
/// | Firebase Auth | Anonymous sign-in to obtain a stable user ID |
/// | Firebase Messaging | FCM push token management |
/// | Facebook SDK | Event logging and purchase revenue reporting |
/// | AppsFlyer | Install attribution and event logging |
/// | Adjust | Install attribution, SKAN conversion, deep links |
/// | Mixpanel | Event logging with EU data residency |
/// | Adapty | Subscription paywall config and entitlement management |
///
/// ## Initialisation sequence
///
/// 1. `setupAnalyticsIfNeeded(options:)` — one-time SDK configuration.
/// 2. `applyCachedIdentity()` → `activateAdapty(customerUserID:)` → `reconcileIdentity(…)` —
///    activates Adapty under the cached Firebase identity (or anonymously on a first launch),
///    then resolves the final identity and registers cross-SDK identifiers. Run in this order;
///    see ``PurchasesAndAnalytics`` for the startup sequence.
/// 3. `initAdjust()` — starts the Adjust SDK and forwards the Adjust device ID and
///    attribution to Adapty.
/// 4. `applicationDidBecomeActive(_:)` — starts the AppsFlyer session.
///.
class AnalyticsService: NSObject, AnalyticsServiceProtocol {
    enum UserIdentitySource {
        case firebase
        case fallback
    }

    struct ResolvedUserIdentity {
        let userID: String
        let source: UserIdentitySource
    }

    // MARK: - Private SDK references

    private let firebase = Analytics.self
    private let adapty = Adapty.self
    private let appsflyer = AppsFlyerLib.shared()
    private let purchaseConnector = PurchaseConnector.shared()

    // MARK: - Public properties

    var fcmToken: String? = ""

    /// Set to `true` before `setupAnalyticsIfNeeded` is called when the app detects
    /// the user is running in the Chinese App Store.
    var isRunningInChina: Bool = false

    /// Post-identity Adapty setup (refund consent, cross-SDK identifiers). Retained so the
    /// work is cancellable and observable rather than being fire-and-forget.
    private var adaptyIntegrationSetup: Task<Void, Never>?

    @Published public var _userID = ""
    public var userID: AnyPublisher<String, Never> {
        $_userID.eraseToAnyPublisher()
    }

    @Published private var _attributionData = [AnyHashable: Any]()
    public var attributionData: AnyPublisher<[AnyHashable: Any], Never> {
        $_attributionData.eraseToAnyPublisher()
    }

    /// Optional hook invoked at the end of ``setupAnalyticsIfNeeded(options:)`` on
    /// every call (including subsequent no-op calls).
    ///
    /// Allows the host app to perform work that depends on the analytics layer being
    /// ready (e.g. activating Adapty) without subclassing `AnalyticsService`.
    public var analyticsStarted: (([UIApplication.LaunchOptionsKey: Any]?) -> Void)?

    /// Guards against running the SDK setup block more than once.
    private var didSetupAnalytics = false
    
    private var didSetupMixPanel = false
    private let fallbackCustomerUserIDKey = "com.aweb.analytics.fallback_customer_user_id"

    // MARK: - App lifecycle

    public func setupAnalyticsIfNeeded(options: [UIApplication.LaunchOptionsKey: Any]?) {
        if !didSetupAnalytics {
            // Facebook SDK — must be configured before any AppEvents calls
            Settings.shared.appID = PurchasesAndAnalytics.Keys.facebookAppId
            Settings.shared.clientToken = PurchasesAndAnalytics.Keys.facebookClientToken
            Settings.shared.isAutoLogAppEventsEnabled = true
            Settings.shared.isAdvertiserIDCollectionEnabled = true

            // AppsFlyer — `waitForATTUserAuthorization` defers the install ping until
            // the ATT prompt result is known, maximising attributed installs.
            appsflyer.appsFlyerDevKey = PurchasesAndAnalytics.Keys.appsflyerKey ?? ""
            appsflyer.appleAppID = PurchasesAndAnalytics.Keys.appID ?? ""
            appsflyer.delegate = self
            appsflyer.deepLinkDelegate = self
            appsflyer.isDebug = true
            appsflyer.waitForATTUserAuthorization(timeoutInterval: 60)
            purchaseConnector.purchaseRevenueDelegate = self
            purchaseConnector.purchaseRevenueDataSource = self
            purchaseConnector.autoLogPurchaseRevenue = .autoRenewableSubscriptions

            FirebaseApp.configure()

            // Mixpanel — EU endpoint used for GDPR compliance.
            setupMixPanelIfNeeded()
            Messaging.messaging().delegate = self
            didSetupAnalytics = true
        }

        analyticsStarted?(options)
    }

    public func didFinishLaunchingWithOptions(
        application: UIApplication,
        options: [UIApplication.LaunchOptionsKey: Any]?
    ) {
        
        SentrySDK.start { options in
            options.dsn = PurchasesAndAnalytics.Keys.sentryDSN
            options.releaseName = PurchasesAndAnalytics.Keys.sentryReleseName
            // Adds IP for users.
             // For more information, visit: https://docs.sentry.io/platforms/apple/data-management/data-collected/
             options.sendDefaultPii = true
             // Set tracesSampleRate to 1 to capture 100% of transactions for performance monitoring.
             // We recommend adjusting this value in production.
             options.tracesSampleRate = 1
             options.configureProfiling = {
                 $0.lifecycle = .trace
                 $0.sessionSampleRate = 1
             }
             // Record session replays for 100% of errors and 10% of sessions
             options.sessionReplay.onErrorSampleRate = 1.0
             options.sessionReplay.sessionSampleRate = 0.1
#if DEBUG
            options.environment = "debug"
//            options.debug = true
#else
            options.environment = "production"
#endif
        }
        
        ApplicationDelegate.shared.application(
            application,
            didFinishLaunchingWithOptions: options
        )

        setupAnalyticsIfNeeded(options: options)
    }

    // MARK: - Firebase sign-in & Adapty activation

    fileprivate func mixPanelIdentifyUser(_ userID: String) {
        Mixpanel.mainInstance().identify(distinctId: userID)
        Mixpanel.mainInstance().people.set(property: "firebase_uid", to: userID)
    }
    
    fileprivate func setupMixPanelIfNeeded() {
        if !didSetupMixPanel {
            // prefetchFlags is false so the first fetch happens after identify(), under the
            // Firebase uid the experiment assigns on. Persistence covers the next launch if
            // that fetch is still in flight when onboarding asks for a variant.
            Mixpanel.initialize(
                options: MixpanelOptions(
                    token: PurchasesAndAnalytics.Keys.mixPanelToken ?? "",
                    trackAutomaticEvents: false,
                    serverURL: "https://api-eu.mixpanel.com",
                    featureFlagOptions: FeatureFlagOptions(
                        enabled: true,
                        prefetchFlags: false,
                        variantLookupPolicy: .persistenceUntilNetworkSuccess()
                    )
                )
            )
            Mixpanel.mainInstance().loggingEnabled = true
            didSetupMixPanel = true
        }
    }

    /// Waits for the in-flight Mixpanel flag fetch, but no longer than `timeout`.
    ///
    /// `identify` already starts a fetch when the distinct id changes. This joins that fetch
    /// (or starts one) so onboarding can read a variant before the splash ends. A timeout
    /// returns without a variant. The caller then treats the user as unassigned.
    func awaitFeatureFlags(timeout: TimeInterval) async {
        setupMixPanelIfNeeded()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Mixpanel.mainInstance().flags.loadFlags { _ in
                        continuation.resume()
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    public func experimentVariant(for flagKey: String) async -> String? {
        setupMixPanelIfNeeded()
        let fallback = MixpanelFlagVariant(key: "")
        let variant = await withCheckedContinuation { continuation in
            Mixpanel.mainInstance().flags.getVariant(flagKey, fallback: fallback) { variant in
                continuation.resume(returning: variant)
            }
        }
        if case .fallback = variant.source {
            return nil
        }
        return variant.key.isEmpty ? nil : variant.key
    }
    
    // MARK: - Startup identity
    //
    // Run in this order, driven by `PurchasesAndAnalytics`, before any paywall is fetched:
    //
    //   applyCachedIdentity() → activateAdapty(customerUserID:) → reconcileIdentity(…)
    //
    // No step throws: a failing SDK degrades the launch instead of blocking it, and every
    // failure surfaces as a log line plus an `AnalyticsSetupFailedEvent`.

    /// Runs one startup step, turning a thrown error into a log line and an
    /// ``AnalyticsSetupFailedEvent``, and reporting whether it succeeded.
    ///
    /// - Parameter operation: Analytics identifier for the step. Dashboards group on this
    ///   value, so existing names must stay stable.
    @discardableResult
    private func runSetupStep(
        _ operation: String,
        _ work: () async throws -> Void
    ) async -> Bool {
        do {
            try await work()
            Log.printLog(l: .debug, str: "Setup step \(operation) succeeded")
            return true
        } catch {
            Log.printLog(l: .error, str: "Setup step \(operation) failed: \(error.localizedDescription)")
            log(e: AnalyticsSetupFailedEvent(operation: operation, error: error))
            return false
        }
    }

    /// Pushes the cached Firebase identity to Firebase, Sentry, Mixpanel, and AppsFlyer.
    ///
    /// Reads local state only, so it never blocks on the network. Returns `nil` on a first
    /// launch, before any anonymous credential has been persisted; pass that result straight
    /// on to ``activateAdapty(customerUserID:)``.
    func applyCachedIdentity() async -> ResolvedUserIdentity? {
        guard let identity = cachedFirebaseIdentity() else {
            Log.printLog(l: .debug, str: "Identity: no cached Firebase user")
            return nil
        }

        Log.printLog(l: .debug, str: "Identity: cached Firebase user \(identity.userID)")
        await applyUserIdentity(identity)
        return identity
    }

    /// Activates Adapty, reporting whether Adapty is usable this session.
    ///
    /// Pass `nil` when no Firebase credential is cached, so Adapty activates **anonymously**
    /// instead of under the fallback ID. `Adapty.identify` merges an anonymous profile in
    /// place, while re-identifying an already-named profile discards the local profile state —
    /// the anonymous path is what keeps one profile per install.
    func activateAdapty(customerUserID: String?) async -> Bool {
        Adapty.setLogHandler { record in
            Log.printLog(l: .init(record.level), str: "[Adapty]" + record.message)
        }

        guard let key = PurchasesAndAnalytics.Keys.subscriptionServiceKey else {
            Log.printLog(l: .error, str: "Adapty activation skipped: subscriptionServiceKey is missing")
            return false
        }

        let configuration = AdaptyConfiguration
            .builder(withAPIKey: key)
            .with(logLevel: .verbose)
            .with(customerUserId: customerUserID)
            .with(serverCluster: adaptyServerClusterForCurrentUser())
            .with(ipAddressCollectionDisabled: isRunningInChina)
            .build()

        return await runSetupStep("adapty_activate") {
            try await adapty.activate(with: configuration)
        }
    }

    /// Resolves the final user identity and propagates it to every SDK.
    ///
    /// Signs in to Firebase anonymously when no credential was cached. If that produces a
    /// different user than Adapty was activated with, the Adapty profile is switched to match.
    /// A persisted local ID is used only when Firebase auth fails outright.
    ///
    /// Runs even when `isAdaptyActivated` is `false`, so Firebase Analytics, Sentry, Mixpanel,
    /// and AppsFlyer still receive a user ID when the purchases SDK is unavailable.
    ///
    /// - Important: Await this before fetching paywalls. `Adapty.identify` cancels Adapty's
    ///   in-flight profile creation, which fails concurrent placement fetches with
    ///   `profileWasChanged`.
    func reconcileIdentity(
        activatedIdentity: ResolvedUserIdentity?,
        isAdaptyActivated: Bool
    ) async {
        let identity = await resolveFirebaseIdentity()
            ?? activatedIdentity
            ?? .init(userID: fallbackCustomerUserID(), source: .fallback)

        if identity.userID == activatedIdentity?.userID {
            Log.printLog(l: .debug, str: "Identity: unchanged (\(identity.userID))")
        } else {
            Log.printLog(l: .debug, str: "Identity: switching to \(identity.userID) [\(identity.source)]")

            if isAdaptyActivated {
                await runSetupStep("adapty_identify") {
                    try await adapty.identify(identity.userID)
                }
            }
            await applyUserIdentity(identity)
        }

        guard isAdaptyActivated else { return }

        // Nothing else waits on these, so they stay off the paywall prefetch's critical path.
        adaptyIntegrationSetup = Task { await self.setUpAdaptyIntegrations() }
    }

    /// Adapty configuration that depends on the final identity but that no other startup step
    /// waits for: refund data consent and the cross-SDK integration identifiers.
    private func setUpAdaptyIntegrations() async {
        await runSetupStep("adapty_refund_consent") {
            try await adapty.updateCollectingRefundDataConsent(true)
        }

        // Lets Adapty join events from Firebase, Mixpanel, and Facebook in its pipelines.
        var identifiers = [
            (operation: "adapty_mixpanel_integration_id", key: "mixpanel_user_id", value: Mixpanel.mainInstance().distinctId),
            (operation: "adapty_facebook_integration_id", key: "facebook_anonymous_id", value: AppEvents.shared.anonymousID),
        ]
        if let appInstanceID = Analytics.appInstanceID() {
            identifiers.append(
                (operation: "adapty_firebase_integration_id", key: "firebase_app_instance_id", value: appInstanceID)
            )
        }

        for identifier in identifiers {
            await runSetupStep(identifier.operation) {
                try await Adapty.setIntegrationIdentifier(key: identifier.key, value: identifier.value)
            }
        }
    }

    /// Returns the cached Firebase identity without touching the network, or `nil` on a
    /// first launch when no anonymous credential has been persisted yet.
    private func cachedFirebaseIdentity() -> ResolvedUserIdentity? {
        Auth.auth().currentUser.map { .init(userID: $0.uid, source: .firebase) }
    }

    /// Returns the Firebase identity, signing in anonymously when nothing is cached, or `nil`
    /// when Firebase auth is unreachable.
    ///
    /// The cached branch costs nothing, so this is only slow on a genuine first launch.
    private func resolveFirebaseIdentity() async -> ResolvedUserIdentity? {
        if let cached = cachedFirebaseIdentity() { return cached }

        do {
            let signInResult = try await Auth.auth().signInAnonymously()
            return .init(userID: signInResult.user.uid, source: .firebase)
        } catch {
            Log.printLog(l: .error, str: "Firebase auth failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns a locally generated ID, stable across launches, used only when Firebase auth
    /// fails. Adapty cannot merge this profile into a later Firebase one, so avoid it unless
    /// there is no alternative.
    private func fallbackCustomerUserID() -> String {
        let defaults = UserDefaults.standard

        if let existingID = defaults.string(forKey: fallbackCustomerUserIDKey),
           !existingID.isEmpty {
            return existingID
        }

        let generatedID = "fallback_" + UUID().uuidString.lowercased()
        defaults.set(generatedID, forKey: fallbackCustomerUserIDKey)
        return generatedID
    }

    /// Applies the identity to every SDK except Adapty, which is identified at activation.
    ///
    /// Main-actor isolated because it publishes `_userID` to UI subscribers. Firebase's own
    /// user ID is set only for a real Firebase identity, never for the local fallback.
    @MainActor
    private func applyUserIdentity(_ identity: ResolvedUserIdentity) {
        if identity.source == .firebase {
            firebase.setUserID(identity.userID)
        }

        _userID = identity.userID
        appsflyer.customerUserID = identity.userID
        SentrySDK.setUser(.init(userId: identity.userID))
        mixPanelIdentifyUser(identity.userID)
    }

    // MARK: - Adjust initialisation

    /// Initialises the Adjust SDK with environment-appropriate settings and forwards
    /// the resolved attribution and device ID to Adapty.
    ///
    /// Debug builds use `ADJEnvironmentSandbox` with verbose logging; release builds
    /// use `ADJEnvironmentProduction` with logging suppressed. After `initSdk` returns,
    /// the device's Adjust ID and existing attribution are fetched asynchronously and
    /// reported to Adapty and the attribution webhook.
    func initAdjust() {

#if DEBUG
        let environment = ADJEnvironmentSandbox
        let adjustConfig = ADJConfig(
            appToken: PurchasesAndAnalytics.Keys.adjustKey ?? "",
            environment: environment)
        adjustConfig?.logLevel = ADJLogLevel.verbose
        adjustConfig?.delegate = self
#else
        let environment = ADJEnvironmentProduction
        let adjustConfig = ADJConfig(
            appToken: PurchasesAndAnalytics.Keys.adjustKey ?? "",
            environment: environment)
        adjustConfig?.logLevel = ADJLogLevel.suppress
        adjustConfig?.delegate = self
#endif

        Adjust.initSdk(adjustConfig)

        Task {
            let (adid, attribution) = await (Adjust.adid(), Adjust.attribution()?.dictionary())
            do {
                if let adid {
                    try await Adapty.setIntegrationIdentifier(key: "adjust_device_id", value: adid)
                }
                if let attribution {
                    try await Adapty.updateAttribution(attribution, source: "adjust")
                    _attributionData = attribution
                }

                let firebaseAppInstanceId = Analytics.appInstanceID() ?? ""
                await sendAttributionWebhook(
                    storeId: PurchasesAndAnalytics.Keys.appID ?? "",
                    firebaseAppInstanceId: firebaseAppInstanceId,
                    adjustDeviceId: adid ?? "",
                    source: "adjust",
                    attribution: attribution ?? [:]
                )
            } catch {
                Log.printLog(l: .error, str: error.localizedDescription)
            }
        }
    }

    // MARK: - Attribution webhook

    /// POSTs a combined attribution snapshot to the internal attribution aggregation
    /// service so that install-level data from multiple sources is centralised.
    ///
    /// The payload joins the App Store product ID, Firebase instance ID, Adjust device
    /// ID, and the raw attribution dictionary. Failures are logged but do not affect
    /// the user experience.
    private func sendAttributionWebhook(
        storeId: String,
        firebaseAppInstanceId: String,
        adjustDeviceId: String,
        source: String,
        attribution: [AnyHashable: Any]
    ) async {
        let webhookURL = "https://adapty-attributions-420095526567.europe-west1.run.app/webhook"
        let authToken = "1dac2f40da774e43344f88eaee0ad566742d73f803f0a88d42626b803d55b085"

        guard let url = URL(string: webhookURL) else {
            Log.printLog(l: .error, str: "Invalid webhook URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "store_id": storeId,
            "firebase_app_instance_id": firebaseAppInstanceId,
            "adjust_device_id": adjustDeviceId,
            "source": source,
            "attribution": attribution
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    Log.printLog(l: .debug, str: "Attribution webhook sent successfully")
                } else {
                    Log.printLog(l: .error, str: "Attribution webhook failed with status code: \(httpResponse.statusCode)")
                }
            }
        } catch {
            Log.printLog(l: .error, str: "Failed to send attribution webhook: \(error.localizedDescription)")
        }
    }

    // MARK: - Notifications

    public func registerForNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { (_, _) in
            // handle if needed
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - URL / deep-link handling

    public func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any]
    ) -> Bool {
        // Forward to Adjust for URL-scheme attribution tracking
        if let adjustDeeplink = ADJDeeplink(deeplink: url) {
            Adjust.processDeeplink(adjustDeeplink)
        }
        Log.printLog(l: .debug, str: "Adjust URL scheme deep link processed: \(url.absoluteString)")

        // Store the raw URL so the app coordinator can route the deep link
        _attributionData = [PurchasesAndAnalytics.Keys.adjustDeeplinkKey: url.absoluteString]

        return ApplicationDelegate.shared.application(
            app,
            open: url,
            sourceApplication: options[UIApplication.OpenURLOptionsKey.sourceApplication] as? String,
            annotation: options[UIApplication.OpenURLOptionsKey.annotation]
        )
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    public func applicationDidBecomeActive(_ application: UIApplication) {
        appsflyer.start()
        purchaseConnector.startObservingTransactions()
    }

    // MARK: - ATT

    /// Presents the system ATT authorisation dialog and propagates the result to
    /// Adapty so paywall personalisation can respect the user's tracking preference.
    ///
    /// IDFA, IDFV, and the ASA attribution token are logged at `.debug` level for
    /// diagnostics but are not stored or forwarded beyond what the SDKs handle
    /// internally.
    public func reqeuestATT() async -> ATTrackingManager.AuthorizationStatus {
        return await withCheckedContinuation { c in
            ATTrackingManager.requestTrackingAuthorization { status in
                DispatchQueue.global(qos: .default).async {
                    let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                    Log.printLog(l: .debug, str: "IDFA: \(idfa)")
                    let idfv = UIDevice.current.identifierForVendor?.uuidString ?? ""
                    Log.printLog(l: .debug, str: "IDFV: \(idfv)")
                    do {
                        let token = try AAAttribution.attributionToken()
                        Log.printLog(l: .debug, str: "AttributionToken: \(token)")
                    } catch {
                        Log.printLog(l: .error, str: "ASA attribution token failed: \(error.localizedDescription)")
                    }
                }
                let builder = AdaptyProfileParameters.Builder().with(appTrackingTransparencyStatus: status)
                Task {
                    do {
                        try await Adapty.updateProfile(params: builder.build())
                    } catch {
                        Log.printLog(l: .error, str: error.localizedDescription)
                    }
                    c.resume(returning: status)
                }
            }
        }
    }

    // MARK: - Universal Links

    public func application(
        _application: UIApplication,
        continue userActivity: NSUserActivity
    ) -> Bool {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {

            if let adjustDeeplink = ADJDeeplink(deeplink: url) {
                Adjust.processDeeplink(adjustDeeplink)
                Log.printLog(l: .debug, str: "Adjust Universal Link processed: \(url.absoluteString)")

                _attributionData = [PurchasesAndAnalytics.Keys.adjustDeeplinkKey: url.absoluteString]
            }
        }
        return true
    }

    // MARK: - Remote notifications

    public func application(
        _application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) {
        Messaging.messaging().appDidReceiveMessage(userInfo)
    }

    // MARK: - Event logging

    /// Fans out the event to every active analytics backend.
    ///
    /// - Firebase Analytics: `logEvent(_:parameters:)` with the raw param dictionary.
    /// - Facebook App Events: params are re-keyed as `AppEvents.ParameterName`; for
    ///   `PurchaseEvent.success` an additional `logPurchase(amount:currency:)` call is
    ///   made so Facebook can model purchase revenue.
    /// - AppsFlyer: `logEvent(_:withValues:)`.
    /// - Mixpanel: values are converted to `MixpanelType` while preserving `Int` /
    ///   `Double` / `Bool` so Insights Average/Median/Percentile work. Unknown types
    ///   fall back to `String(describing:)`.
    public func log(e: EventProtocol) {
        setupMixPanelIfNeeded()
        Log.printLog(l: .analytics, str: e.name + " \(e.params)")

        firebase.logEvent(e.name, parameters: e.params)

        var fbParams: [AppEvents.ParameterName: Any] = [:]
        e.params.forEach { k, v in
            fbParams[AppEvents.ParameterName.init(k)] = v
        }

        AppEvents.shared.logEvent(AppEvents.Name(e.name), parameters: fbParams)

        if let purchaseEvent = e as? PurchaseEvent,
            case let .success(context) = purchaseEvent {
            AppEvents.shared.logPurchase(
                amount: Double(context.price),
                currency: context.currency
            )
        }

        appsflyer.logEvent(e.name, withValues: e.params)

        Mixpanel.mainInstance().track(event: e.name, properties: mixpanelProperties(from: e.params))
    }

    // MARK: - User properties

    public func setUserProperties(_ properties: [String: Any]) {
        guard !properties.isEmpty else { return }

        setupMixPanelIfNeeded()

        Mixpanel.mainInstance().people.set(properties: mixpanelProperties(from: properties))

        for (name, value) in properties {
            firebase.setUserProperty(firebaseUserPropertyValue(from: value), forName: name)
        }

        Task {
            do {
                var builder = AdaptyProfileParameters.Builder()
                for (key, value) in properties {
                    builder = try adaptyCustomAttribute(builder, key: key, value: value)
                }
                try await Adapty.updateProfile(params: builder.build())
            } catch {
                Log.printLog(
                    l: .error,
                    str: "Failed to update Adapty profile properties: \(error.localizedDescription)"
                )
                SentrySDK.capture(error: error)
            }
        }
    }

    public func setPaywallFallback(fileURL: URL) {
        Adapty.setFallback(fileURL: fileURL)
    }

    // MARK: - Consent

    public func updateRefundDataConsent(granted: Bool) async {
        do {
            try await adapty.updateCollectingRefundDataConsent(granted)
            Log.printLog(l: .debug, str: "Updated Adapty refund data consent to \(granted)")
        } catch {
            Log.printLog(l: .error, str: "Failed to update Adapty refund data consent: \(error.localizedDescription)")
        }
    }

    // MARK: - Private helpers

    /// Returns the Adapty server cluster appropriate for the current user.
    ///
    /// Chooses `.cn` when `isRunningInChina` is `true`, per the
    /// [Adapty China cluster docs](https://adapty.io/docs/china-cluster?current-os=swift).
    private func adaptyServerClusterForCurrentUser() -> AdaptyServerCluster {
        return isRunningInChina ? .cn : .default
    }

    /// Converts event params to Mixpanel properties without stringifying numbers.
    /// Mixpanel locks a property's type on first ingest; sending `height_cm` as
    /// `"180"` would make Average/Median return empty forever.
    private func mixpanelProperties(from params: [String: Any]) -> [String: MixpanelType] {
        Dictionary(uniqueKeysWithValues: params.map { key, value in
            (key, mixpanelValue(from: value))
        })
    }

    private func mixpanelValue(from value: Any) -> MixpanelType {
        switch value {
        case let v as String: return v
        case let v as Bool: return v
        case let v as Int: return v
        case let v as UInt: return v
        case let v as Double: return v
        case let v as Float: return v
        case let v as Date: return v
        case let v as URL: return v
        case let v as NSNumber: return v
        case let v as [String]: return v
        default: return String(describing: value)
        }
    }

    private func firebaseUserPropertyValue(from value: Any) -> String {
        switch value {
        case let v as String:
            return v
        case let v as Double:
            return String(format: "%g", v)
        case let v as Float:
            return String(format: "%g", v)
        case let v as Bool:
            return v ? "true" : "false"
        default:
            return String(describing: value)
        }
    }

    private func adaptyCustomAttribute(
        _ builder: AdaptyProfileParameters.Builder,
        key: String,
        value: Any
    ) throws -> AdaptyProfileParameters.Builder {
        switch value {
        case let v as String:
            return try builder.with(customAttribute: v, forKey: key)
        case let v as Double:
            return try builder.with(customAttribute: v, forKey: key)
        case let v as Float:
            return try builder.with(customAttribute: Double(v), forKey: key)
        case let v as Int:
            return try builder.with(customAttribute: Double(v), forKey: key)
        case let v as Bool:
            return try builder.with(customAttribute: v ? "true" : "false", forKey: key)
        default:
            return try builder.with(customAttribute: String(describing: value), forKey: key)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AnalyticsService: UNUserNotificationCenterDelegate {

    /// Calls the completion handler immediately; notification response handling is
    /// delegated to the host app.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            completionHandler()
        }
    }

    /// Presents the notification as a banner, badge, and sound while the app is in
    /// the foreground. Also logs the notification's `userInfo` for diagnostics.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            let userInfo = notification.request.content.userInfo
            Log.printLog(l: .debug, str: "Will present notification, userInfo \n\(userInfo)")
            completionHandler([.banner, .badge, .sound])
        }
    }
}

// MARK: - MessagingDelegate

extension AnalyticsService: MessagingDelegate {

    /// Stores the newly issued FCM registration token so the host app can subscribe
    /// the device to push topics or upload it to the server.
    public func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let fcmToken {
            Log.printLog(l: .debug, str: "Did receive FCM token - \(fcmToken)")
            self.fcmToken = fcmToken
        }
    }
}

// MARK: - AppsFlyerLibDelegate, DeepLinkDelegate, PurchaseRevenueDelegate, PurchaseRevenueDataSource

extension AnalyticsService: AppsFlyerLibDelegate, DeepLinkDelegate, PurchaseRevenueDelegate, PurchaseRevenueDataSource {

    /// Called when AppsFlyer resolves install attribution data.
    ///
    /// The conversion info is published via `attributionData` and also forwarded to
    /// Adapty so paywall personalisation can use campaign-level data.
    public func onConversionDataSuccess(_ conversionInfo: [AnyHashable: Any]) {
        _attributionData = conversionInfo

        let afUID = AppsFlyerLib.shared().getAppsFlyerUID()
        Task {
            do {
                try await Adapty.setIntegrationIdentifier(key: "appsflyer_id", value: afUID)
            } catch {
                Log.printLog(l: .error, str: "Adapty AppsFlyer integration id failed: \(error.localizedDescription)")
            }
            do {
                try await Adapty.updateAttribution(conversionInfo, source: "appsflyer")
            } catch {
                Log.printLog(l: .error, str: "Adapty AppsFlyer attribution update failed: \(error.localizedDescription)")
            }
        }
    }

    public func onConversionDataFail(_ error: any Error) {
        Log.printLog(l: .error, str: error.localizedDescription)
    }

    /// Called when AppsFlyer resolves a OneLink deep link.
    ///
    /// The `deeplinkValue` is published via `attributionData` so the app coordinator
    /// can navigate to the appropriate screen.
    public func didResolveDeepLink(_ result: DeepLinkResult) {
        if let deeplinkValue = result.deepLink?.deeplinkValue {
            _attributionData = ["deep_link_value": deeplinkValue]
        }
    }

    /// Logs the server-side revenue validation result for diagnostics; no action is
    /// taken on the validation outcome.
    public func didReceivePurchaseRevenueValidationInfo(
        _ validationInfo: [AnyHashable: Any]?,
        error: (any Error)?
    ) {
        if let validationInfo {
            Log.printLog(l: .debug, str: "Purchase revenue validation info: \(validationInfo)")
        }
        if let error {
            Log.printLog(l: .error, str: error.localizedDescription)
        }
    }

    /// Returns `nil` to indicate that no additional custom parameters should be
    /// attached to AppsFlyer purchase revenue events.
    public func purchaseRevenueAdditionalParameters(
        for products: Set<SKProduct>,
        transactions: Set<SKPaymentTransaction>?
    ) -> [AnyHashable: Any]? {
        return nil
    }
}

// MARK: - AdjustDelegate

extension AnalyticsService: AdjustDelegate {

    /// Called whenever Adjust's install attribution changes (e.g. after a deferred
    /// deep link resolves or an organic install is re-attributed).
    ///
    /// All non-nil attribution fields are packed into a flat dictionary and:
    /// 1. Published via `attributionData` for the app coordinator.
    /// 2. Forwarded to Adapty for paywall personalisation.
    public func adjustAttributionChanged(_ attribution: ADJAttribution?) {
        Log.printLog(l: .debug, str: "Adjust attribution changed: \(String(describing: attribution))")

        guard let attribution else { return }

        var attributionDict: [AnyHashable: Any] = [:]

        if let trackerToken = attribution.trackerToken { attributionDict["tracker_token"] = trackerToken }
        if let trackerName  = attribution.trackerName  { attributionDict["tracker_name"]  = trackerName  }
        if let network      = attribution.network      { attributionDict["network"]        = network      }
        if let campaign     = attribution.campaign     { attributionDict["campaign"]       = campaign     }
        if let adgroup      = attribution.adgroup      { attributionDict["adgroup"]        = adgroup      }
        if let creative     = attribution.creative     { attributionDict["creative"]       = creative     }
        if let clickLabel   = attribution.clickLabel   { attributionDict["click_label"]    = clickLabel   }
        if let costType     = attribution.costType     { attributionDict["cost_type"]      = costType     }
        if let costAmount   = attribution.costAmount   { attributionDict["cost_amount"]    = costAmount   }
        if let costCurrency = attribution.costCurrency { attributionDict["cost_currency"]  = costCurrency }

        _attributionData = attributionDict

        Task {
            do {
                try await Adapty.updateAttribution(attributionDict, source: "adjust")
            } catch {
                Log.printLog(l: .error, str: "Failed to update Adapty attribution: \(error.localizedDescription)")
            }
        }
    }

    /// Called when the SKAdNetwork conversion value is updated by Adjust.
    ///
    /// SKAN data is informational only; no further action is taken here.
    public func adjustSkanUpdated(withConversionData data: [String: String]) {
        Log.printLog(l: .debug, str: "Adjust SKAN updated: \(data)")
    }

    /// Called when Adjust resolves a deferred deep link after install.
    ///
    /// Returns `false` to prevent Adjust from opening the URL automatically — the app
    /// coordinator is responsible for routing based on the published `attributionData`.
    public func adjustDeferredDeeplinkReceived(_ deeplink: URL?) -> Bool {
        Log.printLog(l: .debug, str: "Adjust deferred deeplink received: \(String(describing: deeplink))")

        if let deeplink {
            _attributionData = [PurchasesAndAnalytics.Keys.adjustDeeplinkKey: deeplink.absoluteString]
        }
        return false
    }
}
