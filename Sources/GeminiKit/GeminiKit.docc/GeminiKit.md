# ``GeminiKit``

Swift client library and reference server for the Gemini protocol.

## Overview

GeminiKit implements the core Gemini protocol pieces:

- Parse `gemini://` URLs with ``GeminiURI``, following links via ``GeminiURI/resolving(_:)``.
- Fetch pages with ``GeminiClient``, which pins server certificates on first
  sight (TOFU) through ``CertificateStore``.
- Decode `text/*` bodies with ``textString(from:charset:)`` (UTF-8 first,
  falling back to lossy US-ASCII) and split `text/gemini` into
  ``GemtextBlock`` values with ``GemtextParser``.
- Serve content with ``GeminiServer`` by mapping each request URI to a
  ``GeminiServerResponse``.

```swift
let uri = try GeminiURI.parse("gemini://example.com/")
switch try await GeminiClient.shared.fetch(uri) {
case .content(_, let mime, let data, _) where mime.hasPrefix("text/gemini"):
    let blocks = GemtextParser.parse(gemtextString(from: data))
    print(blocks)
case .redirect(let target):
    print("redirect:", target)
case .status(let status):
    print("status:", status.code, status.statusDescription)
case .certMismatch:
    print("server certificate changed — verify before continuing")
}
```

## Topics

### URLs

- ``GeminiURI``
- ``isAcceptableGeminiURL(_:)``

### Fetching

- ``GeminiClient``
- ``GeminiFetchResult``
- ``GeminiFetchError``

### Responses

- ``GeminiStatus``
- ``GeminiResponseHeader``
- ``GeminiProtocolError``

### Certificates

- ``CertificateStore``

### Gemtext

- ``GemtextParser``
- ``GemtextBlock``
- ``textString(from:charset:)``
- ``gemtextString(from:)``

### Serving

- ``GeminiServer``
- ``GeminiServerResponse``
- ``GeminiServerError``
