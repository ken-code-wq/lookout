import SwiftUI
import LocalObserverCore

/// The dashboard's one line about the You page. Days 1 to 5 offer last month's recap, December to January 7 offers
/// Wrapped for the year, and every other day gets a quiet line about this month. It's a strip you can see when you
/// look, never a pop-up. Dismissing a recap or Wrapped hides it until the next month or year. Nothing shows until
/// there's a habit to name, so a new history stays out of the way.
struct ProfileTeaserCard: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject private var prefs = Preferences.shared
    @AppStorage("LocalObserver.profileTeaserDismissed") private var dismissedKey = ""
    /// The day the line is read for: today in the app, a fixed day in the snapshots.
    var now: Date = .now
    /// Opens the You page on a period.
    var open: (ProfilePeriod) -> Void
    @State private var loaded: Loaded?
    @State private var sharing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Loaded {
        var variant: ProfileTeaser
        var profile: PersonalProfile
    }

    private struct LoadKey: Hashable {
        var variant: ProfileTeaser
        var revision: Int
    }

    var body: some View {
        let variant = ProfileTeaser.on(now)
        // A VStack rather than a Group: it stays in the tree when there's nothing to show yet, so the load still runs.
        VStack(spacing: 0) {
            if prefs.showProfileRecaps, !isDismissed(variant), let loaded, loaded.variant == variant,
               let match = readable(loaded.profile) {
                row(variant, loaded.profile, match)
                    .padding(.bottom, 16)
            }
        }
        .task(id: LoadKey(variant: variant, revision: agentStore.historyRevision)) { await load(variant) }
        .sheet(isPresented: $sharing) {
            ProfileShareSheet(agentStore: agentStore, period: ProfileTeaser.on(now).period())
        }
    }

    // MARK: Loading and what shows

    private func load(_ variant: ProfileTeaser) async {
        let profile = await agentStore.profile(for: variant.period(), now: now)
        guard !Task.isCancelled else { return }
        loaded = Loaded(variant: variant, profile: profile)
    }

    private func isDismissed(_ variant: ProfileTeaser) -> Bool {
        variant.dismissalKey().map { $0 == dismissedKey } ?? false
    }

    /// A line needs a habit to name. A stretch too thin to read, or one that only says "just getting started", shows nothing.
    private func readable(_ profile: PersonalProfile) -> ArchetypeMatch? {
        guard profile.archetype.insufficientData == nil, let match = profile.archetype.primary,
              match.archetype != .gettingStarted else { return nil }
        return match
    }

    /// The newest milestone reached just now, as the quiet line names it. Ones found in old history don't count.
    private var newMilestone: Milestone? {
        agentStore.newMilestones.last(where: { !$0.isRetroactive })?.milestone
    }

    @ViewBuilder private func row(_ variant: ProfileTeaser, _ profile: PersonalProfile, _ match: ArchetypeMatch) -> some View {
        switch variant {
        case .recap(let monthStart): recapRow(monthStart, profile, match, variant)
        case .wrapped(let year): wrappedRow(year, profile, match, variant)
        case .quiet: quietRow(profile, match, variant)
        }
    }

    // MARK: Rows

    private func recapRow(_ monthStart: Date, _ profile: PersonalProfile, _ match: ArchetypeMatch, _ variant: ProfileTeaser) -> some View {
        strip {
            Image(systemName: "calendar").font(.system(size: 14)).foregroundStyle(N.text2).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your \(monthStart.formatted(.dateTime.month(.wide))) recap is ready")
                    .font(NFont.bodyMedium).foregroundStyle(N.text).lineLimit(1)
                Text("\(match.archetype.name) · \(requestsLine(profile, against: "the month before"))")
                    .font(NFont.small).foregroundStyle(N.text2).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Open recap") { open(variant.period()) }.buttonStyle(SecondaryButtonStyle())
            dismissButton(variant, help: "Hide it until next month")
        }
    }

    private func wrappedRow(_ year: Int, _ profile: PersonalProfile, _ match: ArchetypeMatch, _ variant: ProfileTeaser) -> some View {
        // Still under way in December; the whole year once it's January.
        let who = profile.isPartial ? "\(youAre(match.archetype.name)) so far this year" : "\(youWere(match.archetype.name)) in \(year)"
        return strip {
            Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(N.text2).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                // A String, not the Int: a Text would write the year as "2,026".
                Text("Lookout Wrapped \(String(year)) is ready")
                    .font(NFont.bodyMedium).foregroundStyle(N.text).lineLimit(1)
                Text("\(who) · \(requestsLine(profile, against: "the year before"))")
                    .font(NFont.small).foregroundStyle(N.text2).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Open") { open(variant.period()) }.buttonStyle(SecondaryButtonStyle())
            Button("Share card") { sharing = true }.buttonStyle(SecondaryButtonStyle())
            dismissButton(variant, help: "Hide it until next year")
        }
    }

    /// The whole strip opens the You page on this month, and carries the newest milestone when there is one.
    private func quietRow(_ profile: PersonalProfile, _ match: ArchetypeMatch, _ variant: ProfileTeaser) -> some View {
        // The archetype's own sentence is the one fact: the same clause the You page's hero leads with.
        let line = "\(youAre(match.archetype.name)) this month · \(match.sentence)"
        return Button { open(variant.period()) } label: {
            strip {
                Image(systemName: "person.crop.circle").font(.system(size: 14)).foregroundStyle(N.text2).frame(width: 18)
                Text(line).font(NFont.small).foregroundStyle(N.text2).lineLimit(1)
                Spacer(minLength: 12)
                if let milestone = newMilestone {
                    Tag(text: "New milestone: \(milestone.title)", color: .yellow, symbol: "star.fill")
                }
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(N.text3)
            }
        }
        .buttonStyle(.plain)
        .help("Open your profile")
    }

    // MARK: Pieces

    /// The bordered strip the line sits in, matching the dashboard's overview strip.
    private func strip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(N.divider))
    }

    private func dismissButton(_ variant: ProfileTeaser, help: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { dismissedKey = variant.dismissalKey() ?? "" }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(N.text3)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The stretch's requests, with how they moved on the one before when there's a change to show.
    private func requestsLine(_ profile: PersonalProfile, against: String) -> String {
        let requests = "\(profile.totals.tally.requests.formatted()) requests"
        guard let change = profile.trends?.requests else { return requests }
        let percent = Int((change * 100).rounded())
        guard percent != 0 else { return requests }
        return "\(requests) · \(ProfileCardFormat.change(change)) vs \(against)"
    }

    /// "You're The Conductor", or "You're in Night Shift" where the name has no article.
    private func youAre(_ name: String) -> String { name.hasPrefix("The ") ? "You're \(name)" : "You're in \(name)" }
    private func youWere(_ name: String) -> String { name.hasPrefix("The ") ? "You were \(name)" : "You were in \(name)" }
}
