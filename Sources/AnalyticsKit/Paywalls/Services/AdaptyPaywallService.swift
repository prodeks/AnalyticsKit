import UIKit
import StoreKit
import Network
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

/// Loads every placement once at startup, then fetches the placements that failed to load
/// again when the network comes back or when a paywall is requested for one of them.
class AdaptyPaywallService: PaywallServiceProtocol {
    
    public var placements = Set<String>()
    
    public var uiFactory: ((PaywallIdentifier) -> PaywallViewProtocol?)?
    
    /// Loaded placements by identifier. A placement only ever goes from missing to loaded.
    var paywallData = [String: CustomPaywallData]()
    
    private enum FetchTrigger: String {
        case startup
        case networkRestored = "network_restored"
        case paywallMiss = "paywall_miss"
    }
    
    private enum FetchState: Equatable {
        /// The startup fetch has not run. Nothing else fetches before it, because it runs only
        /// after the Adapty identity has settled.
        case notStarted
        case idle
        /// One fetch is in flight. `next` is a trigger that arrived meanwhile; it is replayed
        /// once the fetch ends, so the placements it was meant for get another attempt.
        case fetching(next: FetchTrigger?)
    }
    
    private var fetchState = FetchState.notStarted
    private var pathMonitor: NWPathMonitor?
    private var isNetworkSatisfied: Bool?
    
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
        
        if let customPaywallData = paywallData[placement.identifier] {
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
            requestFetch(.paywallMiss)
            return nil
        }
    }
    
    func fetchPaywallsAndProducts() async {
        guard fetchState == .notStarted else { return }
        fetchState = .fetching(next: nil)
        startMonitoringNetwork()
        await fetchMissingPaywalls(trigger: .startup)
        finishFetch()
    }
    
    private func requestFetch(_ trigger: FetchTrigger) {
        switch fetchState {
        case .notStarted, .fetching(next: .some(_)):
            return
        case .fetching(next: nil):
            fetchState = .fetching(next: trigger)
        case .idle:
            guard !missingPlacements.isEmpty else { return }
            fetchState = .fetching(next: nil)
            Task {
                await fetchMissingPaywalls(trigger: trigger)
                finishFetch()
            }
        }
    }
    
    private func finishFetch() {
        let next: FetchTrigger?
        if case let .fetching(queued) = fetchState {
            next = queued
        } else {
            next = nil
        }
        fetchState = .idle
        if let next {
            requestFetch(next)
        }
    }
    
    private var missingPlacements: Set<String> {
        placements.subtracting(paywallData.keys)
    }
    
    private func startMonitoringNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            MainActor.assumeIsolated {
                self?.networkPathChanged(isSatisfied: isSatisfied)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }
    
    /// Only a change to a usable network triggers a fetch. The first update just records the
    /// state at startup, when the startup fetch is already running.
    private func networkPathChanged(isSatisfied: Bool) {
        defer { isNetworkSatisfied = isSatisfied }
        if isSatisfied, isNetworkSatisfied == false {
            requestFetch(.networkRestored)
        }
    }
    
    private func fetchMissingPaywalls(trigger: FetchTrigger) async {
        let missing = missingPlacements
        guard !missing.isEmpty else { return }
        Log.printLog(l: .debug, str: "Paywalls: fetching \(missing.sorted()) [\(trigger.rawValue)]")
        
        let paywalls = await missing
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
        
        for paywall in paywalls {
            paywallData[paywall.placement] = paywall
        }
        Log.printLog(
            l: .debug,
            str: "Paywalls: loaded \(paywalls.map(\.placement).sorted()), missing \(missingPlacements.sorted())"
        )
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
