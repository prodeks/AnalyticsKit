import AdServices
import Foundation

public enum AdjustInstallGateState: String, Equatable, Sendable {
    case pending
    case active
    case disabled
}

public final class AdjustInstallGate {
    public static let stateDefaultsKey = "com.aweb.analytics.adjust_install_gate_state"
    public static let adServicesEndpoint = URL(string: "https://api-adservices.apple.com/api/v1/")!

    public typealias TokenProvider = @Sendable () throws -> String
    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias SleepClosure = @Sendable (TimeInterval) async -> Void

    private let userDefaults: UserDefaults
    private let tokenProvider: TokenProvider
    private let httpClient: HTTPClient
    private let sleep: SleepClosure
    private let processArguments: [String]
    private let maxAttempts: Int
    private let retryDelay: TimeInterval
    private let totalTimeout: TimeInterval

    public init(
        userDefaults: UserDefaults = .standard,
        tokenProvider: @escaping TokenProvider = { try AAAttribution.attributionToken() },
        httpClient: @escaping HTTPClient = AdjustInstallGate.defaultHTTPClient,
        sleep: @escaping SleepClosure = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        processArguments: [String] = ProcessInfo.processInfo.arguments,
        maxAttempts: Int = 3,
        retryDelay: TimeInterval = 1.0,
        totalTimeout: TimeInterval = 5.0
    ) {
        self.userDefaults = userDefaults
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
        self.sleep = sleep
        self.processArguments = processArguments
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelay = retryDelay
        self.totalTimeout = totalTimeout
    }

    public var storedState: AdjustInstallGateState? {
        guard let raw = userDefaults.string(forKey: Self.stateDefaultsKey) else {
            return nil
        }
        return AdjustInstallGateState(rawValue: raw)
    }

    public func setStoredState(_ state: AdjustInstallGateState) {
        userDefaults.set(state.rawValue, forKey: Self.stateDefaultsKey)
    }

    /// Evaluates whether Adjust SDK should be initialized on this launch.
    public func shouldStartAdjust(isFreshInstall: Bool) async -> Bool {
        if let state = storedState {
            switch state {
            case .active, .pending:
                return true
            case .disabled:
                return false
            }
        }

        guard isFreshInstall else {
            setStoredState(.disabled)
            return false
        }

        let isASA = await checkIsASAInstall()
        if isASA {
            setStoredState(.disabled)
            return false
        } else {
            setStoredState(.pending)
            return true
        }
    }

    /// Evaluates Adjust attribution and updates persisted gate state.
    /// Returns `true` when Adjust should remain active, `false` when it should be disabled.
    @discardableResult
    public func handleAttribution(network: String?, trackerName: String? = nil) -> Bool {
        let keepEnabled = Self.shouldKeepAdjustEnabled(network: network, trackerName: trackerName)
        setStoredState(keepEnabled ? .active : .disabled)
        return keepEnabled
    }

    /// Returns `false` when attribution network is `"Organic"` or `"Apple Search Ads"` (case-insensitive, trimmed).
    public static func shouldKeepAdjustEnabled(network: String?, trackerName: String? = nil) -> Bool {
        let candidate = normalizedSource(network) ?? normalizedSource(trackerName)
        guard let candidate else {
            return true
        }
        switch candidate {
        case "organic", "apple search ads":
            return false
        default:
            return true
        }
    }

    private static func normalizedSource(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private func isSimulatedASAInstall() -> Bool {
        #if DEBUG
        guard let flagIndex = processArguments.firstIndex(of: "-SimulateASAInstall"),
              processArguments.indices.contains(flagIndex + 1) else {
            return false
        }
        let value = processArguments[flagIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "yes" || value == "true" || value == "1"
        #else
        return false
        #endif
    }

    private func checkIsASAInstall() async -> Bool {
        if isSimulatedASAInstall() {
            Log.printLog(l: .debug, str: "AdjustInstallGate: simulated ASA install via launch argument")
            return true
        }

        let token: String
        do {
            token = try tokenProvider()
        } catch {
            Log.printLog(l: .debug, str: "AdjustInstallGate: AdServices token unavailable (\(error.localizedDescription))")
            return false
        }

        let totalTimeout = self.totalTimeout
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                return await self.fetchASAAttributionWithRetry(token: token)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, totalTimeout) * 1_000_000_000))
                return false
            }

            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }
    }

    private func fetchASAAttributionWithRetry(token: String) async -> Bool {
        var request = URLRequest(url: Self.adServicesEndpoint)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(token.utf8)

        for attempt in 1...maxAttempts {
            if Task.isCancelled { return false }
            do {
                let (data, response) = try await httpClient(request)
                if response.statusCode == 404, attempt < maxAttempts {
                    await sleep(retryDelay)
                    continue
                }
                guard response.statusCode == 200 else {
                    Log.printLog(l: .debug, str: "AdjustInstallGate: AdServices status \(response.statusCode)")
                    return false
                }
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let attribution = json["attribution"] as? Bool {
                    return attribution
                }
                return false
            } catch {
                Log.printLog(l: .debug, str: "AdjustInstallGate: AdServices request failed (\(error.localizedDescription))")
                return false
            }
        }
        return false
    }

    public static func defaultHTTPClient(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}
