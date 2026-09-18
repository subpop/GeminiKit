# GeminiKit

Swift package with Gemini protocol support: client library, reference server, and CLI.

## Layout

### GeminiKit

| Path | Description |
| --- | --- |
| `GeminiURI` | Parse/normalize/resolve `gemini://` URLs, build request lines. | 
| `GeminiStatus`, `GeminiResponseHeader` | Status and response header parsing. |
| `GeminiClient` | `async` fetch over `NWConnection` with TLS TOFU; `GeminiClient.shared.fetch(uri)`, or `fetch(uri, timeout:)`. |
| `CertificateStore` | Keychain-backed SHA-256 fingerprint pins; `init(servicePrefix:)` isolates namespaces, e.g. per test-run. |
| `GemtextParser` / `GemtextBlock` | Parse `text/gemini` into blocks. |

### Gemini

`gemini` is a single verb-command program combining both:

- `gemini serve` is a reference server. It uses an ephemeral self-signed identity,
  demo routes for every status class, `--root` static file serving (`.gmi` →
  `text/gemini`).
- `gemini fetch` is a fetch-and-print client with light ANSI rendering (`--raw`,
  `--status`, `--timeout`, `--insecure`, `--tofu-prefix`)

## Usage

Fetch a page:

```swift
import GeminiKit

let uri = try GeminiURI.parse("gemini://example.com/")
switch try await GeminiClient.shared.fetch(uri) {
case .content(let mime, let data):
    print(mime, data.count)
case .redirect(let target):
    print("redirect:", target)
case .status(let status):
    print("status:", status.code, status.meta)
case .certMismatch:
    print("server certificate changed!")
}
```

Parse Gemtext:

```swift
if case .content(_, let data) = try await GeminiClient.shared.fetch(uri) {
    let blocks = GemtextParser.parse(gemtextString(from: data))
    for block in blocks {
        switch block {
        case .heading(let level, let text): print("h\(level):", text)
        case .link(let url, let label): print("=>", url, label ?? "")
        case .text(let t), .bullet(let t), .quote(let t): print(t)
        case .pre(let t): print(t)
        }
    }
}
```

Build and resolve URLs:

```swift
let uri = GeminiURI(host: "example.com", path: "/docs/")
let next = try uri.resolving("page?answer=42") // follows relative links
let prompt = uri.withInputQuery("search terms") // answers 1x input prompts
```

Serve a capsule:

```swift
import GeminiKit

let server = GeminiServer(port: 1966) { _ in
    .success(mime: "text/gemini", body: Data("# Hello\n=> /about About".utf8))
}
try await server.start()
```

## Build & test

```sh
swift build
swift test   # 45 tests, all pass
```

## Documentation

API reference is generated with Swift DocC and published to GitHub Pages by
`.github/workflows/docs.yml` on every push to `main`.

Preview locally:

```sh
swift package --allow-writing-to-directory ./docs \
  generate-documentation --target GeminiKit \
  --output-path ./docs \
  --transform-for-static-hosting \
  --hosting-base-path GeminiKit
```

## Try it

```sh
.build/debug/gemini serve --port 1966 &
.build/debug/gemini fetch gemini://localhost:1966/chain/2
.build/debug/gemini fetch --raw gemini://geminiprotocol.net/ > page.gmi
```

First connection to a host prompts for Keychain access (TOFU pin storage)
and trusts silently thereafter; a changed certificate surfaces as
`GeminiFetchResult.certMismatch`.
