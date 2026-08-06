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
cosmokit record [name|udid]          Record video until Ctrl-C
cosmokit location <lat> <lon> [dev]  Set the simulator's GPS position
cosmokit open <url> [name|udid]      Open a deep link
cosmokit erase [name|udid]           Erase a simulator back to a fresh install
```

`--output <path>` sets the directory for `capture` and `record`.

Device arguments accept a UDID, an exact name, or a partial name. Omit them to
use the booted simulator.

Commands exit non-zero on failure, so they are safe to use under `set -e`.

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
