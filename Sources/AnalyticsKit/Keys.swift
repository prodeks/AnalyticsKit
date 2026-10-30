import Foundation

extension PurchasesAndAnalytics {
    public enum Keys {
        public static var subscriptionServiceKey: String?
        public static var adjustKey: String?
        public static var adjustInstallGateEnabled: Bool = false
        public static var isFreshInstall: Bool = false
        public static var sharedSecret: String?
        public static var appsflyerKey: String?
        public static var appID: String?
        public static var mixPanelToken: String?
        /// Must match the data residency of the project that owns `mixPanelToken`.
        /// Mixpanel answers 200 to events sent to the wrong region and drops them.
        public static var mixPanelRegion: MixpanelRegion = .eu
        public static var facebookAppId: String?
        public static var facebookClientToken: String?
        public static var sentryDSN: String?
        public static var sentryReleseName: String?
        
        // Attribution data keys
        public static let adjustDeeplinkKey = "adjust_deeplink"
        public static let adjustAttributionKey = "adjust_attribution"
    }

    public enum MixpanelRegion {
        case us
        case eu

        var serverURL: String {
            switch self {
            case .us: "https://api.mixpanel.com"
            case .eu: "https://api-eu.mixpanel.com"
            }
        }
    }
}
