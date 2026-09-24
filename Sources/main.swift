import Cocoa
import ServiceManagement

// ClaudeUsage — claude.ai の「設定 > 使用量」と同じレート制限の消費率を
// macOS のメニューバーに常時表示する常駐アプリ。
//
// データ源は 2 つある。
//
//   1) ~/.claude/usage-snapshot.json
//      Claude Code の statusline (~/.claude/statusline.sh) が毎レンダリング時に
//      書き出すサイドカー。Claude Code が statusline に渡す rate_limits は
//      サーバー側の値で、claude.ai の使用量ページと同じものを指す。
//      したがって Claude Code のセッションが動いているときだけ更新される
//      （claude.ai の Web で消費した分も、次にセッションが一言動けば反映される）。
//
//   2) ccusage (npx 経由) の `claude daily --breakdown`
//      ~/.claude/projects/**/*.jsonl のローカルログを集計したモデル別の
//      トークン数と料金。レート制限側にはモデル別の枠が無い（five_hour /
//      seven_day などアカウント単位の枠しか降ってこない）ため、
//      「どのモデルをどれだけ使ったか」はこちらで補う。

// MARK: - 設定

enum Config {
    static let snapshotPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".claude/usage-snapshot.json")
    /// スナップショットの mtime を見る間隔。読むのは変化したときだけ。
    static let snapshotPollInterval: TimeInterval = 2
    /// この時間更新が無ければ「Claude Code が動いていない」とみなし淡色表示にする。
    static let staleThreshold: TimeInterval = 15 * 60
    /// ccusage は CPU を数秒使うため、この間隔でしか回さない。
    static let breakdownTTL: TimeInterval = 5 * 60
    /// npx のレジストリ解決を避けるためバージョンを固定する（statusline.sh と揃える）。
    static let ccusageSpec = "ccusage@20.0.20"
    static let ccusageTimeout: TimeInterval = 120
    static let usagePageURL = URL(string: "https://claude.ai/settings/usage")!
    static let rowWidth: CGFloat = 330
}

// MARK: - データモデル

/// rate_limits の 1 枠分。
///
/// キーはプランや状況で増減する（five_hour / seven_day / seven_day_opus /
/// spend_limit …）ため、キー名を決め打ちせずスナップショットにあったものを
/// そのまま保持し、未知のキーも落とさず表示する。
struct RateLimitWindow {
    let key: String
    let usedPercentage: Double
    let resetsAt: Date?

    /// メニュー内に出す表示名。未知のキーは snake_case を読める形に整える。
    var displayName: String {
        switch key {
        case "five_hour": return "5 時間枠"
        case "seven_day": return "7 日枠（全体）"
        case "seven_day_opus": return "7 日枠（Opus）"
        case "spend_limit": return "支出上限"
        default:
            return key.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    /// メニューバーに出す短縮名。
    var shortName: String {
        switch key {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        case "seven_day_opus": return "Opus"
        case "spend_limit": return "支出"
        default: return key
        }
    }

    /// 既知の枠を既知の順に並べ、未知のキーは末尾へ回す。
    var sortOrder: Int {
        switch key {
        case "five_hour": return 0
        case "seven_day": return 1
        case "seven_day_opus": return 2
        case "spend_limit": return 3
        default: return 4
        }
    }

    /// メニューバーに載せる枠かどうか。支出上限や未知の枠はメニュー内だけに出し、
    /// メニューバーが横に伸び続けるのを防ぐ。
    var showsInStatusBar: Bool {
        key == "five_hour" || key == "seven_day" || key == "seven_day_opus"
    }
}

/// statusline が書き出したサイドカーの中身。
struct Snapshot {
    let updatedAt: Date
    let model: String?
    let sessionCostUSD: Double?
    let windows: [RateLimitWindow]

    var isStale: Bool { Date().timeIntervalSince(updatedAt) > Config.staleThreshold }

    static func load(from path: String) -> Snapshot? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let updatedAt = (root["updated_at"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        let rawLimits = root["rate_limits"] as? [String: Any] ?? [:]

        var windows: [RateLimitWindow] = []
        for (key, raw) in rawLimits {
            guard let dict = raw as? [String: Any],
                  let pct = (dict["used_percentage"] as? NSNumber)?.doubleValue
            else { continue }
            let resets = (dict["resets_at"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(RateLimitWindow(key: key, usedPercentage: pct, resetsAt: resets))
        }
        windows.sort { ($0.sortOrder, $0.key) < ($1.sortOrder, $1.key) }

        return Snapshot(
            updatedAt: updatedAt,
            model: root["model"] as? String,
            sessionCostUSD: (root["session_cost_usd"] as? NSNumber)?.doubleValue,
            windows: windows
        )
    }
}

/// ccusage が返すモデル 1 つ分の集計。
struct ModelUsage {
    let modelName: String
    let cost: Double
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int

    /// claude-opus-5 → Opus 5、claude-fable-5-1 → Fable 5.1、
    /// claude-haiku-4-5-20251001 → Haiku 4.5 のように読みやすい形へ整える。
    var displayName: String {
        var name = modelName
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        var parts = name.split(separator: "-").map(String.init)
        // 末尾に付く 8 桁のリリース日付は表示に不要なので落とす。
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return modelName }
        let version = parts.dropFirst().joined(separator: ".")
        let capitalized = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? capitalized : "\(capitalized) \(version)"
    }
}

/// ccusage による今日のモデル別集計。
struct Breakdown {
    let models: [ModelUsage]
    let totalCost: Double
    let fetchedAt: Date
}

// MARK: - 書式

enum Format {
    /// 599521 → 600k、253284264 → 253M のように桁を落として読ませる。
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:
            return String(format: "%.0fk", Double(n) / 1_000)
        default:
            return "\(n)"
        }
    }

    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

    /// リセットまでの残り時間。
    static func remaining(until date: Date) -> String {
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 0 { return "まもなくリセット" }
        let days = secs / 86400
        let hours = (secs % 86400) / 3600
        let mins = (secs % 3600) / 60
        if days > 0 { return "あと \(days) 日 \(hours) 時間" }
        if hours > 0 { return "あと \(hours) 時間 \(mins) 分" }
        return "あと \(mins) 分"
    }

    /// リセット時刻。今日中なら時刻だけ、日をまたぐなら日付も添える。
    static func resetClock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }

    /// 最終更新からの経過。
    static func elapsed(since date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(max(secs, 0)) 秒前" }
        if secs < 3600 { return "\(secs / 60) 分前" }
        if secs < 86400 { return "\(secs / 3600) 時間前" }
        return "\(secs / 86400) 日前"
    }

    /// メニュー内のバーと％の色。淡色表示のときは情報が古いので色を出さない。
    static func color(for pct: Double, stale: Bool) -> NSColor {
        if stale { return .tertiaryLabelColor }
        if pct >= 80 { return .systemRed }
        if pct >= 50 { return .systemOrange }
        return .controlAccentColor
    }

    /// メニューバーの数字の色。
    ///
    /// メニューバーは壁紙が透けるため彩度のある色が沈む。余裕があるうちは
    /// OS 標準の文字色（ライト / ダークで自動反転する）に任せて確実に読めるようにし、
    /// 注意が要る水準に達したときだけ色を出して目を引かせる。
    static func statusBarColor(for pct: Double, stale: Bool) -> NSColor {
        if stale { return .tertiaryLabelColor }
        if pct >= 80 { return .systemRed }
        if pct >= 50 { return .systemOrange }
        return .labelColor
    }
}

// MARK: - メニュー内のカスタム行

/// レート制限 1 枠分の行（枠名・％・進捗バー・リセット時刻）。
final class RateLimitRowView: NSView {
    private let limit: RateLimitWindow
    private let stale: Bool

    init(limit: RateLimitWindow, stale: Bool) {
        self.limit = limit
        self.stale = stale
        super.init(frame: NSRect(x: 0, y: 0, width: Config.rowWidth, height: 50))
    }

    required init?(coder: NSCoder) { fatalError("未使用") }

    override func draw(_ dirtyRect: NSRect) {
        let left: CGFloat = 20
        let right = bounds.width - 16
        let barWidth = right - left
        let accent = Format.color(for: limit.usedPercentage, stale: stale)
        let primary: NSColor = stale ? .tertiaryLabelColor : .labelColor
        let secondary: NSColor = stale ? .quaternaryLabelColor : .secondaryLabelColor

        // 枠名（左）
        let name = NSAttributedString(string: limit.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: primary,
        ])
        name.draw(at: NSPoint(x: left, y: bounds.height - 20))

        // ％（右寄せ）
        let pct = NSAttributedString(string: "\(Int(limit.usedPercentage.rounded()))%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: accent,
        ])
        pct.draw(at: NSPoint(x: right - pct.size().width, y: bounds.height - 20))

        // 進捗バー。角丸でクリップしてから、溝 → 使用量の順に塗る。
        let barRect = NSRect(x: left, y: 18, width: barWidth, height: 6)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3).setClip()
        NSColor.quaternaryLabelColor.setFill()
        barRect.fill()
        let ratio = min(max(limit.usedPercentage / 100, 0), 1)
        if ratio > 0 {
            accent.setFill()
            NSRect(x: left, y: 18, width: max(barWidth * ratio, 3), height: 6).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // リセット情報
        if let resets = limit.resetsAt {
            let text = "\(Format.remaining(until: resets))でリセット（\(Format.resetClock(resets))）"
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: secondary,
            ]).draw(at: NSPoint(x: left, y: 2))
        }
    }
}

/// モデル 1 つ分の行（モデル名・料金・トークン内訳）。
final class ModelRowView: NSView {
    private let usage: ModelUsage

    init(usage: ModelUsage) {
        self.usage = usage
        super.init(frame: NSRect(x: 0, y: 0, width: Config.rowWidth, height: 34))
    }

    required init?(coder: NSCoder) { fatalError("未使用") }

    override func draw(_ dirtyRect: NSRect) {
        let left: CGFloat = 20
        let right = bounds.width - 16

        let name = NSAttributedString(string: usage.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        name.draw(at: NSPoint(x: left, y: bounds.height - 18))

        let cost = NSAttributedString(string: Format.usd(usage.cost), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        cost.draw(at: NSPoint(x: right - cost.size().width, y: bounds.height - 18))

        let detail = "出力 \(Format.tokens(usage.outputTokens))"
            + " · 入力 \(Format.tokens(usage.inputTokens))"
            + " · キャッシュ読 \(Format.tokens(usage.cacheReadTokens))"
        NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(at: NSPoint(x: left, y: 2))
    }
}

// MARK: - ccusage 呼び出し

/// ローカルログのモデル別集計を ccusage から取る。
///
/// ccusage は数秒 CPU を使うため常にバックグラウンドで、nice を付けて回す。
enum CCUsage {
    static func fetchTodayBreakdown(completion: @escaping (Breakdown?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = run()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func run() -> Breakdown? {
        let today = DateFormatter()
        today.dateFormat = "yyyyMMdd"
        let day = today.string(from: Date())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "nice -n 19 npx -y --prefer-offline \(Config.ccusageSpec)"
                + " claude daily --json --breakdown -s \(day)",
        ]
        // Finder から起動されたアプリは PATH が最小限になるため、
        // Homebrew / Node の一般的な場所を明示的に足す。
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // 読み切ってから待つ（パイプが詰まって双方待ちになるのを避ける）。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        // 想定外に長引いたら諦めて殺す。
        let deadline = Date().addingTimeInterval(Config.ccusageTimeout)
        while process.isRunning && Date() < deadline { usleep(100_000) }
        if process.isRunning { process.terminate() }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let daily = root["daily"] as? [[String: Any]],
              let entry = daily.first
        else { return nil }

        let breakdowns = entry["modelBreakdowns"] as? [[String: Any]] ?? []
        let models: [ModelUsage] = breakdowns.compactMap { item in
            guard let name = item["modelName"] as? String else { return nil }
            func num(_ key: String) -> Double {
                (item[key] as? NSNumber)?.doubleValue ?? 0
            }
            return ModelUsage(
                modelName: name,
                cost: num("cost"),
                inputTokens: Int(num("inputTokens")),
                outputTokens: Int(num("outputTokens")),
                cacheCreationTokens: Int(num("cacheCreationTokens")),
                cacheReadTokens: Int(num("cacheReadTokens"))
            )
        }.sorted { $0.cost > $1.cost }

        let total = (entry["totalCost"] as? NSNumber)?.doubleValue
            ?? models.reduce(0) { $0 + $1.cost }

        return Breakdown(models: models, totalCost: total, fetchedAt: Date())
    }
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var snapshot: Snapshot?
    private var breakdown: Breakdown?
    private var breakdownFailed = false
    private var isFetchingBreakdown = false

    private var lastSnapshotMtime: Date?
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        if let icon = NSImage(systemSymbolName: "gauge.with.needle",
                              accessibilityDescription: "Claude 使用量") {
            icon.isTemplate = true
            statusItem.button?.image = icon
        }
        menu.delegate = self
        statusItem.menu = menu

        reloadSnapshot(force: true)
        refreshBreakdown(force: true)

        pollTimer = Timer.scheduledTimer(withTimeInterval: Config.snapshotPollInterval,
                                         repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: 更新

    /// スナップショットの mtime を見て、変化していたときだけ読み直す。
    private func tick() {
        reloadSnapshot(force: false)
        if let fetched = breakdown?.fetchedAt,
           Date().timeIntervalSince(fetched) > Config.breakdownTTL {
            refreshBreakdown(force: false)
        }
        // 残り時間やバッジの淡色化は時間で変わるため、毎回描き直す。
        updateStatusTitle()
    }

    private func reloadSnapshot(force: Bool) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Config.snapshotPath)
        let mtime = attrs?[.modificationDate] as? Date
        if !force, mtime == lastSnapshotMtime { return }
        lastSnapshotMtime = mtime
        snapshot = Snapshot.load(from: Config.snapshotPath)
        updateStatusTitle()
    }

    private func refreshBreakdown(force: Bool) {
        if isFetchingBreakdown { return }
        if !force, let fetched = breakdown?.fetchedAt,
           Date().timeIntervalSince(fetched) <= Config.breakdownTTL { return }
        isFetchingBreakdown = true
        CCUsage.fetchTodayBreakdown { [weak self] result in
            guard let self else { return }
            self.isFetchingBreakdown = false
            if let result {
                self.breakdown = result
                self.breakdownFailed = false
            } else {
                self.breakdownFailed = true
            }
            self.rebuildMenu()
        }
    }

    // MARK: メニューバー

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        guard let snapshot, !snapshot.windows.isEmpty else {
            button.attributedTitle = NSAttributedString(string: " --", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            return
        }

        let stale = snapshot.isStale
        let shown = snapshot.windows.filter(\.showsInStatusBar)
        let title = NSMutableAttributedString()
        for (index, window) in shown.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: " · ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            // 「5h」「7d」のラベル。数字とはウェイトで差を付け、色は
            // OS 標準の文字色に揃えてメニューバー上で沈まないようにする。
            title.append(NSAttributedString(string: "\(window.shortName) ", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: stale ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            ]))
            title.append(NSAttributedString(
                string: "\(Int(window.usedPercentage.rounded()))%",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: Format.statusBarColor(for: window.usedPercentage, stale: stale),
                ]
            ))
        }
        button.attributedTitle = title
    }

    // MARK: メニュー

    func menuWillOpen(_ menu: NSMenu) {
        reloadSnapshot(force: true)
        refreshBreakdown(force: false)
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(sectionHeader("レート制限（claude.ai の使用量と同じ）"))
        if let snapshot, !snapshot.windows.isEmpty {
            for window in snapshot.windows {
                menu.addItem(customItem(RateLimitRowView(limit: window, stale: snapshot.isStale)))
            }
        } else {
            menu.addItem(noteItem("まだ取得できていません"))
            menu.addItem(noteItem("Claude Code のセッションを一度動かしてください"))
        }

        if let snapshot, snapshot.isStale {
            menu.addItem(noteItem("⚠︎ Claude Code が動いていないため古い値の可能性があります"))
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("今日のモデル別使用量（ローカルログ集計）"))
        if let breakdown, !breakdown.models.isEmpty {
            for usage in breakdown.models {
                menu.addItem(customItem(ModelRowView(usage: usage)))
            }
            menu.addItem(totalItem(breakdown.totalCost))
            menu.addItem(noteItem("※ API 料金換算。サブスク枠の消費率とは別物です"))
        } else if breakdownFailed {
            menu.addItem(noteItem("集計を取得できませんでした（npx / ccusage を確認）"))
        } else {
            menu.addItem(noteItem("集計中…"))
        }

        menu.addItem(.separator())
        if let snapshot {
            var status = "最終更新 \(Format.elapsed(since: snapshot.updatedAt))"
            if let model = snapshot.model { status += " · \(model) セッション" }
            menu.addItem(noteItem(status))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("使用量ページを開く", #selector(openUsagePage), key: "u"))
        menu.addItem(actionItem("モデル別集計を更新", #selector(forceRefresh), key: "r"))

        let login = actionItem("ログイン時に起動", #selector(toggleLoginItem), key: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(actionItem("ClaudeUsage を終了", #selector(quit), key: "q"))
    }

    // MARK: メニュー項目の組み立て

    private func sectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func noteItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func totalItem(_ cost: Double) -> NSMenuItem {
        let item = NSMenuItem()
        let text = NSMutableAttributedString(string: "合計  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        text.append(NSAttributedString(string: Format.usd(cost), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        item.attributedTitle = text
        item.isEnabled = false
        return item
    }

    private func customItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: 操作

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(Config.usagePageURL)
    }

    @objc private func forceRefresh() {
        refreshBreakdown(force: true)
        reloadSnapshot(force: true)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "ログイン項目を変更できませんでした"
            alert.informativeText = error.localizedDescription
                + "\n\nシステム設定 > 一般 > ログイン項目 から手動で追加してください。"
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 起動

// ログイン項目の登録はアプリ自身のプロセスからしか行えない（SMAppService の制約）。
// メニューのトグルと同じ操作をコマンドラインからも呼べるようにしておく。
let arguments = CommandLine.arguments
if arguments.contains("--register-login-item")
    || arguments.contains("--unregister-login-item")
    || arguments.contains("--login-item-status") {
    let service = SMAppService.mainApp

    func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "未登録"
        case .enabled: return "有効"
        case .requiresApproval: return "システム設定での承認待ち"
        case .notFound: return "見つからない"
        @unknown default: return "不明(\(status.rawValue))"
        }
    }

    do {
        if arguments.contains("--register-login-item") {
            try service.register()
        } else if arguments.contains("--unregister-login-item") {
            try service.unregister()
        }
        print("ログイン項目: \(describe(service.status))")
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("失敗: \(error.localizedDescription)\n".utf8))
        print("ログイン項目: \(describe(service.status))")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Dock にもアプリスイッチャーにも出さず、メニューバーだけに常駐する。
app.setActivationPolicy(.accessory)
app.run()
