import UIKit
import StoreKit
import Adapty

public protocol PaywallPlacementProtocol: Hashable {
    var identifier: String { get }
}

public protocol PaywallScreenProtocol: RawRepresentable where RawValue == String {
    
}

public protocol PaywallControllerProtocol: UIViewController {
    var dismissed: ((_ purchasedProductID: String?) -> Void)? { get set }
    var navigated: ((any PaywallPlacementProtocol) -> Void)? { get set }
    var paywallScreenID: String? { get }
}

@MainActor public protocol PaywallServiceProtocol: AnyObject {
    var placements: Set<String> { get set }
    var uiFactory: ((PaywallIdentifier) -> PaywallViewProtocol?)? { get set }
    func getPaywall(_ placement: any PaywallPlacementProtocol) -> PaywallControllerProtocol?
    func setFallbackPaywalls(url: URL)
}

struct CustomPaywallData {
    let placement: String
    let adaptyPaywall: AdaptyPaywall
    let products: [AdaptyPaywallProduct]
}

public typealias PaywallIdentifier = String

class AdaptyPaywallService: PaywallServiceProtocol {
    
    public var placements = Set<String>()
    
    public var uiFactory: ((PaywallIdentifier) -> PaywallViewProtocol?)?
    
    var paywallData = [CustomPaywallData]()
    
    let purchaseService: PurchaseService
    let analyticsService: AnalyticsService
    
    init(purchaseService: PurchaseService, analyticsService: AnalyticsService) {
        self.purchaseService = purchaseService
        self.analyticsService = analyticsService
    }
    
    public func setFallbackPaywalls(url: URL) {
        analyticsService.setPaywallFallback(fileURL: url)
    }
    
    public func getPaywall(_ placement: any PaywallPlacementProtocol) -> PaywallControllerProtocol? {
        Log.printLog(l: .debug, str: "Show paywall for placement: \(placement.identifier)")
        assert(uiFactory != nil)
        
        if let customPaywallData = paywallData.first(where: { $0.placement == placement.identifier }) {
            if let view = uiFactory?(customPaywallData.adaptyPaywall.name) {
                let context = PaywallPresentationContext(
                    paywallID: view.paywallID.rawValue,
                    placement: customPaywallData.placement,
                    variationId: customPaywallData.adaptyPaywall.variationId,
                    source: .adapty
                )
                let controller = PaywallController(
                    purchaseService: purchaseService,
                    paywallView: view,
                    adaptyPaywallData: customPaywallData
                )
                controller.configureAnalytics(
                    context: context,
                    logEvent: analyticsService.log(e:)
                )
                return controller
            } else {
                logPaywallFailed(
                    placement: placement.identifier,
                    metadata: PaywallAnalyticsError.customViewUnavailable
                )
                return nil
            }
        } else {
            logPaywallFailed(
                placement: placement.identifier,
                metadata: PaywallAnalyticsError.missingPaywallData
            )
            return nil
        }
    }
    
    func fetchPaywallsAndProducts() async {
        let paywalls = await placements
            .asyncMap { identifier -> CustomPaywallData? in
                do {
                    let paywall = try await Adapty.getPaywall(placementId: identifier)
                    let products: [AdaptyPaywallProduct]
                    do {
                        products = try await Adapty.getPaywallProducts(paywall: paywall)
                    } catch {
                        self.logPricesFailed(metadata: AnalyticsErrorMetadata(error: error))
                        self.analyticsService.log(
                            e: PaywallFetchErrorEvent(
                                source: .adapty,
                                placement: identifier,
                                error: error
                            )
                        )
                        return nil
                    }
                    
                    return CustomPaywallData(
                        placement: identifier,
                        adaptyPaywall: paywall,
                        products: products
                    )
                } catch {
                    Log.printLog(
                        l: .error,
                        str: "Failed to fetch paywall for placement \(identifier): \(error.localizedDescription)"
                    )
                    self.analyticsService.log(
                        e: PaywallFetchErrorEvent(
                            source: .adapty,
                            placement: identifier,
                            error: error
                        )
                    )
                    return nil
                }
            }
            .compactMap { $0 }
        
        self.paywallData = paywalls
    }
    
    private func logPricesFailed(metadata: AnalyticsErrorMetadata) {
        Log.printLog(
            l: .error,
            str: "Failed to load paywall products: \(metadata.errorDomain) \(metadata.errorCode) \(metadata.reasonRawValue)"
        )
        analyticsService.log(
            e: PricesFailedEvent(
                source: .adapty,
                metadata: metadata
            )
        )
    }
    
    private func logPaywallFailed(placement: String, metadata: AnalyticsErrorMetadata) {
        Log.printLog(
            l: .error,
            str: "Failed to show paywall for placement: \(placement) with error: \(metadata.errorDomain) \(metadata.errorCode) \(metadata.reasonRawValue)"
        )
        analyticsService.log(
            e: PaywallFailedEvent(
                source: .adapty,
                placement: placement,
                metadata: metadata
            )
        )
    }
}
