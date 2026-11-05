import FirebaseCore
import FirebaseRemoteConfig

public protocol RemoteConfigServiceProtocol {
    func getString<K: RawRepresentable>(_ key: K) -> String? where K.RawValue == String
    func getInt<K: RawRepresentable>(_ key: K) -> Int where K.RawValue == String
    func getBool<K: RawRepresentable>(_ key: K) -> Bool where K.RawValue == String
}

class RemoteConfigService: RemoteConfigServiceProtocol {
    
    /// `nil` when the app has no Firebase configuration. Every read then returns the empty value.
    let remoteConfig: RemoteConfig?
    
    static let shared = RemoteConfigService()

    private init() {
        guard FirebaseApp.app() != nil else {
            remoteConfig = nil
            return
        }
        let remoteConfig = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        settings.minimumFetchInterval = 0
        remoteConfig.configSettings = settings
        self.remoteConfig = remoteConfig
    }
    
    public func getInt<K: RawRepresentable>(_ key: K) -> Int where K.RawValue == String {
        remoteConfig?.configValue(forKey: key.rawValue).numberValue.intValue ?? 0
    }
    
    public func getString<K: RawRepresentable>(_ key: K) -> String? where K.RawValue == String {
        remoteConfig?.configValue(forKey: key.rawValue).stringValue
    }
    
    public func getBool<K: RawRepresentable>(_ key: K) -> Bool where K.RawValue == String {
        remoteConfig?.configValue(forKey: key.rawValue).boolValue ?? false
    }
    
    func fetch() async {
        return await withCheckedContinuation { continuation in
            fetch {
                continuation.resume()
            }
        }
    }
    
    func fetch(_ completion: @escaping () -> Void) {
        guard let remoteConfig else {
            completion()
            return
        }
        remoteConfig.fetch { status, error in
            Log.printLog(l: .debug, str: status.description)
            if status != .success {
                if let error {
                    Log.printLog(l: .error, str: error.localizedDescription)
                } else {
                    Log.printLog(l: .error, str: status.description)
                }
                completion()
                return
            }
            
            remoteConfig.activate { _, error in
                if let error {
                    Log.printLog(l: .error, str: error.localizedDescription)
                } else {
                    Log.printLog(l: .debug, str: "Remote config activated")
                }
                completion()
            }
        }
    }
}

extension RemoteConfigFetchStatus {
    var description: String {
        switch self {
        case .failure:
            return "Remote Config Status: Fetch failed"
        case .noFetchYet:
            return "Remote Config Status: No fetch yet"
        case .success:
            return "Remote Config Status: Fetch success"
        case .throttled:
            return "Remote Config Status: Fetch throttled"
        @unknown default:
            return ""
        }
    }
}
