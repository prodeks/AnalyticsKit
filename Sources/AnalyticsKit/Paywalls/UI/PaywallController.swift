import Foundation
import StoreKit
import Lottie
import Adapty

public class PaywallController: UIViewController, PaywallViewDelegateProtocol, UIViewControllerTransitioningDelegate, PaywallControllerProtocol {
    
    public var dismissed: ((_ purchasedProductID: String?) -> Void)?
    public var navigated: ((any PaywallPlacementProtocol) -> Void)?
    public var paywallScreenID: String? { paywallView.paywallID.rawValue }

    public var paywallAnalyticsContext: PaywallAnalyticsContext? {
        if let presentationContext {
            return PaywallAnalyticsContext(presentationContext)
        }
        return PaywallAnalyticsContext(
            paywallID: paywallView.paywallID.rawValue,
            placementID: adaptyPaywallData.placement,
            variationID: adaptyPaywallData.adaptyPaywall.variationId,
            purchaseService: PaywallSource.adapty.analyticsValue
        )
    }

    private var presentationContext: PaywallPresentationContext?
    private var logEvent: ((EventProtocol) -> Void)?
    private var didLogOpen = false

    let overlayView = LoaderOverlayView()
    let purchaseService: PurchaseService
    let adaptyPaywallData: CustomPaywallData
    let paywallView: any PaywallViewProtocol
    
    init(
        purchaseService: PurchaseService, 
        paywallView: any PaywallViewProtocol,
        adaptyPaywallData: CustomPaywallData
    ) {
        self.paywallView = paywallView
        self.purchaseService = purchaseService
        self.adaptyPaywallData = adaptyPaywallData
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func loadView() {
        view = paywallView
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()

        paywallView.delegate = self
        view.addSubview(overlayView)
        overlayView.isHidden = true
        
        if let navigationController {
            navigationController.setNavigationBarHidden(true, animated: false)
        }
        
        Adapty.logShowPaywall(adaptyPaywallData.adaptyPaywall)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !didLogOpen, let presentationContext else { return }
        didLogOpen = true
        logEvent?(PaywallOpenEvent(context: presentationContext))
    }

    func configureAnalytics(
        context: PaywallPresentationContext,
        logEvent: @escaping (EventProtocol) -> Void
    ) {
        self.presentationContext = context
        self.logEvent = logEvent
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        overlayView.frame = view.bounds
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        if let navigationController {
            navigationController.setNavigationBarHidden(false, animated: false)
        }
    }
    
    public func pricingData(_ iap: any IAPProtocol) -> PricingData? {
        return adaptyPaywallData.products
            .first(where: { $0.vendorProductId == iap.productID })
            .flatMap { product in
                PricingData(
                    value: Double(truncating: product.price as NSNumber),
                    priceLocale: product.priceLocale,
                    currencySymbol: product.currencySymbol ?? "",
                    introOfferValue: product.subscriptionOffer.map { Double(truncating: $0.price as NSNumber) },
                    introOfferLocalizedPrice: product.subscriptionOffer?.localizedPrice,
                    iap: iap
                )
            }
    }
    
    public func restore() {
        overlayView.isHidden = false
        purchaseService.restore(source: .adapty, paywall: paywallAnalyticsContext) { [weak self] restored in
            self?.overlayView.isHidden = true
            if restored {
                self?.dismiss()
            } else {
                self?.presentNoPurchasesToRestoreAlert()
            }
        }
    }

    public func didSelectProduct(_ iap: any IAPProtocol, previous: (any IAPProtocol)?) {
        PaywallLifetimeAnalytics.logSelection(
            iap,
            previous: previous,
            context: paywallAnalyticsContext,
            log: logEvent
        )
    }
    
    public func purchase(_ iap: any IAPProtocol) {
        PaywallLifetimeAnalytics.logCheckout(
            iap,
            context: paywallAnalyticsContext,
            log: logEvent
        )
        self.overlayView.isHidden = false
        if let product = adaptyPaywallData.products.first(where: { $0.vendorProductId == iap.productID }) {
            purchaseService.purchaseAdaptyProduct(
                product,
                paywallID: paywallView.paywallID.rawValue,
                placement: adaptyPaywallData.placement,
                presentationID: presentationContext?.presentationID,
                variationId: presentationContext?.variationId
            ) { [weak self] result in
                guard let self = self else { return }
                self.overlayView.isHidden = true
                
                switch result {
                case .cancel:
                    break
                case .fail:
                    self.presentCannotPurchaseAlert()
                case .success:
                    self.dismiss(iap.productID)
                }
            }
        } else {
            Log.printLog(
                l: .error,
                str: "Selected IAP \(iap.productID) not found in Adapty products for placement \(adaptyPaywallData.placement)"
            )
            self.presentCannotPurchaseAlert()
            self.overlayView.isHidden = true
        }
    }
    
    private func dismiss(_ purchasedProductID: String?) {
        if let presentationContext {
            logEvent?(PaywallClosedEvent(
                context: presentationContext,
                purchased: purchasedProductID != nil
            ))
        }

        if let presented = presentedViewController {
            presented.dismiss(animated: true) {
                self.dismissed?(purchasedProductID)
            }
        } else {
            self.dismissed?(purchasedProductID)
        }
    }
    
    public func termsTap(_ item: URLConvertable) {
        presentPolicyItem(item)
    }
    
    public func privacyPolicyTap(_ item: URLConvertable) {
        presentPolicyItem(item)
    }
    
    public func navigate(to placement: any PaywallPlacementProtocol) {
        navigated?(placement)
    }
    
    public func dismiss() {
        dismiss(nil)
    }
    
    func presentNoPurchasesToRestoreAlert() {
        let alert = UIAlertController(
            title: PurchasesAndAnalytics.Strings.noPurchasesToRestore,
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(.init(title: PurchasesAndAnalytics.Strings.cancel, style: .cancel))
        if let presented = presentedViewController { 
            presented.present(alert, animated: true)
        } else {
            present(alert, animated: true)
        }
    }
    
    func presentCannotPurchaseAlert() {
        let alert = UIAlertController(
            title: PurchasesAndAnalytics.Strings.somethingWentWrongDuringPurchase,
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(.init(title: PurchasesAndAnalytics.Strings.cancel, style: .cancel))
        if let presented = presentedViewController { 
            presented.present(alert, animated: true)
        } else {
            present(alert, animated: true)
        }
    }
    
    func presentPolicyItem(_ item: URLConvertable) {
        let c = WebViewController()
        let n = UINavigationController(rootViewController: c)
        c.item = item
        if let presented = presentedViewController {
            presented.present(n, animated: true)
        } else {
            present(n, animated: true)
        }
    }
}
