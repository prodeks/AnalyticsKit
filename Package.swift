// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AnalyticsKit",
    platforms: [.iOS(.v16)],
    products: [.library(name: "AnalyticsKit", targets: ["AnalyticsKit"])],
    dependencies: [
        .package(url: "https://github.com/AppsFlyerSDK/AppsFlyerFramework-Dynamic", exact: .init(6, 15, 2)),
        .package(url: "https://github.com/facebook/facebook-ios-sdk", exact: Version(18, 0, 0)),
        .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: Version(12, 8, 0)),
        .package(url: "https://github.com/airbnb/lottie-ios.git", exact: Version(4, 5, 1)),
        .package(url: "https://github.com/adaptyteam/AdaptySDK-iOS.git", exact: Version(3, 15, 7)),
        .package(url: "https://github.com/AppsFlyerSDK/PurchaseConnector-Dynamic", exact: .init(6, 15, 3)),
        .package(url: "https://github.com/mixpanel/mixpanel-swift.git", exact: .init(6, 8, 0)),
        .package(url: "https://github.com/adjust/ios_sdk", exact: .init(5, 5, 0)),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: .init(9, 16, 1)),
        .package(url: "https://github.com/apple/swift-algorithms.git", exact: .init(1, 2, 1)),
        .package(url: "https://github.com/CombineCommunity/CombineExt", exact: .init(1, 9, 0)),
        .package(url: "https://github.com/SnapKit/SnapKit.git", exact: .init(6, 0, 0))
    ],
    targets: [
        .target(
            name: "AnalyticsKit",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "FacebookCore", package: "facebook-ios-sdk"),
                .product(name: "FirebaseRemoteConfig", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAnalytics", package: "firebase-ios-sdk"),
                .product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseDatabase", package: "firebase-ios-sdk"),
                .product(name: "FirebaseStorage", package: "firebase-ios-sdk"),
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk"),
                .product(name: "AppsFlyerLib-Dynamic", package: "AppsFlyerFramework-Dynamic"),
                .product(name: "Lottie", package: "lottie-ios"),
                .product(name: "Adapty", package: "AdaptySDK-iOS"),
                .product(name: "AdaptyUI", package: "AdaptySDK-iOS"),
                .product(name: "PurchaseConnector-Dynamic", package: "PurchaseConnector-Dynamic"),
                .product(name: "Mixpanel", package: "mixpanel-swift"),
                .product(name: "AdjustSdk", package: "ios_sdk"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "CombineExt", package: "CombineExt"),
                .product(name: "SnapKit", package: "SnapKit")
            ]
        )
    ]
)
