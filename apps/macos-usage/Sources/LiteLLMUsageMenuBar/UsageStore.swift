import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: UsageState = .needsKey
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var availableKeys: [GatewayKey] = []
    @Published private(set) var selectedKeyHash: String?
    @Published private(set) var keyListMessage: String?
    @Published private(set) var isLoadingKeys = false
    @Published private(set) var monthlyChartState: MonthlyUsageChartState = .loading
    @Published private(set) var autoRefreshInterval: AutoRefreshInterval
    private let keychain: KeychainStore
    private var client: GatewayClient
    private let monthlyUsageLoader = MonthlyUsageLoader()
    private(set) var gatewayURL: URL
    private var credentials: (username: String, password: String)?
    private var session: AuthSession?
    private var isRefreshing = false
    private var refreshGeneration = 0
    private var queuedRefresh = false
    private var queuedKeyReload = false
    private var refreshTimer: Timer?
    private var lastSpendSample: SpendSample?
    private var smoothedSpendPerDay: Double?
    private let selectedKeyDefaultsKey = "selected-key-hash"
    private let legacySelectedKeyDefaultsKey = "selected-key-name"
    private let refreshIntervalDefaultsKey = "auto-refresh-interval"
    private let gatewayURLDefaultsKey = "gateway-url"

    init(keychain: KeychainStore = KeychainStore(), client: GatewayClient? = nil) {
        let configuredURL = client?.baseURL ?? Self.loadGatewayURL()
        self.keychain = keychain
        self.client = client ?? GatewayClient(baseURL: configuredURL)
        gatewayURL = configuredURL
        selectedKeyHash = UserDefaults.standard.string(forKey: selectedKeyDefaultsKey)
            ?? UserDefaults.standard.string(forKey: legacySelectedKeyDefaultsKey)
        let storedInterval = UserDefaults.standard.object(forKey: refreshIntervalDefaultsKey) as? Int
        autoRefreshInterval = AutoRefreshInterval(rawValue: storedInterval ?? AutoRefreshInterval.adaptive.rawValue) ?? .adaptive
        state = .loading
        configureRefreshTimer()
        let generation = refreshGeneration
        Task { [weak self] in
            guard let self else { return }
            await self.loadStoredCredentials(generation: generation)
            guard self.refreshGeneration == generation, self.hasCredentials else { return }
            await self.loadKeys()
            await self.refresh()
        }
    }

    var hasCredentials: Bool { credentials != nil }

    var savedUsername: String { credentials?.username ?? "" }
    var savedPassword: String { credentials?.password ?? "" }

    func saveSettings(gatewayURL input: String, username: String, password: String) throws {
        guard let newGatewayURL = GatewayClient.baseURL(from: input) else {
            throw GatewayError.invalidGatewayURL
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else { throw KeychainError(errSecParam) }
        try keychain.saveCredentials(username: trimmedUsername, password: password)
        refreshGeneration += 1
        UserDefaults.standard.set(newGatewayURL.absoluteString, forKey: gatewayURLDefaultsKey)
        gatewayURL = newGatewayURL
        client = GatewayClient(baseURL: newGatewayURL)
        credentials = (trimmedUsername, password)
        session = nil
        availableKeys = []
        keyListMessage = nil
        monthlyChartState = .loading
        lastSpendSample = nil
        smoothedSpendPerDay = nil
        state = .loading
        configureRefreshTimer()
        Task {
            if isRefreshing {
                queueRefresh(reloadKeys: true)
                return
            }
            await loadKeys()
            await refresh()
        }
    }

    func setAutoRefreshInterval(_ interval: AutoRefreshInterval) {
        guard autoRefreshInterval != interval else { return }
        autoRefreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: refreshIntervalDefaultsKey)
        configureRefreshTimer()
    }

    func refresh() async {
        guard let credentials else { return }
        guard !isRefreshing else {
            queueRefresh()
            return
        }
        isRefreshing = true
        queuedRefresh = false
        let generation = refreshGeneration
        let currentClient = client
        let selectedKeyHash = self.selectedKeyHash
        let currentKeys = availableKeys
        defer {
            isRefreshing = false
            scheduleNextRefresh()
            if queuedRefresh {
                let reloadKeys = queuedKeyReload
                queuedRefresh = false
                queuedKeyReload = false
                Task { [weak self] in
                    guard let self else { return }
                    if reloadKeys { await self.loadKeys() }
                    await self.refresh()
                }
            }
        }
        do {
            let loaded: (auth: AuthSession, scopedBudget: ScopedBudget)
            do {
                let auth = try await authenticatedSession(
                    client: currentClient,
                    credentials: credentials,
                    generation: generation
                )
                guard generation == refreshGeneration else {
                    queueRefresh()
                    return
                }
                let scopedBudget = try await fetchCurrentBudget(
                    apiKey: auth.apiKey,
                    client: currentClient,
                    selectedKeyHash: selectedKeyHash,
                    availableKeys: currentKeys
                )
                loaded = (auth, scopedBudget)
            } catch GatewayError.unauthorized {
                guard generation == refreshGeneration else {
                    queueRefresh()
                    return
                }
                session = nil
                let auth = try await authenticatedSession(
                    client: currentClient,
                    credentials: credentials,
                    generation: generation
                )
                guard generation == refreshGeneration else {
                    queueRefresh()
                    return
                }
                let scopedBudget = try await fetchCurrentBudget(
                    apiKey: auth.apiKey,
                    client: currentClient,
                    selectedKeyHash: selectedKeyHash,
                    availableKeys: currentKeys
                )
                loaded = (auth, scopedBudget)
            }
            guard generation == refreshGeneration else {
                queueRefresh()
                return
            }
            let auth = loaded.auth
            let scopedBudget = loaded.scopedBudget
            if let fetchedKeys = scopedBudget.fetchedKeys { availableKeys = fetchedKeys }
            if let selectedKey = scopedBudget.selectedKey {
                self.selectedKeyHash = selectedKey.value
                UserDefaults.standard.set(selectedKey.value, forKey: selectedKeyDefaultsKey)
                UserDefaults.standard.removeObject(forKey: legacySelectedKeyDefaultsKey)
            } else if selectedKeyHash != nil {
                self.selectedKeyHash = nil
                UserDefaults.standard.removeObject(forKey: selectedKeyDefaultsKey)
                UserDefaults.standard.removeObject(forKey: legacySelectedKeyDefaultsKey)
            }
            let budget = scopedBudget.budget
            guard let limit = budget.maxBudget, limit > 0 else { throw GatewayError.noUserBudget }
            guard let duration = budget.budgetDuration, isMonthly(duration) else {
                throw GatewayError.notMonthlyBudget(budget.budgetDuration ?? "없음")
            }
            let now = Date()
            updateSpendRate(spend: budget.spend, at: now)
            state = .ready(UsageSnapshot(
                spend: budget.spend,
                limit: limit,
                percentage: max(0, budget.spend / limit * 100),
                budgetDuration: duration,
                resetAt: budget.budgetResetAt
            ))
            lastUpdated = now
            let chartState = await monthlyUsageLoader.load(
                client: currentClient,
                request: MonthlyUsageRequest(
                    apiKey: auth.apiKey,
                    selectedKey: scopedBudget.selectedKey?.value,
                    limit: limit,
                    now: now
                )
            )
            guard generation == refreshGeneration else {
                queueRefresh()
                return
            }
            monthlyChartState = chartState
        } catch let error as GatewayError {
            guard generation == refreshGeneration else {
                queueRefresh()
                return
            }
            state = .failure(error.localizedDescription)
            monthlyChartState = .unavailable(error.localizedDescription)
        } catch {
            guard generation == refreshGeneration else {
                queueRefresh()
                return
            }
            state = .failure("게이트웨이에 연결할 수 없습니다")
            monthlyChartState = .unavailable(error.localizedDescription)
        }
    }

    func loadKeys() async {
        guard hasCredentials, availableKeys.isEmpty else { return }
        guard !isLoadingKeys else {
            queuedKeyReload = true
            return
        }
        guard let credentials else { return }
        let generation = refreshGeneration
        let currentClient = client
        isLoadingKeys = true
        keyListMessage = nil
        defer {
            isLoadingKeys = false
            if queuedKeyReload {
                queuedKeyReload = false
                Task { [weak self] in await self?.loadKeys() }
            }
        }
        do {
            let auth: AuthSession
            do {
                auth = try await authenticatedSession(
                    client: currentClient,
                    credentials: credentials,
                    generation: generation
                )
            } catch GatewayError.unauthorized {
                guard generation == refreshGeneration else { return }
                session = nil
                auth = try await authenticatedSession(
                    client: currentClient,
                    credentials: credentials,
                    generation: generation
                )
            }
            guard generation == refreshGeneration else { return }
            let keys = try await fetchKeyOptions(apiKey: auth.apiKey, client: currentClient)
            guard generation == refreshGeneration else { return }
            availableKeys = keys
            if let selectedKeyHash {
                if let selectedKey = keys.first(where: { $0.value == selectedKeyHash })
                    ?? keys.first(where: { $0.keyName == selectedKeyHash }) {
                    self.selectedKeyHash = selectedKey.value
                    UserDefaults.standard.set(selectedKey.value, forKey: selectedKeyDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: legacySelectedKeyDefaultsKey)
                } else {
                    self.selectedKeyHash = nil
                    UserDefaults.standard.removeObject(forKey: selectedKeyDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: legacySelectedKeyDefaultsKey)
                    refreshGeneration += 1
                    if isRefreshing { queueRefresh() }
                }
            }
        } catch let error as GatewayError {
            guard generation == refreshGeneration else { return }
            keyListMessage = error.localizedDescription
        } catch {
            guard generation == refreshGeneration else { return }
            keyListMessage = "키 목록을 불러올 수 없습니다"
        }
    }

    func selectKey(withHash keyHash: String?) {
        guard selectedKeyHash != keyHash else { return }
        refreshGeneration += 1
        selectedKeyHash = keyHash
        lastSpendSample = nil
        smoothedSpendPerDay = nil
        monthlyChartState = .loading
        state = .loading
        if let keyHash {
            UserDefaults.standard.set(keyHash, forKey: selectedKeyDefaultsKey)
            UserDefaults.standard.removeObject(forKey: legacySelectedKeyDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedKeyDefaultsKey)
            UserDefaults.standard.removeObject(forKey: legacySelectedKeyDefaultsKey)
        }
        Task { await refresh() }
    }

    private func configureRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        scheduleNextRefresh()
    }

    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        guard hasCredentials, let delay = nextRefreshDelay() else {
            refreshTimer = nil
            return
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    private func nextRefreshDelay() -> TimeInterval? {
        switch autoRefreshInterval {
        case .off:
            return nil
        case .adaptive:
            guard case let .ready(snapshot) = state else { return 900 }
            return adaptiveRefreshDelay(for: snapshot)
        case .oneMinute, .fiveMinutes, .fifteenMinutes, .thirtyMinutes, .oneHour:
            return autoRefreshInterval.fixedSeconds
        }
    }

    private func adaptiveRefreshDelay(for snapshot: UsageSnapshot) -> TimeInterval {
        if snapshot.percentage >= 100 {
            guard let resetAt = snapshot.resetAt else { return 86_400 }
            return min(86_400, max(60, resetAt.timeIntervalSinceNow - 60))
        }

        let remaining = max(0, snapshot.limit - snapshot.spend)
        if let smoothedSpendPerDay, smoothedSpendPerDay > 0 {
            let secondsUntilLimit = remaining / smoothedSpendPerDay * 86_400
            if secondsUntilLimit <= 6 * 3_600 { return 60 }
            if secondsUntilLimit <= 24 * 3_600 { return 300 }
            if secondsUntilLimit <= 3 * 86_400 { return 900 }
        }

        if snapshot.percentage >= 95 { return 300 }
        if snapshot.percentage >= 80 { return 900 }
        if snapshot.percentage >= 50 { return 3_600 }
        return 14_400
    }

    private func updateSpendRate(spend: Double, at date: Date) {
        if let lastSpendSample {
            let elapsed = date.timeIntervalSince(lastSpendSample.date)
            if elapsed > 0 {
                let spendDelta = spend - lastSpendSample.spend
                if spendDelta < 0 {
                    smoothedSpendPerDay = nil
                } else {
                    let spendPerDay = spendDelta / elapsed * 86_400
                    smoothedSpendPerDay = smoothedSpendPerDay.map { $0 * 0.7 + spendPerDay * 0.3 } ?? spendPerDay
                }
            }
        }
        lastSpendSample = SpendSample(spend: spend, date: date)
    }

    private struct SpendSample {
        let spend: Double
        let date: Date
    }

    private func loadStoredCredentials(generation: Int) async {
        do {
            let stored = try await keychain.readCredentials()
            guard generation == refreshGeneration else { return }
            credentials = stored
            state = stored == nil ? .needsKey : .loading
            configureRefreshTimer()
        } catch {
            guard generation == refreshGeneration else { return }
            state = .failure(error.localizedDescription)
        }
    }

    private func authenticatedSession(
        client: GatewayClient,
        credentials: (username: String, password: String),
        generation: Int
    ) async throws -> AuthSession {
        if let session, session.expiresAt.timeIntervalSinceNow > 300 { return session }
        let refreshed = try await client.login(username: credentials.username, password: credentials.password)
        if generation == refreshGeneration { session = refreshed }
        return refreshed
    }

    private func fetchBudget(apiKey: String, client: GatewayClient) async throws -> TeamBudget {
        let userInfo = try await client.fetchUserInfo(apiKey: apiKey)
        if userInfo.maxBudget != nil {
            return TeamBudget(
                spend: userInfo.spend,
                maxBudget: userInfo.maxBudget,
                budgetDuration: userInfo.budgetDuration,
                budgetResetAt: userInfo.budgetResetAt
            )
        }
        guard let teamID = userInfo.teams.first else { throw GatewayError.noUserBudget }
        return try await client.fetchTeamInfo(apiKey: apiKey, teamID: teamID)
    }

    private struct ScopedBudget {
        let budget: TeamBudget
        let selectedKey: GatewayKey?
        let fetchedKeys: [GatewayKey]?
    }

    private func fetchCurrentBudget(
        apiKey: String,
        client: GatewayClient,
        selectedKeyHash: String?,
        availableKeys: [GatewayKey]
    ) async throws -> ScopedBudget {
        guard let selectedKeyHash else {
            return ScopedBudget(budget: try await fetchBudget(apiKey: apiKey, client: client), selectedKey: nil, fetchedKeys: nil)
        }

        let keys = availableKeys.isEmpty ? try await fetchKeyOptions(apiKey: apiKey, client: client) : availableKeys
        let fetchedKeys = availableKeys.isEmpty ? keys : nil
        guard let selectedKey = keys.first(where: { $0.value == selectedKeyHash })
            ?? keys.first(where: { $0.keyName == selectedKeyHash }) else {
            return ScopedBudget(
                budget: try await fetchBudget(apiKey: apiKey, client: client),
                selectedKey: nil,
                fetchedKeys: fetchedKeys
            )
        }

        let keyInfo = try await client.fetchKeyInfo(apiKey: apiKey, key: selectedKey.value)
        if let maxBudget = keyInfo.maxBudget {
            return ScopedBudget(
                budget: TeamBudget(
                    spend: keyInfo.spend,
                    maxBudget: maxBudget,
                    budgetDuration: keyInfo.budgetDuration,
                    budgetResetAt: keyInfo.budgetResetAt
                ),
                selectedKey: selectedKey,
                fetchedKeys: fetchedKeys
            )
        }
        guard let teamID = keyInfo.teamID else { throw GatewayError.noUserBudget }
        let teamBudget = try await client.fetchTeamInfo(apiKey: apiKey, teamID: teamID)
        return ScopedBudget(
            budget: TeamBudget(
                spend: keyInfo.spend,
                maxBudget: teamBudget.maxBudget,
                budgetDuration: teamBudget.budgetDuration,
                budgetResetAt: teamBudget.budgetResetAt
            ),
            selectedKey: selectedKey,
            fetchedKeys: fetchedKeys
        )
    }

    private func fetchKeyOptions(apiKey: String, client: GatewayClient) async throws -> [GatewayKey] {
        let keys = try await client.fetchKeyList(apiKey: apiKey)
        var options: [GatewayKey] = []
        for key in keys {
            let info = try await client.fetchKeyInfo(apiKey: apiKey, key: key)
            options.append(GatewayKey(value: key, keyName: info.keyName, alias: info.keyAlias))
        }
        return options
    }

    private func queueRefresh(reloadKeys: Bool = false) {
        queuedRefresh = true
        queuedKeyReload = queuedKeyReload || reloadKeys
    }

    private func isMonthly(_ duration: String) -> Bool {
        let normalized = duration.lowercased()
        return ["1mo", "1month", "30d", "monthly"].contains(normalized)
    }

    private static func loadGatewayURL() -> URL {
        guard let savedURL = UserDefaults.standard.string(forKey: "gateway-url"),
              let gatewayURL = GatewayClient.baseURL(from: savedURL) else {
            return GatewayClient.defaultBaseURL
        }
        return gatewayURL
    }

}
