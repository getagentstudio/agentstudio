/// Static, shareable instructions; runtime paths and credentials are resolved
/// by the agentstudio skill after the user pastes this into their agent.
enum AgentSetupPrompt {
    static let text = """
        Use the agentstudio skill to set up Agent Studio hooks for my current provider. Run `agentstudio package status` first and explain the result. Get my go-ahead before using `agentstudio package install <provider>` or `agentstudio package uninstall <provider>`. Offer `agentstudio package snippet <provider>` if I manage my configuration with chezmoi. Follow the skill's helper and target resolution, and never hand-edit provider files.
        """
}
