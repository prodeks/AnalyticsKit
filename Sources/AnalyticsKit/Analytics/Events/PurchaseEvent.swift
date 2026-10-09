import Foundation
import Firebase
import FacebookCore
import StoreKit
import Adapty

/// Source-agnostic failure payload for `PurchaseEvent.fail`.
struct PurchaseFailurePayload {
    let productID: String
    let errorDomain: String
    let errorCode: Int
    let errorDescription: String
    let value: String

    init(adaptyError error: AdaptyError, productID: String) {
        self.productID = productID
        self.errorDomain = (error as NSError).domain
        self.errorCode = error.errorCode
        self.errorDescription = error.localizedDescription

        var value = ""
        value.append("code: \(error.errorCode)\n")
        error.errorUserInfo.forEach { key, valueItem in
            value.append("\(key): \(valueItem)\n")
        }
        self.value = value
    }

    init(
        productID: String,
        errorDomain: String,
        errorCode: Int,
        description: String
    ) {
        self.productID = productID
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorDescription = description
        self.value = "code: \(errorCode)\n\(errorDomain): \(description)\n"
    }

    init(
        productID: String,
        errorDomain: String,
        errorCode: Int,
        description: String,
        value: String?
    ) {
        self.productID = productID
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorDescription = description
        self.value = value ?? "code: \(errorCode)\n\(errorDomain): \(description)\n"
    }
}

/// Represents the four possible outcomes of an in-app purchase attempt.
///
/// These events are logged to every analytics backend via `AnalyticsService.log(e:)`.
/// The Firebase backend additionally logs a purchase revenue event for `.success` via
/// `AppEvents.shared.logPurchase(amount:currency:)`.
///
/// ## Event names (stable — do not rename)
/// | Case | Firebase / FB / AF name |
/// |---|---|
/// | `.success` | `sale_confirmation_success` |
/// | `.cancel` | `sale_confirmation_cancel` |
/// | `.fail` | `sale_confirmation_fail` |
/// | `.restore` | `sale_confirmation_restore` |
enum PurchaseEvent: EventProtocol {

    /// The purchase completed successfully.
    ///
    /// The context's price and currency are used by `AnalyticsService` to log revenue
    /// to Facebook.
    case success(PaywallCheckoutContext)

    /// The user cancelled the purchase dialog before payment was authorised.
    ///
    /// Price and currency are preserved so cancelled checkout funnels can be valued the
    /// same way as completions.
    case cancel(PaywallCheckoutContext)

    /// The purchase failed due to an Adapty or StoreKit error.
    ///
    /// The payload keeps the legacy string value while also exposing structured error
    /// fields that work across Adapty and StoreKit.
    case fail(PaywallCheckoutContext, PurchaseFailurePayload)

    /// A restore-purchases operation completed.
    ///
    /// No product-level payload is attached because a restore may affect multiple
    /// products simultaneously and the authoritative state is derived from the profile
    /// returned by `Adapty.restorePurchases()`. `paywall` is `nil` when the restore was
    /// not started from a paywall (for example from Settings).
    case restore(source: PaywallSource, paywall: PaywallAnalyticsContext?)

    // MARK: - EventProtocol

    var name: String {
        switch self {
        case .cancel: return "sale_confirmation_cancel"
        case .success: return "sale_confirmation_success"
        case .fail: return "sale_confirmation_fail"
        case .restore: return "sale_confirmation_restore"
        }
    }

    var params: [String: Any] {
        switch self {
        case .success(let context), .cancel(let context):
            return PaywallAnalyticsContext(context).analyticsParams.merging([
                "product_id": context.productID,
                AnalyticsParameterValue: context.price,
                "currency": context.currency
            ]) { _, new in new }

        case .fail(let context, let payload):
            return PaywallAnalyticsContext(context).analyticsParams.merging([
                "product_id": payload.productID,
                AnalyticsParameterValue: payload.value,
                "error_domain": payload.errorDomain,
                "error_code": payload.errorCode,
                "error_description": payload.errorDescription
            ]) { _, new in new }

        case .restore(let source, let paywall):
            var result = paywall?.analyticsParams ?? [:]
            result["purchase_service"] = source.analyticsValue
            return result
        }
    }
}
