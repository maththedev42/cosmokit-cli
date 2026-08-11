# cosmokit CLI

Scriptable access to the iOS Simulator operations the [CosmoKit](https://usecosmoskittool.com)
macOS app performs, for Makefiles, git hooks and CI.

Boot a simulator, take a screenshot, record a video, set GPS coordinates or
open a deep link, without leaving the terminal.

## Requirements

macOS 13 or later with Xcode's command line tools installed. The CLI shells out
to `xcrun simctl`. It does not depend on the CosmoKit app, and you do not need
the app to use it.

## Install

Build from source. This is the recommended route, and the fastest one on a
machine that already has Xcode:

```sh
git clone https://github.com/maththedev42/cosmokit-cli.git
cd cosmokit-cli
swift build -c release
cp .build/release/cosmokit /usr/local/bin/
```

Or download the universal binary from
[Releases](https://github.com/maththedev42/cosmokit-cli/releases). It is ad-hoc
signed rather than notarized, so macOS quarantines it on download and you have
to clear that yourself:

```sh
tar xzf cosmokit-0.1.0-macos-universal.tar.gz
xattr -d com.apple.quarantine cosmokit
mv cosmokit /usr/local/bin/
```

## Commands

```
cosmokit list                        List available simulators
cosmokit boot [name|udid]            Boot a simulator (default: first available)
cosmokit shutdown [name|udid]        Shut a simulator down (default: booted)
cosmokit capture [name|udid]         Screenshot to a file
cosmokit record [name|udid]          Record video until Ctrl-C or --duration
cosmokit location <lat> <lon> [dev]  Set the simulator's GPS position
cosmokit open <url> [name|udid]      Open a deep link
cosmokit erase [name|udid]           Erase a simulator back to a fresh install
cosmokit mcp                         Run as an MCP server over stdio (for AI agents)
```

`--output <path>` sets the directory for `capture` and `record`. Use
`--duration <seconds>` with `record` when an agent or script cannot send
Ctrl-C.

Device arguments accept a UDID, an exact name, or a partial name. Omit them to
use the booted simulator.

Commands exit non-zero on failure, so they are safe to use under `set -e`.

## JSON output

Pass `--json` to make any command print one machine-readable JSON object.
Successful results use `{"ok":true,...}` with the command's fields at the top
level; failures use `{"ok":false,"error":{"code":"...","message":"..."}}`.

The stable error codes are:

| Code | Meaning |
| --- | --- |
| `usage` | The arguments did not make sense. |
| `deviceNotFound` | No simulator matched the device query. |
| `noSimulator` | No simulator was available for the operation. |
| `simctlFailed` | `xcrun simctl` returned a failure. |
| `unknownCommand` | The command or tool name is not recognised. |

Exit codes are unchanged, so a script can branch on either the process exit
status or the JSON `ok` field.

```sh
cosmokit --json version
# {"ok":true,"version":"0.1.0"}

cosmokit --json list
# {"devices":[{"available":true,"booted":false,"name":"iPad mini","state":"Shutdown","udid":"F4A10318-6B19-444B-A55D-A76536BC2196"},{"available":true,"booted":false,"name":"iPhone 15 Pro","state":"Shutdown","udid":"3F6F3AE3-D548-4486-83C7-42FC5604B436"},{"available":true,"booted":true,"name":"iPhone 16","state":"Booted","udid":"535B96FA-19EB-4682-868F-6DD1C53B6474"},{"available":true,"booted":true,"name":"iPhone 16 Pro","state":"Booted","udid":"B5029438-33A9-47E0-ACA4-C7B790A12E64"}],"ok":true}
```

## Use from an AI agent

An agent that can run a command can already use this CLI. `cosmokit mcp` goes
further by letting an MCP client discover the simulator operations and call
them with typed arguments.

### Register it

Add the following to the configuration file for an MCP client such as Claude
Code or Cursor:

```json
{
  "mcpServers": {
    "cosmokit": {
      "command": "cosmokit",
      "args": ["mcp"]
    }
  }
}
```

### What it exposes

| Tool | Purpose |
| --- | --- |
| `list_simulators` | List available simulators sorted by name. |
| `boot_simulator` | Boot a selected simulator, or the first available shutdown simulator. |
| `shutdown_simulator` | Shut down a selected simulator, or the booted simulator. |
| `capture_screenshot` | Capture a PNG screenshot into an optional output directory. |
| `record_video` | Record a video for a required fixed duration into an optional output directory. |
| `set_location` | Set latitude and longitude on a simulator. |
| `open_url` | Open a URL or deep link in a simulator. |
| `erase_simulator` | Erase a selected simulator, or the booted simulator. |

`record_video` requires `duration` because a tool call has no way to send
Ctrl-C, so every recording has to stop on a timer.

The transport is newline-delimited JSON-RPC 2.0 on stdin and stdout. Stdout is
reserved for protocol messages; diagnostics go to stderr so they cannot
corrupt the MCP stream.

To try discovery by hand:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | cosmokit mcp
```

The command prints one JSON object per line. JSON object key order carries no
meaning, so a reader's output may order fields differently.

The `set_location` tool schema looks like this when pretty-printed:

```json
{
  "name": "set_location",
  "inputSchema": {
    "required": [
      "latitude",
      "longitude"
    ],
    "type": "object",
    "properties": {
      "longitude": {
        "description": "Longitude in decimal degrees",
        "type": "number"
      },
      "device": {
        "type": "string",
        "description": "UDID, exact name, or partial name; omit to use the booted simulator"
      },
      "latitude": {
        "type": "number",
        "description": "Latitude in decimal degrees"
      }
    }
  },
  "description": "Set a simulator's GPS location using latitude and longitude; omit device to use the booted simulator."
}
```

The full response lists all eight tools.

## Examples

```sh
# Screenshot every booted simulator into the repo's screenshots folder
cosmokit capture --output ./screenshots

# Put the simulator in Rio before running location tests
cosmokit location -22.9068 -43.1729

# Exercise a deep link in a pre-commit hook
cosmokit open "myapp://item/42"

# Start from a known-clean device in CI
cosmokit erase "iPhone 16" && cosmokit boot "iPhone 16"
```

## Scope

Free, and intentionally limited to what plain `simctl` can do. The CosmoKit
app's Pro features (network proxy, device frames, watermark-free exports, Dev
Presets) stay in the app, where the entitlement lives.

## License

MIT. See [LICENSE](LICENSE).
