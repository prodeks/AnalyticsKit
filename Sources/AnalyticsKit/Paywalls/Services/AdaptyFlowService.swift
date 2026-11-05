import Adapty
import AdaptyUI
import UIKit

/// Shows Adapty Flows: paywalls that the Adapty Flow Builder owns, screens and navigation included.
@MainActor public protocol FlowServiceProtocol: AnyObject {
    /// Fetches the flow of a placement, or returns `nil` when it cannot be shown.
    func makeFlowController(_ placement: any PaywallPlacementProtocol) async -> UIViewController?
}

final class AdaptyFlowService: FlowServiceProtocol {
    private let purchaseService: PurchaseService
    private let analyticsService: AnalyticsService

    /// `AdaptyFlowController` holds its delegate weakly. The delegate must stay alive for as
    /// long as the flow is on screen, also while a web page covers it.
    private var activeDelegate: FlowDelegate?

    init(purchaseService: PurchaseService, analyticsService: AnalyticsService) {
        self.purchaseService = purchaseService
        self.analyticsService = analyticsService
    }

    func makeFlowController(_ placement: any PaywallPlacementProtocol) async -> UIViewController? {
        let placementID = placement.identifier
        do {
            let flow = try await Adapty.getFlow(placementId: placementID)
            guard flow.hasViewConfiguration else {
                logFailure(placementID: placementID, metadata: PaywallAnalyticsError.missingPaywallData)
                return nil
            }
            let configuration = try await AdaptyUI.getFlowConfiguration(forFlow: flow)
            let delegate = FlowDelegate(
                presentation: PaywallPresentationContext(
                    paywallID: flow.name,
                    placement: placementID,
                    variationId: flow.variationId,
                    source: .adapty
                ),
                purchaseService: purchaseService,
                logEvent: analyticsService.log(e:)
            )
            let controller = try AdaptyUI.flowController(with: configuration, delegate: delegate)
            activeDelegate = delegate
            return controller
        } catch {
            analyticsService.log(e: PaywallFetchErrorEvent(source: .adapty, placement: placementID, error: error))
            logFailure(placementID: placementID, metadata: AnalyticsErrorMetadata(error: error))
            return nil
        }
    }

    private func logFailure(placementID: String, metadata: AnalyticsErrorMetadata) {
        Log.printLog(
            l: .error,
            str: "Failed to show flow for placement \(placementID): \(metadata.errorDomain) \(metadata.errorCode) \(metadata.reasonRawValue)"
        )
        analyticsService.log(e: PaywallFailedEvent(source: .adapty, placement: placementID, metadata: metadata))
    }
}

/// AdaptyUI runs the purchase and the restore. This class records their results the same way
/// `PaywallController` does, so the analytics funnel and the subscription state stay the same.
@MainActor
private final class FlowDelegate: AdaptyFlowControllerDelegate {
    private let presentation: PaywallPresentationContext
    private let purchaseService: PurchaseService
    private let logEvent: (EventProtocol) -> Void

    private var didLogOpen = false
    private var didPurchase = false
    private var selectedProductID: String?
    private var checkoutContext: PaywallCheckoutContext?

    private var analyticsContext: PaywallAnalyticsContext { PaywallAnalyticsContext(presentation) }

    init(
        presentation: PaywallPresentationContext,
        purchaseService: PurchaseService,
        logEvent: @escaping (EventProtocol) -> Void
    ) {
        self.presentation = presentation
        self.purchaseService = purchaseService
        self.logEvent = logEvent
    }

    func flowControllerDidAppear(_ controller: AdaptyFlowController) {
        guard !didLogOpen else { return }
        didLogOpen = true
        logEvent(PaywallOpenEvent(context: presentation))
    }

    func flowControllerDidDisappear(_ controller: AdaptyFlowController) {
        // A web page over the flow also fires this callback.
        guard controller.isBeingDismissed else { return }
        logEvent(PaywallClosedEvent(context: presentation, purchased: didPurchase))
    }

    func flowController(_ controller: AdaptyFlowController, didSelectProduct product: AdaptyPaywallProduct) {
        PaywallLifetimeAnalytics.logSelection(
            productID: product.vendorProductId,
            previousProductID: selectedProductID,
            context: analyticsContext,
            log: logEvent
        )
        selectedProductID = product.vendorProductId
    }

    func flowController(_ controller: AdaptyFlowController, didStartPurchase product: AdaptyPaywallProduct) {
        PaywallLifetimeAnalytics.logCheckout(
            productID: product.vendorProductId,
            context: analyticsContext,
            log: logEvent
        )
        checkoutContext = startCheckout(product)
    }

    func flowController(
        _ controller: AdaptyFlowController,
        didFinishPurchase product: AdaptyPaywallProduct,
        purchaseResult: AdaptyPurchaseResult
    ) {
        finishCheckout(.success(purchaseResult), product: product, controller: controller)
    }

    func flowController(
        _ controller: AdaptyFlowController,
        didFailPurchase product: AdaptyPaywallProduct,
        error: AdaptyError
    ) {
        finishCheckout(.failure(error), product: product, controller: controller)
    }

    func flowController(_ controller: AdaptyFlowController, didFinishRestoreWith profile: AdaptyProfile) {
        finishRestore(.success(profile), controller: controller)
    }

    func flowController(_ controller: AdaptyFlowController, didFailRestoreWith error: AdaptyError) {
        finishRestore(.failure(error), controller: controller)
    }

    func flowController(_ controller: AdaptyFlowController, didReceiveError error: AdaptyUIError) {
        Log.printLog(l: .error, str: "Flow error on placement \(presentation.placement): \(error.localizedDescription)")
    }

    private func startCheckout(_ product: AdaptyPaywallProduct) -> PaywallCheckoutContext {
        purchaseService.startCheckout(
            product,
            paywallID: product.paywallName,
            placement: presentation.placement,
            presentationID: presentation.presentationID,
            variationId: product.variationId
        )
    }

    private func finishCheckout(
        _ result: Result<AdaptyPurchaseResult, AdaptyError>,
        product: AdaptyPaywallProduct,
        controller: AdaptyFlowController
    ) {
        purchaseService.finishCheckout(
            result,
            checkoutContext: checkoutContext ?? startCheckout(product)
        ) { [weak self, weak controller] purchase in
            switch purchase {
            case .cancel:
                break
            case .fail:
                controller?.presentPaywallAlert(title: PurchasesAndAnalytics.Strings.somethingWentWrongDuringPurchase)
            case .success:
                self?.didPurchase = true
                controller?.dismiss(animated: true)
            }
        }
        checkoutContext = nil
    }

    private func finishRestore(_ result: Result<AdaptyProfile, AdaptyError>, controller: AdaptyFlowController) {
        purchaseService.finishRestore(result, source: .adapty, paywall: analyticsContext) { [weak controller] isActive in
            if isActive {
                controller?.dismiss(animated: true)
            } else {
                controller?.presentPaywallAlert(title: PurchasesAndAnalytics.Strings.noPurchasesToRestore)
            }
        }
    }
}
