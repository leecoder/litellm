import CryptoKit
import Foundation

struct DailyActivityQuery: Sendable {
    let apiKey: String
    let selectedKey: String?
    let startDate: String
    let endDate: String
    let timezone: Int
}

struct DailySpendActivityResponse: Decodable, Sendable {
    let results: [DailySpendActivityDay]
    let metadata: DailySpendActivityMetadata
}

struct DailySpendActivityDay: Decodable, Sendable {
    let date: String
    let metrics: DailySpendMetrics
}

struct DailySpendMetrics: Decodable, Sendable {
    let spend: Double
}

struct DailySpendActivityMetadata: Decodable, Sendable {
    let totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case totalPages = "total_pages"
    }
}

struct MonthlyUsagePoint: Identifiable, Equatable, Sendable {
    let date: Date
    let cumulativeSpend: Double

    var id: Date { date }
}

struct MonthlyUsageChartData: Equatable, Sendable {
    let actualPoints: [MonthlyUsagePoint]
    let forecastPoints: [MonthlyUsagePoint]
    let limit: Double
    let monthToDateSpend: Double
    let estimatedMonthEndSpend: Double
    let monthStart: Date
    let monthEnd: Date
    let axisDates: [Date]

    init?(activity: DailySpendActivityResponse, limit: Double, now: Date, calendar: Calendar = .current) {
        let monthComponents = calendar.dateComponents([.year, .month], from: now)
        guard let monthStart = calendar.date(from: monthComponents),
              let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count,
              let monthEnd = calendar.date(byAdding: .day, value: daysInMonth - 1, to: monthStart) else { return nil }

        let dailySpend = Dictionary(grouping: activity.results, by: \.date)
            .mapValues { $0.reduce(0) { $0 + $1.metrics.spend } }
        let currentDay = calendar.component(.day, from: now)
        var cumulativeSpend = 0.0
        let actualPoints = (1...currentDay).compactMap { day -> MonthlyUsagePoint? in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }
            cumulativeSpend += dailySpend[Self.dateString(date, calendar: calendar), default: 0]
            return MonthlyUsagePoint(date: date, cumulativeSpend: cumulativeSpend)
        }
        guard let currentPoint = actualPoints.last else { return nil }

        let estimatedMonthEndSpend = currentPoint.cumulativeSpend / Double(currentDay) * Double(daysInMonth)
        self.actualPoints = actualPoints
        forecastPoints = [
            currentPoint,
            MonthlyUsagePoint(date: monthEnd, cumulativeSpend: estimatedMonthEndSpend),
        ]
        self.limit = limit
        monthToDateSpend = currentPoint.cumulativeSpend
        self.estimatedMonthEndSpend = estimatedMonthEndSpend
        self.monthStart = monthStart
        self.monthEnd = monthEnd
        axisDates = [1, 8, 15, 22].compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: monthStart)
        }
    }

    var upperBound: Double {
        max(limit, monthToDateSpend, estimatedMonthEndSpend) * 1.12
    }

    private static func dateString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

enum MonthlyUsageChartState: Equatable, Sendable {
    case loading
    case ready(MonthlyUsageChartData)
    case unavailable(String)
}

struct MonthlyUsageRequest: Sendable {
    let apiKey: String
    let selectedKey: String?
    let limit: Double
    let now: Date
}

struct MonthlyUsageLoader {
    func load(client: GatewayClient, request: MonthlyUsageRequest) async -> MonthlyUsageChartState {
        let calendar = Calendar.current
        let monthComponents = calendar.dateComponents([.year, .month], from: request.now)
        guard let monthStart = calendar.date(from: monthComponents) else {
            return .unavailable("이번 달 시작 날짜를 계산할 수 없습니다")
        }
        let timezone = -TimeZone.current.secondsFromGMT() / 60
        let query = DailyActivityQuery(
            apiKey: request.apiKey,
            selectedKey: request.selectedKey,
            startDate: dateString(monthStart, calendar: calendar),
            endDate: dateString(request.now, calendar: calendar),
            timezone: timezone
        )

        do {
            let activity = try await client.fetchDailyActivity(query)
            guard let chartData = MonthlyUsageChartData(
                activity: activity,
                limit: request.limit,
                now: request.now,
                calendar: calendar
            ) else { return .unavailable("월간 사용량을 계산할 수 없습니다") }
            return .ready(chartData)
        } catch let error as GatewayError {
            return .unavailable(error.localizedDescription)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func dateString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

extension GatewayClient {
    func fetchDailyActivity(_ query: DailyActivityQuery) async throws -> DailySpendActivityResponse {
        let teamID: String?
        if query.selectedKey == nil {
            let userInfo = try await fetchUserInfo(apiKey: query.apiKey)
            teamID = userInfo.maxBudget == nil ? userInfo.teams.first : nil
        } else {
            teamID = nil
        }
        let path = teamID == nil ? "/user/daily/activity/aggregated" : "/team/daily/activity/aggregated"
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw GatewayError.invalidResponse
        }
        var queryItems = [
            URLQueryItem(name: "start_date", value: query.startDate),
            URLQueryItem(name: "end_date", value: query.endDate),
            URLQueryItem(name: "timezone", value: String(query.timezone)),
        ]
        if let selectedKey = query.selectedKey {
            let keyHash = SHA256.hash(data: Data(selectedKey.utf8)).map { String(format: "%02x", $0) }.joined()
            queryItems.append(URLQueryItem(name: "api_key", value: keyHash))
            queryItems.append(URLQueryItem(name: "include_current_utc_day", value: "true"))
        } else if let teamID {
            queryItems.append(URLQueryItem(name: "team_ids", value: teamID))
        } else {
            queryItems.append(URLQueryItem(name: "include_current_utc_day", value: "true"))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw GatewayError.invalidResponse }
        do {
            return try await fetchDailyActivity(url: url, apiKey: query.apiKey)
        } catch GatewayError.notFound {
            let paginatedPath = path.replacingOccurrences(of: "/aggregated", with: "")
            return try await fetchPaginatedDailyActivity(
                path: paginatedPath,
                queryItems: queryItems,
                apiKey: query.apiKey
            )
        }
    }

    private func fetchDailyActivity(url: URL, apiKey: String) async throws -> DailySpendActivityResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw GatewayError.invalidResponse }
        switch httpResponse.statusCode {
        case 200...299: break
        case 401: throw GatewayError.unauthorized
        case 403: throw GatewayError.forbidden
        case 404: throw GatewayError.notFound
        default: throw GatewayError.server(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(DailySpendActivityResponse.self, from: data)
    }

    private func fetchPaginatedDailyActivity(
        path: String,
        queryItems: [URLQueryItem],
        apiKey: String
    ) async throws -> DailySpendActivityResponse {
        func fetchPage(_ page: Int) async throws -> DailySpendActivityResponse {
            guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
                throw GatewayError.invalidResponse
            }
            components.queryItems = queryItems + [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: "1000"),
            ]
            guard let url = components.url else { throw GatewayError.invalidResponse }
            return try await fetchDailyActivity(url: url, apiKey: apiKey)
        }

        let firstPage = try await fetchPage(1)
        guard let totalPages = firstPage.metadata.totalPages, totalPages > 1 else { return firstPage }
        var results = firstPage.results
        for page in 2...totalPages {
            results.append(contentsOf: try await fetchPage(page).results)
        }
        return DailySpendActivityResponse(results: results, metadata: firstPage.metadata)
    }
}
