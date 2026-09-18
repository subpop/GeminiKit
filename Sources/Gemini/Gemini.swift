import ArgumentParser

// MARK: - gemini: basic Gemini server + client in one verb-command program.
//
// gemini serve - serves a basic server for testing clients.
// gemini fetch - fetches a gemini URL and prints it.

@main
struct Gemini: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gemini",
        abstract: "Basic Gemini server and client.",
        version: "1.0.0",
        subcommands: [Serve.self, Fetch.self]
    )
}
