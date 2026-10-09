import Foundation

/// Paywall presentation metadata host-app views can attach to custom tap events.
///
/// Keys in `analyticsParams` match `PaywallEvent.params` so a host event can
/// join the same Mixpanel funnel as `paywall_shown` / `paywall_checkout_initiated`.
public struct PaywallAnalyticsContext {
    public let paywallID: String
    public let placementID: String
    public let variationID: String?
    public let presentationID: String?
    public let purchaseService: String

    public init(
        paywallID: String,
        placementID: String,
        variationID: String? = nil,
        presentationID: String? = nil,
        purchaseService: String = "adapty"
    ) {
        self.paywallID = paywallID
        self.placementID = placementID
        self.variationID = variationID
        self.presentationID = presentationID
        self.purchaseService = purchaseService
    }

    init(_ context: PaywallCheckoutContext) {
        self.init(
            paywallID: context.paywallID,
            placementID: context.placement,
            variationID: context.variationId,
            presentationID: context.presentationID,
            purchaseService: context.source.analyticsValue
        )
    }

    init(_ context: PaywallPresentationContext) {
        self.init(
            paywallID: context.paywallID,
            placementID: context.placement,
            variationID: context.variationId,
            presentationID: context.presentationID,
            purchaseService: context.source.analyticsValue
        )
    }

    /// Same keys `PaywallEvent.params` emits, for host-app events.
    public var analyticsParams: [String: Any] {
        var result: [String: Any] = [
            "paywall_id": paywallID,
            "placement_id": placementID,
            "purchase_service": purchaseService
        ]
        if let variationID {
            result["variation_id"] = variationID
        }
        if let presentationID {
            result["presentation_id"] = presentationID
        }
        return result
    }

    var paywallSource: PaywallSource {
        purchaseService == PaywallSource.storeKit.analyticsValue ? .storeKit : .adapty
    }
}
