import SwiftUI
import AppKit
import LocalObserverCore

// The shareable profile: a card for one stretch of history, previewed in a sheet and exported as a PNG. Every number on
// it is one the You page shows; nothing is generated. It's the one place the app is allowed to be expressive, and it
// never names a project unless the user turns that on, because the image is meant to be posted.

/// Fixed canvases: landscape for X and LinkedIn, portrait for Instagram and stories.
enum ProfileCardLayout: String, CaseIterable, Identifiable {
    case landscape, portrait

    var id: String { rawValue }
    var size: CGSize { self == .landscape ? CGSize(width: 1200, height: 675) : CGSize(width: 1080, height: 1350) }
    var title: String { self == .landscape ? "Landscape" : "Portrait" }
    var help: String { self == .landscape ? "1200 × 675, for X and LinkedIn" : "1080 × 1350, for Instagram and stories" }
}

/// Colours fixed per appearance, so an exported image looks the same whatever the app is set to. The accent is the top
/// agent's hue: the same family as `AgentKind.tag`, written as fixed values because those colours adapt to appearance.
struct ProfileCardPalette {
    enum Tone { case blue, orange, green, purple, brown, pink, yellow }

    var dark: Bool
    var tone: Tone

    static func forAgent(_ agent: AgentKind?) -> Tone {
        switch agent {
        case .claude: return .orange
        case .codex: return .green
        case .copilot: return .purple
        case .cursor: return .brown
        case .antigravity: return .blue
        case .pi: return .pink
        case .qoder: return .yellow
        case .openCode, nil: return .blue
        }
    }

    private func hex(_ lightHex: UInt32, _ darkHex: UInt32, _ lightAlpha: Double = 1, _ darkAlpha: Double = 1) -> Color {
        let value = dark ? darkHex : lightHex
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255, opacity: dark ? darkAlpha : lightAlpha)
    }

    var bg: Color { hex(0xFFFFFF, 0x191919) }
    var text: Color { hex(0x37352F, 0xFFFFFF, 1, 0.92) }
    var text2: Color { hex(0x787774, 0x9B9B9B) }
    var divider: Color { hex(0x37352F, 0xFFFFFF, 0.1, 0.1) }
    var track: Color { hex(0x37352F, 0xFFFFFF, 0.06, 0.07) }

    var accent: Color {
        switch tone {
        case .blue: return hex(0x2383E2, 0x2383E2)
        case .orange: return hex(0xD9730D, 0xC77D48)
        case .green: return hex(0x448361, 0x529E72)
        case .purple: return hex(0x9065B0, 0x9D68D3)
        case .brown: return hex(0x9F6B53, 0xBA856F)
        case .pink: return hex(0xC14C8A, 0xD15796)
        case .yellow: return hex(0xCB912F, 0xCA9849)
        }
    }

    /// One rhythm cell: empty cells sit on the track, busier ones step up in accent strength.
    func heat(_ requests: Int, of peak: Int) -> Color {
        guard requests > 0 else { return track }
        return accent.opacity(0.16 + 0.84 * (Double(requests) / Double(max(peak, 1))).squareRoot())
    }
}

/// The card's headline numbers, in the order they read.
struct ProfileCardStat: Identifiable {
    var value: String
    var label: String
    var id: String { label }
}

/// One profile on a fixed canvas. `dark` picks the appearance; `showsProject` opts in to the top project's name.
struct ProfileCard: View {
    var profile: PersonalProfile
    var layout: ProfileCardLayout
    var dark: Bool
    var showsProject = false

    private var palette: ProfileCardPalette {
        ProfileCardPalette(dark: dark, tone: ProfileCardPalette.forAgent(profile.providers.first?.agent))
    }
    private var wrappedYear: Int? { ProfileCardFormat.wrappedYear(of: profile.period) }
    private var memberSince: String? { profile.firsts.memberSince.map(ProfileCardFormat.month) }

    /// The numbers that carry the card. Wrapped reads the year instead: requests, best streak, days with agents.
    private var stats: [ProfileCardStat] {
        let requests = ProfileCardStat(value: AgentFormat.compact(Double(profile.totals.tally.requests)), label: "requests")
        if wrappedYear != nil {
            return [requests,
                    ProfileCardStat(value: "\(profile.records.longestStreak?.days ?? 0)", label: "day best streak"),
                    ProfileCardStat(value: "\(profile.totals.activeDays)", label: "active days")]
        }
        // The period's most telling number: a real run of agents at once, else a live streak, else the session count.
        let signature: ProfileCardStat
        if let peak = profile.records.peakConcurrent?.sessions, peak >= 3 {
            signature = ProfileCardStat(value: "\(peak)", label: "agents at once")
        } else if profile.records.currentStreak >= 2 {
            signature = ProfileCardStat(value: "\(profile.records.currentStreak)", label: "day streak")
        } else {
            signature = ProfileCardStat(value: "\(profile.totals.sessions)", label: "sessions")
        }
        return [requests, signature, ProfileCardStat(value: ProfileCardFormat.hours(profile.totals.activeSeconds), label: "with agents")]
    }

    /// What a Wrapped card adds to the year: the biggest day and when Lookout first saw the user.
    private var yearNotes: String {
        var notes: [String] = []
        if let day = profile.records.biggestDayByTokens {
            let date = day.date.formatted(.dateTime.month(.abbreviated).day())
            notes.append("Biggest day \(date), \(AgentFormat.compact(Double(day.tally.processed))) tokens")
        }
        if let memberSince { notes.append("Member since \(memberSince)") }
        return notes.joined(separator: "   ·   ")
    }

    var body: some View {
        ZStack(alignment: .top) {
            palette.bg
            Rectangle().fill(palette.accent).frame(height: 6)
            switch layout {
            case .landscape: landscape
            case .portrait: portrait
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    // MARK: Layouts

    private var landscape: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 80) {
                VStack(alignment: .leading, spacing: 0) {
                    masthead
                    Spacer(minLength: 28)
                    hero(name: 108, tagline: 28, evidence: 20)
                    Spacer(minLength: 36)
                    statRow(size: 52)
                    if wrappedYear != nil {
                        Text(yearNotes).font(.system(size: 16)).foregroundStyle(palette.text2).lineLimit(1).padding(.top, 22)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    agentRow
                    rule(18)
                    modelRow
                    if showsProject, let project = profile.projects.first {
                        rule(18)
                        rank("Top project", title: project.title, share: project.share, agent: nil)
                    }
                    rule(18)
                    rhythm(rowHeight: 20, gap: 5)
                    extras
                }
                .frame(width: 400)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.bottom, 28)
            footer
        }
        .padding(.horizontal, 72)
        .padding(.top, 64)
        .padding(.bottom, 48)
    }

    private var portrait: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            Spacer(minLength: 40)
            hero(name: 128, tagline: 38, evidence: 26)
            Spacer(minLength: 40)
            statRow(size: 72)
            if wrappedYear != nil {
                Text(yearNotes).font(.system(size: 18)).foregroundStyle(palette.text2).lineLimit(2).padding(.top, 22)
            }
            rule(26)
            agentRow
            rule(24)
            modelRow
            if showsProject, let project = profile.projects.first {
                rule(24)
                rank("Top project", title: project.title, share: project.share, agent: nil)
            }
            rule(26)
            rhythm(rowHeight: 26, gap: 5)
            Spacer(minLength: 24)
            footer
        }
        .padding(.horizontal, 84)
        .padding(.top, 72)
        .padding(.bottom, 60)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Pieces

    private var masthead: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(wrappedYear == nil ? "LOOKOUT PROFILE" : "LOOKOUT WRAPPED")
                    .font(.system(size: 13, weight: .semibold)).tracking(1.2).foregroundStyle(palette.text2)
                Text(ProfileCardFormat.period(profile))
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(palette.text)
            }
            Spacer(minLength: 16)
            if let year = wrappedYear {
                Text(String(year)).font(.system(size: 60, weight: .bold)).monospacedDigit().foregroundStyle(palette.accent)
            } else if let memberSince {
                Text("Member since \(memberSince)").font(.system(size: 16)).foregroundStyle(palette.text2)
            }
        }
    }

    /// The archetype as the hero: "The" as a small label over the name, then its tagline and the evidence it rests on.
    private func hero(name size: CGFloat, tagline: CGFloat, evidence: CGFloat) -> some View {
        let match = profile.archetype.primary
        let split = ProfileCardFormat.split(match?.archetype.name ?? "Still learning")
        return VStack(alignment: .leading, spacing: 0) {
            if let lead = split.lead {
                Text(lead.uppercased())
                    .font(.system(size: size * 0.2, weight: .semibold)).tracking(size * 0.03).foregroundStyle(palette.text2)
                    .padding(.bottom, size * 0.04)
            }
            Text(split.name)
                .font(.system(size: size, weight: .bold)).tracking(-size * 0.02)
                .foregroundStyle(palette.text)
                .lineLimit(3).minimumScaleFactor(0.5)
            Text(match?.archetype.tagline ?? "")
                .font(.system(size: tagline)).foregroundStyle(palette.text2)
                .padding(.top, size * 0.16)
            if let sentence = match?.sentence {
                Text(sentence).font(.system(size: evidence)).foregroundStyle(palette.text2).padding(.top, 8)
            }
        }
    }

    private func statRow(size: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 36) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 6) {
                    Text(stat.value)
                        .font(.system(size: size, weight: .semibold)).monospacedDigit().foregroundStyle(palette.text)
                    Text(stat.label).font(.system(size: 16)).foregroundStyle(palette.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var agentRow: some View {
        if let agent = profile.providers.first {
            rank("Top agent", title: agent.title, share: agent.share, agent: agent.agent)
        }
    }

    @ViewBuilder private var modelRow: some View {
        if let model = profile.models.first {
            rank("Top model", title: model.title, share: model.share, agent: model.agent)
        }
    }

    /// A ranked favourite: a small label, its name, and its share of requests. The share is requests, not tokens.
    private func rank(_ label: String, title: String, share: Double, agent: AgentKind?) -> some View {
        HStack(alignment: .center, spacing: 16) {
            if let agent { agentMark(agent) }
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 12, weight: .semibold)).tracking(0.8).foregroundStyle(palette.text2)
                Text(title)
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(palette.text)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ProfileCardFormat.share(share))
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit().foregroundStyle(palette.text)
                Text("of requests").font(.system(size: 13)).foregroundStyle(palette.text2)
            }
        }
    }

    @ViewBuilder private func agentMark(_ agent: AgentKind) -> some View {
        if let image = AgentIcons.image(for: agent) {
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(palette.text)
                .frame(width: 34, height: 34)
        }
    }

    private func rhythm(rowHeight: CGFloat, gap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("RHYTHM").font(.system(size: 12, weight: .semibold)).tracking(0.8).foregroundStyle(palette.text2)
                Spacer(minLength: 8)
                if let hour = profile.rhythm.peakHour {
                    Text("Peak \(ProfileCardFormat.hour(hour))").font(.system(size: 15, weight: .medium)).foregroundStyle(palette.text)
                }
                if let weekday = profile.rhythm.busiestWeekday {
                    Text("· \(Calendar.current.weekdaySymbols[weekday - 1])").font(.system(size: 15)).foregroundStyle(palette.text2)
                }
            }
            ProfileRhythmGrid(rhythm: profile.rhythm, palette: palette, rowHeight: rowHeight, gap: gap)
        }
    }

    /// The landscape column's last strip, under the rhythm: the secondary archetype and, when effort is known for at
    /// least half the requests, the top effort level. Only what the profile can say; nothing is filled in.
    @ViewBuilder private var extras: some View {
        let also = profile.archetype.secondary?.archetype.name
        let effort = profile.effort.coverage >= ProfileArchetypes.effortCoverageNeeded ? profile.effort.levels.first : nil
        if also != nil || effort != nil {
            rule(14)
            HStack(alignment: .top, spacing: 36) {
                if let also {
                    detail("Also", also)
                }
                if let effort {
                    detail("Top effort", ProfileCardFormat.effort(effort.title),
                           caption: "\(ProfileCardFormat.share(effort.share)) of effort-known requests")
                }
            }
        }
    }

    private func detail(_ label: String, _ value: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 12, weight: .semibold)).tracking(0.8).foregroundStyle(palette.text2)
            Text(value)
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(palette.text)
                .lineLimit(1).minimumScaleFactor(0.8)
            if let caption {
                Text(caption).font(.system(size: 13)).foregroundStyle(palette.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "binoculars.fill").font(.system(size: 15))
                Text("Lookout").font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(palette.text)
            Spacer()
            Text("Computed on my Mac, not in the cloud.").font(.system(size: 15)).foregroundStyle(palette.text2)
        }
        .padding(.top, 22)
        .overlay(alignment: .top) { Rectangle().fill(palette.divider).frame(height: 1) }
    }

    private func rule(_ spacing: CGFloat) -> some View {
        Rectangle().fill(palette.divider).frame(height: 1).padding(.vertical, spacing)
    }
}

/// The week-by-hour rhythm as a small grid: weekdays down, hours across, busier cells in deeper accent.
private struct ProfileRhythmGrid: View {
    var rhythm: ProfileRhythm
    var palette: ProfileCardPalette
    var rowHeight: CGFloat
    var gap: CGFloat
    var labelWidth: CGFloat = 16

    var body: some View {
        let rows = rhythm.rows(firstWeekday: Calendar.current.firstWeekday)
        let peak = rhythm.requests.flatMap { $0 }.max() ?? 1
        let symbols = Calendar.current.veryShortWeekdaySymbols
        VStack(alignment: .leading, spacing: gap) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: gap) {
                    Text(symbols[row.weekday - 1])
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text2)
                        .frame(width: labelWidth, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(palette.heat(row.hours[hour], of: peak))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: rowHeight)
            }
            HStack(spacing: gap) {
                Color.clear.frame(width: labelWidth)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? "\(hour)" : "")
                        .font(.system(size: 11)).foregroundStyle(palette.text2)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 14)
        }
    }
}

/// Words for the card and the sheet, so the preview and the export read the same.
enum ProfileCardFormat {
    /// The year a whole-calendar-year period names: the Wrapped card.
    static func wrappedYear(of period: ProfilePeriod, calendar: Calendar = .current) -> Int? {
        guard case .custom(let interval) = period, calendar.dateInterval(of: .year, for: interval.start) == interval else { return nil }
        return calendar.component(.year, from: interval.start)
    }

    /// The span under the masthead: "Oct 5 – 11, 2026 · so far", "October 2026 · so far", "Last 30 days".
    static func period(_ profile: PersonalProfile) -> String {
        let suffix = profile.isPartial ? " · so far" : ""
        if let year = wrappedYear(of: profile.period) { return profile.isPartial ? "Year to date" : "Full year \(year)" }
        switch profile.period {
        case .week: return WeeklyReportFormat.range(profile.interval) + suffix
        case .month: return profile.interval.start.formatted(.dateTime.month(.wide).year()) + suffix
        case .year: return profile.interval.start.formatted(.dateTime.year()) + suffix
        case .lastDays(let days): return "Last \(days) days"
        case .allTime: return "All time"
        case .custom: return WeeklyReportFormat.range(profile.interval)
        }
    }

    /// Picker labels. The current calendar year is offered as "Wrapped", the year-in-review card.
    static func title(_ period: ProfilePeriod) -> String {
        switch period {
        case .week: return "This week"
        case .month: return "This month"
        case .year: return "This year"
        case .lastDays(let days): return "Last \(days) days"
        case .allTime: return "All time"
        case .custom:
            return wrappedYear(of: period).map { "Wrapped \($0)" } ?? "Custom range"
        }
    }

    /// "The Conductor" → ("The", "Conductor"); other names stay whole.
    static func split(_ name: String) -> (lead: String?, name: String) {
        name.hasPrefix("The ") ? ("The", String(name.dropFirst(4))) : (nil, name)
    }

    static func share(_ fraction: Double) -> String { AgentFormat.percent(fraction, digits: 0) }

    /// "xhigh" reads as "Extra high"; the other levels just get a capital.
    static func effort(_ level: String) -> String {
        switch level {
        case "xhigh": return "Extra high"
        case "none": return "Off"
        default: return level.prefix(1).uppercased() + level.dropFirst()
        }
    }

    /// Agent time for a headline: whole hours once it's past ten, so "242h" stays on one line.
    static func hours(_ seconds: TimeInterval) -> String {
        seconds >= 10 * 3_600 ? "\(Int(seconds / 3_600))h" : WeeklyReportFormat.hours(seconds)
    }

    static func month(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).year()) }

    /// "+25%", "−8%", or "18×" once growth passes tenfold, where a percentage stops reading as a number.
    static func change(_ change: Double) -> String {
        if change >= 9 { return "\(Int((change + 1).rounded()))×" }
        let percent = Int((change * 100).rounded())
        if percent == 0 { return "0%" }
        return percent > 0 ? "+\(percent)%" : "−\(abs(percent))%"
    }

    /// The clock hour in the user's own format: "9:00 PM", "21:00".
    static func hour(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// What the sheet's profile is keyed on: a new period or new history means a fresh read.
private struct ProfileLoadKey: Hashable {
    var period: ProfilePeriod
    var revision: Int
}

/// The shareable profile sheet: the card for a period, previewed and copied or saved as a PNG at 2x.
struct ProfileShareSheet: View {
    @ObservedObject var agentStore: AgentStore
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: ProfilePeriod
    @State private var layout: ProfileCardLayout = .landscape
    @State private var dark: Bool?
    @State private var showsProject = false
    @State private var loaded: (key: ProfileLoadKey, profile: PersonalProfile)?
    @State private var status: String?

    init(agentStore: AgentStore, period: ProfilePeriod) {
        _agentStore = ObservedObject(wrappedValue: agentStore)
        _chosen = State(initialValue: period)
    }

    private var isDark: Bool { dark ?? (systemScheme == .dark) }
    private var key: ProfileLoadKey { ProfileLoadKey(period: chosen, revision: agentStore.historyRevision) }
    /// Only the profile for the period on screen; a stale one waits until its replacement is read.
    private var profile: PersonalProfile? { loaded.flatMap { $0.key == key ? $0.profile : nil } }
    /// Sharing waits until there's enough history to say something true.
    private var canShare: Bool { profile.map { $0.archetype.insufficientData == nil } ?? false }

    private var periodOptions: [ProfilePeriod] {
        let year = Calendar.current.component(.year, from: .now)
        let options: [ProfilePeriod] = [.week, .month, .year, .lastDays(30), .allTime, .calendarYear(year)]
        return options.contains(chosen) ? options : [chosen] + options
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(N.divider).frame(height: 1)
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(N.bgSoft)
            Rectangle().fill(N.divider).frame(height: 1)
            footer
        }
        .frame(width: 880, height: 740)
        .background(N.bg)
        .task(id: key) { await load() }
    }

    private func load() async {
        let requested = key
        let built = await agentStore.profile(for: requested.period)
        guard !Task.isCancelled else { return }
        loaded = (requested, built)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share your profile").font(NFont.bodyMedium).foregroundStyle(N.text)
                    Text("Built from your local history. Copying or saving is the only way it leaves this Mac.")
                        .font(NFont.caption).foregroundStyle(N.text2)
                }
                Spacer()
                Picker("Period", selection: $chosen) {
                    ForEach(periodOptions, id: \.self) { option in
                        Text(ProfileCardFormat.title(option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("The stretch of history the card covers")
            }
            HStack(spacing: 14) {
                Picker("Layout", selection: $layout) {
                    ForEach(ProfileCardLayout.allCases) { option in
                        Text(option.title).tag(option).help(option.help)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Appearance", selection: Binding(get: { isDark }, set: { dark = $0 })) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("How the card looks here and when exported")
                Toggle("Show top project", isOn: $showsProject)
                    .toggleStyle(.checkbox)
                    .font(NFont.small)
                    .help("Off by default: a project name can give away what you're working on")
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        if let profile {
            if let reason = profile.archetype.insufficientData {
                notice(reason)
            } else {
                scaled(profile)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading your history…").font(NFont.small).foregroundStyle(N.text2)
            }
        }
    }

    private func notice(_ reason: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "hourglass").font(.system(size: 22)).foregroundStyle(N.text2)
            Text("Not enough to share yet").font(NFont.bodyMedium).foregroundStyle(N.text)
            Text("Keep working with your agents and this card will fill in. \(reason)")
                .font(NFont.small).foregroundStyle(N.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }

    /// The card at a size that fits the preview, centred. Scaling is visual only: the export draws it at full size.
    private func scaled(_ profile: PersonalProfile) -> some View {
        GeometryReader { proxy in
            let size = layout.size
            let fit = min((proxy.size.width - 56) / size.width, (proxy.size.height - 56) / size.height)
            ProfileCard(profile: profile, layout: layout, dark: isDark, showsProject: showsProject)
                .overlay(Rectangle().strokeBorder(N.divider))
                .scaleEffect(fit)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    // MARK: Actions

    private var footer: some View {
        HStack(spacing: 8) {
            if let status {
                Label(status, systemImage: "checkmark").font(NFont.small).foregroundStyle(N.text2).labelStyle(TightLabelStyle())
            }
            Spacer()
            Button("Copy image") { copyImage() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!canShare)
            Button("Save…") { saveImage() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!canShare)
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    /// The card at 2x, in the chosen appearance regardless of the app's.
    private func renderedImage() -> NSImage? {
        guard let profile, canShare else { return nil }
        let renderer = ImageRenderer(content: ProfileCard(profile: profile, layout: layout, dark: isDark, showsProject: showsProject))
        renderer.scale = 2
        return renderer.nsImage
    }

    private func copyImage() {
        guard let image = renderedImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        flash("Image copied")
    }

    private func saveImage() {
        guard let profile, let image = renderedImage(), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let key = profile.period == .allTime ? "all time" : profile.interval.start.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Lookout profile \(key).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            flash("Saved \(url.lastPathComponent)")
        } catch {
            flash("Couldn't save: \(error.localizedDescription)")
        }
    }

    private func flash(_ message: String) {
        withAnimation(.snappy(duration: 0.2)) { status = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy(duration: 0.2)) { if status == message { status = nil } }
        }
    }
}
