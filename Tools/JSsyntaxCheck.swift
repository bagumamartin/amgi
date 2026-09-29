#!/usr/bin/env swift
// Syntax-checks a JavaScript file with JavaScriptCore (always present on
// macOS), so the reader's injected script can be validated without a
// node/deno/bun install.
//
//   swift Tools/JSsyntaxCheck.swift path/to/script.js
import Foundation
import JavaScriptCore

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: JSsyntaxCheck.swift <file.js>\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: arguments[1])
guard let source = try? String(contentsOf: url, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
    exit(2)
}

// A fresh context with no globals. Wrapping the source in a function body
// means JavaScriptCore *parses* it without executing it, so a `ReferenceError`
// from a missing `window`/`document` is not mistaken for a syntax error — and
// a genuinely unbalanced quote or brace is still caught.
let context = JSContext()!
var thrown: String?
context.exceptionHandler = { _, exception in
    thrown = exception?.toString()
}

let wrapped = "(function amgiSyntaxCheckOnly() {\n\(source)\n});"
let result = context.evaluateScript(wrapped)
if let thrown {
    FileHandle.standardError.write(Data("SYNTAX ERROR in \(url.lastPathComponent):\n\(thrown)\n".utf8))
    exit(1)
}
guard result != nil else {
    FileHandle.standardError.write(Data("SYNTAX ERROR in \(url.lastPathComponent)\n".utf8))
    exit(1)
}

print("OK \(url.lastPathComponent)")
