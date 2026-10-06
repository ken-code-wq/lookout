import SwiftUI
import LocalObserverCore

/// Budget meters on the Plan limits page: what each agent has spent against its cap, with the caps editable in place.
struct BudgetsSection: View {
    @ObservedObject var store: AgentStore
    @State private var editing = false

    private var agents: [AgentKind] { store.enabledAgentsSorted }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.gauge.chart.lefthalf.righthalf").foregroundStyle(N.text2)
                Text("Budgets").font(.system(size: 16, weight: .semibold)).foregroundStyle(N.text)
                Spacer()
                Button(editing ? "Done" : "Edit budgets") { withAnimation(.snappy(duration: 0.2)) { editing.toggle() } }
                    .buttonStyle(GhostButtonStyle(tint: N.blue))
            }
            let set = agents.filter { !(store.settings.budgets[$0]?.isEmpty ?? true) }
            if set.isEmpty && !editing {
                Text("Set a daily or weekly cap per agent and Lookout warns you before you hit it. Spend comes from the agents' own usage records.")
                    .font(NFont.small).foregroundStyle(N.text2)
            }
            ForEach(editing ? agents : set, id: \.self) { agent in
                BudgetRow(store: store, agent: agent, editing: editing)
            }
        }
        .padding(18)
        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct BudgetRow: View {
    @ObservedObject var store: AgentStore
    var agent: AgentKind
    var editing: Bool

    var body: some View {
        let budget = store.settings.budgets[agent] ?? AgentBudget()
        let spend = store.spend[agent] ?? AgentSpend()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentIconView(agent: agent, size: 16)
                Text(agent.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                Spacer()
                Text("\(AgentFormat.cost(spend.today, estimated: spend.estimated)) today · \(AgentFormat.cost(spend.week, estimated: spend.estimated)) this week")
                    .font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
            }
            if editing {
                HStack(spacing: 14) {
                    capField("Daily cap", value: budget.daily) { v in update { $0.daily = v } }
                    capField("Weekly cap", value: budget.weekly) { v in update { $0.weekly = v } }
                    Picker("Warn at", selection: Binding(get: { budget.warnAt }, set: { v in update { $0.warnAt = v } })) {
                        ForEach([0.5, 0.7, 0.8, 0.9], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    .fixedSize()
                }
                .font(NFont.small)
            } else {
                if let cap = budget.daily { meter("Today", spend.today, cap, budget.warnAt) }
                if let cap = budget.weekly { meter("This week", spend.week, cap, budget.warnAt) }
            }
        }
    }

    private func update(_ change: (inout AgentBudget) -> Void) {
        var settings = store.settings
        var budget = settings.budgets[agent] ?? AgentBudget()
        change(&budget)
        settings.budgets[agent] = budget.isEmpty ? nil : budget
        store.saveSettings(settings)
    }

    private func capField(_ label: String, value: Double?, set: @escaping (Double?) -> Void) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(N.text2)
            TextField("None", text: Binding(
                get: { value.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.2f", $0) } ?? "" },
                set: { text in
                    let cleaned = text.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
                    set(Double(cleaned).flatMap { $0 > 0 ? $0 : nil })
                }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Text("$").foregroundStyle(N.text3)
        }
    }

    private func meter(_ title: String, _ spent: Double, _ cap: Double, _ warnAt: Double) -> some View {
        let fraction = cap > 0 ? spent / cap : 0
        let color: Color = fraction >= 1 ? TagColor.red.fg : (fraction >= warnAt ? TagColor.orange.fg : N.blue)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(NFont.caption).foregroundStyle(N.text2)
                Spacer()
                Text("\(AgentFormat.cost(spent)) of \(AgentFormat.cost(cap))").font(NFont.caption).foregroundStyle(color).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(N.hover)
                    Capsule().fill(color).frame(width: geo.size.width * min(fraction, 1))
                    Rectangle().fill(N.text3).frame(width: 1).offset(x: geo.size.width * warnAt)
                }
            }
            .frame(height: 6)
        }
    }
}

/// Compact budget line for the menu bar's Limits section.
struct MenuBudgetRow: View {
    var agent: AgentKind
    var progress: (fraction: Double, period: String, spent: Double, cap: Double)
    var warnAt: Double

    var body: some View {
        let color: Color = progress.fraction >= 1 ? N.red : (progress.fraction >= warnAt ? TagColor.orange.fg : N.blue)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AgentIconView(agent: agent, size: 12)
                Text("\(agent.shortName) budget \(progress.period)").font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(AgentFormat.cost(progress.spent)) / \(AgentFormat.cost(progress.cap))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: geo.size.width * min(progress.fraction, 1))
                }
            }
            .frame(height: 4)
        }
    }
}
