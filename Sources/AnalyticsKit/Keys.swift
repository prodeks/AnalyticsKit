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
        public static var facebookAppId: String?
        public static var facebookClientToken: String?
        public static var sentryDSN: String?
        public static var sentryReleseName: String?
        
        // Attribution data keys
        public static let adjustDeeplinkKey = "adjust_deeplink"
        public static let adjustAttributionKey = "adjust_attribution"
    }
}
