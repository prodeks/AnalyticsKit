import Foundation
import StoreKit
import Combine
import Adapty

/// Concrete implementation of `PurchaseServiceProtocol` that coordinates focused
/// purchase, restore, entitlement, and transaction collaborators.
///
/// ## Dual-backend entitlement strategy
///
/// The service supports two modes controlled by `usesStoreKitEntitlementsForAccess`:
///
/// - **Adapty mode** (default): Adapty is the source of truth. Transactions are
///   reported to Adapty and subscription state is derived from the Adapty profile.
///
/// - **StoreKit mode** (China region): StoreKit is the source of truth because Adapty
///   may be unreachable. The subscription state is computed directly from StoreKit
///   product status and current entitlements. Adapty is still notified in the
///   background so that server-side analytics remain accurate, but access decisions
///   do not depend on Adapty being reachable.
class PurchaseService: @preconcurrency PurchaseServiceProtocol {

    // MARK: - Public properties

    public var iaps: [any IAPProtocol] = []

    /// Analytics event hook. Set by the owning service to forward purchase-related
    /// events to the analytics pipeline without creating a hard dependency on it.
    var logEvent: ((EventProtocol) -> Void)?

    public var subscriptionStatus: SubscriptionStatus {
        get { statusStore.current }
        set { statusStore.current = newValue }
    }

    public var subscriptionStatusStream: AnyPublisher<SubscriptionStatus, Never> {
        statusStore.stream
    }

    // MARK: - Private properties

    private let statusStore = SubscriptionStatusStore()
    private let adaptyService = AdaptyPurchaseService()

    /// Adapty variation id from the most recent paywall purchase, used when reporting
    /// StoreKit transactions back to Adapty.
    private var pendingVariationId: String?

    // MARK: - Purchase

    public func purchaseAdaptyProduct(
        _ product: AdaptyPaywallProduct,
        paywallID: String,
        presentationID: String?,
        variationId: String?,
        _ completion: @escaping (PurchaseResult) -> Void
    ) {
        purchaseAdaptyProduct(
            product,
            paywallID: paywallID,
            placement: paywallID,
            presentationID: presentationID,
            variationId: variationId,
            completion
        )
    }

    /// Extended variant used internally when the placement identifier differs from the
    /// paywall identifier (e.g. multi-placement paywalls).
    func purchaseAdaptyProduct(
        _ product: AdaptyPaywallProduct,
        paywallID: String,
        placement: String,
        presentationID: String? = nil,
        variationId: String? = nil,
        _ completion: @escaping (PurchaseResult) -> Void
    ) {
        let productContext = AdaptyProductContext(product: product)
        let checkoutContext = PaywallCheckoutContext(
            paywallID: paywallID,
            placement: placement,
            product: productContext,
            variationId: variationId,
            presentationID: presentationID,
            source: .adapty
        )
        pendingVariationId = variationId
        if let logEvent {
            PaywallEventLogger.checkoutStarted(checkoutContext, log: logEvent)
        }

        adaptyService.makePurchase(product: product) { [weak self] purchaseResult in
            guard let self else { return }

            switch purchaseResult {
            case .success(let result):
                if result.isPurchaseCancelled {
                    self.handlePurchaseCancelled(
                        checkoutContext: checkoutContext,
                        completion: completion
                    )
                } else if result.isPurchasePending {
                    Log.printLog(
                        l: .error,
                        str: "Unexpected pending Adapty purchase for product \(product.vendorProductId) on placement \(placement)"
                    )
                    completion(.fail)
                } else {
                    if let profile = result.profile {
                        self.updateSubscriptionState(from: profile)
                    }
                    if let logEvent = self.logEvent {
                        PaywallEventLogger.purchaseSucceeded(checkoutContext, log: logEvent)
                    }
                    completion(.success)
                }
            case .failure(let error):
                self.handlePurchaseFailure(
                    error: error,
                    checkoutContext: checkoutContext,
                    completion: completion
                )
            }
        }
    }

    // MARK: - Restore

    /// Restores purchases, choosing the verification strategy based on
    /// `usesStoreKitEntitlementsForAccess`.
    ///
    /// In StoreKit mode:
    /// 1. `AppStore.sync()` is called to reconcile the local receipt with Apple's
    ///    servers.
    /// 2. Subscription state is derived directly from StoreKit entitlements.
    /// 3. Adapty is notified in the background (best-effort) so server-side data
    ///    stays consistent.
    ///
    /// In Adapty mode: `Adapty.restorePurchases()` is the sole source of truth.
    @MainActor
    public func restore(_ completion: @escaping (Bool) -> Void) {
        restore(source: .adapty, completion)
    }

    /// - Parameter paywall: The paywall the user restored from, attached to
    ///   `sale_confirmation_restore`. `nil` for restores started outside a paywall.
    @MainActor
    public func restore(
        source: PaywallSource,
        paywall: PaywallAnalyticsContext? = nil,
        _ completion: @escaping (Bool) -> Void
    ) {
        restorePurchasesWithAdapty(source: source, paywall: paywall, completion: completion)
    }

    /// Calls `Adapty.restorePurchases()` and merges the result with an optional
    /// StoreKit-derived status.
    ///
    /// - Parameters:
    ///   - storeKitStatus: When provided (StoreKit mode), its active state can override
    ///     the Adapty status if the two sources disagree.
    ///   - completion: Optional callback with `true` when an active sub is found.
    private func restorePurchasesWithAdapty(
        source: PaywallSource,
        paywall: PaywallAnalyticsContext? = nil,
        storeKitStatus: SubscriptionStatus? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        adaptyService.restorePurchases { [weak self] restoreResults in
            switch restoreResults {
            case .success(let profile):
                let status = self?.updateSubscriptionState(from: profile) ?? .inactive
                if let logEvent = self?.logEvent {
                    PaywallEventLogger.restoreSucceeded(source: source, paywall: paywall, log: logEvent)
                }
                completion?(status.isSubActive)
            case .failure(let error):
                let metadata = PaywallFailureMetadata(error: error)
                Log.printLog(
                    l: .error,
                    str: "Adapty restore failed: \(metadata.errorDomain) \(metadata.errorCode) \(metadata.reasonRawValue)"
                )
                if let logEvent = self?.logEvent {
                    PaywallEventLogger.restoreFailed(
                        reason: metadata.reason,
                        source: source,
                        errorDomain: metadata.errorDomain,
                        errorCode: metadata.errorCode,
                        log: logEvent
                    )
                }
                completion?(false)
            }
        }
    }

    // MARK: - Verify

    /// Re-fetches the subscription state from the appropriate source(s).
    ///
    /// In StoreKit mode, StoreKit is queried first and the result is passed along when
    /// Adapty is subsequently polled, allowing the merger logic in
    /// ``resolvedSubscriptionStatus(adaptyStatus:storeKitStatus:)`` to produce the
    /// correct combined status.
    func verifySubscriptionIfNeeded() async {
        await refreshSubscriptionStateFromAdapty()
    }

    // MARK: - Private – subscription state

    /// Derives the subscription status from an `AdaptyProfile`, optionally merged with
    /// a StoreKit status, then persists and broadcasts it.
    ///
    /// - Returns: The resolved status after the merge.
    @discardableResult
    private func updateSubscriptionState(from profile: AdaptyProfile) -> SubscriptionStatus {
        let accessLevel = profile.accessLevels["premium"]
        let status = accessLevel?.subscriptionStatus ?? .inactive
        updateSubscriptionState(status)
        return status
    }

    /// Persists the status and broadcasts it on the main queue.
    private func updateSubscriptionState(_ status: SubscriptionStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.subscriptionStatus = status
        }
    }

    /// Fetches the latest Adapty profile and updates the subscription state.
    ///
    /// When called in StoreKit mode the `storeKitStatus` is passed through so the
    /// merger logic can produce the correct combined status.
    private func refreshSubscriptionStateFromAdapty() async {
        do {
            let profile = try await adaptyService.profile()
            updateSubscriptionState(from: profile)
        } catch {
            Log.printLog(l: .error, str: "Failed to verify subscription: \(error.localizedDescription)")
        }
    }

    // MARK: - Private – purchase event helpers

    /// Handles the user cancelling an Adapty purchase by logging the appropriate
    /// analytics events and forwarding `.cancel` to the completion handler.
    private func handlePurchaseCancelled(
        checkoutContext: PaywallCheckoutContext,
        completion: @escaping (PurchaseResult) -> Void
    ) {
        if let logEvent {
            PaywallEventLogger.purchaseCancelled(checkoutContext, log: logEvent)
        }
        completion(.cancel)
    }

    /// Handles a non-cancellation failure from an Adapty purchase.
    ///
    /// Adapty maps payment cancellations to an error with code
    /// `paymentCancelled`, so this method delegates to ``handlePurchaseCancelled``
    /// when that specific code is detected, avoiding duplicate event logging.
    private func handlePurchaseFailure(
        error: AdaptyError,
        checkoutContext: PaywallCheckoutContext,
        completion: @escaping (PurchaseResult) -> Void
    ) {
        if error.errorCode == AdaptyError.ErrorCode.paymentCancelled.rawValue {
            handlePurchaseCancelled(
                checkoutContext: checkoutContext,
                completion: completion
            )
        } else {
            let metadata = PaywallFailureMetadata(error: error)
            Log.printLog(
                l: .error,
                str: "Adapty purchase failed for product \(checkoutContext.productID) on placement \(checkoutContext.placement): \(metadata.errorDomain) \(metadata.errorCode) \(metadata.reasonRawValue)"
            )
            if let logEvent {
                PaywallEventLogger.purchaseFailed(
                    checkoutContext,
                    adaptyError: error,
                    reason: metadata.reason,
                    log: logEvent
                )
            }
            completion(.fail)
        }
    }
}
