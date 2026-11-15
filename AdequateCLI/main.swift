// adequate: drive the Adequate browser from the shell.
//
//   adequate open <space> <url>...   open the urls as tabs in the space, creating it if needed
//   adequate spaces                  list the spaces, one per line
import AppKit

let usage = """
    usage: adequate open <space> <url>...
           adequate spaces
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Strict query encoding: only unreserved characters stay literal, so `&`,
/// `=`, `+` and `#` inside a url survive the trip.
func encode(_ value: String) -> String {
    let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved)!
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "open":
    guard args.count >= 3 else { fail(usage) }
    let space = args[1]
    let tokenFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Adequate/cli-token")
    guard let token = try? String(contentsOf: tokenFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) else { fail("no cli token yet: run Adequate once") }
    let query = (["token=\(encode(token))", "space=\(encode(space))"] + args[2...].map { "url=\(encode($0))" })
        .joined(separator: "&")
    guard let url = URL(string: "adequate://open?\(query)") else { fail("couldn't build an adequate url") }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [url.absoluteString]
    try open.run()
    open.waitUntilExit()
    if open.terminationStatus != 0 { fail("couldn't open Adequate (is it installed?)") }
case "spaces":
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Adequate/spaces.json")
    struct Space: Decodable { let name: String }
    guard let data = try? Data(contentsOf: file),
          let spaces = try? JSONDecoder().decode([Space].self, from: data)
    else { fail("no spaces yet: run Adequate once") }
    spaces.forEach { print($0.name) }
default:
    fail(usage)
}
