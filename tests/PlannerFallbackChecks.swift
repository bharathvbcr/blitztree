import Foundation

/// A deleted or invalid custom provider in `bz.engine` must not hide the
/// ready CLI agents from the Clean Up planner.
@main
struct PlannerFallbackChecks {
    @MainActor
    static func main() async {
        let defaults = UserDefaults.standard
        let savedEngine = defaults.object(forKey: "bz.engine")
        let savedAgent = defaults.object(forKey: "bz.agent")
        defer {
            defaults.set(savedEngine, forKey: "bz.engine")
            defaults.set(savedAgent, forKey: "bz.agent")
        }
        defaults.removeObject(forKey: "bz.agent")

        let model = ScanModel()
        model.agentEnv = AgentEnvironment(
            agents: [InstalledAgent(kind: .codex, path: "/bin/codex", signedIn: true),
                     InstalledAgent(kind: .claude, path: "/bin/claude", signedIn: true)],
            loaded: true)

        defaults.set("provider:deleted-provider", forKey: "bz.engine")
        precondition(model.preferredProvider == nil, "the stale provider must not resolve")
        precondition(model.preferredAgent?.kind == .claude,
                     "a stale provider must fall back to a ready agent, preferring Claude Code")
        precondition(model.plannerName == "Claude Code", "the planner must not be nil with a ready agent")
        precondition(defaults.string(forKey: "bz.engine") == nil, "the stale bz.engine key must be cleared")

        defaults.set("provider:deleted-provider", forKey: "bz.engine")
        defaults.set("codex", forKey: "bz.agent")
        precondition(model.preferredAgent?.kind == .codex, "the last-used agent wins over Claude Code")

        // MANVI is a planner like the others once ready, and only when picked
        // or when it is the only one ready.
        model.agentEnv = AgentEnvironment(
            agents: [InstalledAgent(kind: .manvi, path: "/bin/manvi", signedIn: true),
                     InstalledAgent(kind: .claude, path: "/bin/claude", signedIn: true)],
            loaded: true)
        defaults.removeObject(forKey: "bz.agent")
        defaults.set("manvi", forKey: "bz.engine")
        precondition(model.preferredAgent?.kind == .manvi && model.plannerName == "MANVI", "MANVI when picked")
        defaults.removeObject(forKey: "bz.engine")
        precondition(model.preferredAgent?.kind == .claude, "Claude Code stays the default")
        model.agentEnv = AgentEnvironment(
            agents: [InstalledAgent(kind: .manvi, path: "/bin/manvi", signedIn: false)], loaded: true)
        defaults.set("manvi", forKey: "bz.engine")
        precondition(model.preferredAgent == nil, "a MANVI without a model is not a planner")
        model.setUp(.manvi)
        precondition(model.agentSetup == nil, "BlitzTree never installs MANVI")

        model.agentEnv = AgentEnvironment(loaded: true)
        defaults.set("provider:deleted-provider", forKey: "bz.engine")
        precondition(model.plannerName == nil, "with no ready agent there is still no planner")
        print("PlannerFallbackChecks passed")
    }
}
