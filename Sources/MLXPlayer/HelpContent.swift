import Foundation

/// Plain-language explanations shown by the "?" button on each screen: what a term means and why it matters.
enum HelpContent {
    typealias Entries = [(term: String, meaning: String)]

    static let advisor: Entries = [
        ("Job", "What you want the model for. It changes which models rank first: coding favors code models, reasoning favors thinking models."),
        ("Variant", "Standard models decline some requests. Uncensored and abliterated ones have that reduced or removed."),
        ("Best overall", "The strongest model that fits comfortably with a useful context window."),
        ("Headroom", "Memory left after the weights and the context cache. Low headroom means slowdowns or a failed load."),
        ("Speed (t/s)", "Estimated tokens per second, from your Mac's memory bandwidth. Real speed varies; treat it as a guide."),
        ("Context", "How much text the model can read at once. Longer context uses more memory."),
    ]

    static let usage: Entries = [
        ("Requests", "Calls that went through this app's local endpoint. Only traffic via the proxy is counted."),
        ("Tokens in / out", "Tokens are word pieces. 'In' is what you send (prompt), 'out' is what the model writes."),
        ("Avg speed", "Output tokens per second while generating."),
        ("First token", "How long a request waits before the first word appears. Includes loading the model if it was idle."),
        ("By client", "Which app sent the requests, taken from its User-Agent."),
    ]

    static let server: Entries = [
        ("Context length", "The longest prompt plus answer the server accepts. Bigger needs more memory; the proxy rejects requests above it."),
        ("Prompt cache", "Keeps the processed start of a conversation so follow-ups skip re-reading it. Faster, uses memory."),
        ("Cache size", "Memory budget for the prompt cache. When full, the oldest entries are dropped."),
        ("KV cache", "Memory that stores attention for the text so far. Quantizing it (kv-bits) saves memory but serves one request at a time."),
        ("Prefill step", "How many prompt tokens are processed per chunk. Larger can be faster but spikes memory."),
        ("Concurrency", "How many prompts or decodes run side by side."),
        ("Benchmark", "Streams one fixed prompt and measures real tokens per second and first-token delay. Results appear in Library and make speed estimates for other models more accurate."),
        ("Network", "Host and port of the endpoint. 127.0.0.1 keeps it on this Mac; 0.0.0.0 exposes it to your network."),
    ]

    static let memory: Entries = [
        ("Pressure", "macOS's own health signal for memory: Normal, Warning, High, Critical. The app reacts at each level."),
        ("GPU memory limit", "The most unified memory the GPU may wire. A model bigger than this cannot load. Apply raises it until restart."),
        ("Keep free", "Memory the app leaves for macOS and other apps when it decides what fits."),
        ("Profiles", "Performance keeps the model loaded and the cache large. Saver unloads sooner and trims more."),
        ("Swap", "Memory pushed to disk. Heavy swap makes everything slow."),
    ]

    static let logs: Entries = [
        ("Logs", "Output from the model server, installer and downloads. Errors are red, warnings amber."),
        ("Filter", "Shows only lines containing your text."),
        ("Copy", "Copies the visible lines, useful when reporting a problem."),
    ]

    static let settings: Entries = [
        ("Hugging Face token", "Needed for gated models and gives higher download limits. Stored in the macOS Keychain, never in a file."),
        ("Agents (MCP)", "Lets tools like Claude Code control this app: check status, search and download models, start and stop the server."),
        ("Permission", "Read only can look. Ask first prompts you before changes. Full allows changes without asking."),
        ("mlx-lm", "The Python package that serves the models. Upgrade for new model support."),
        ("Appearance", "System follows macOS. Light and Dark override it."),
    ]
}
