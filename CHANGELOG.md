# Changelog

## 0.4.1 — 2026-09-28

- Fixed `ui tree --app` latency: snapshot traversal via `XCElementSnapshot` and skipping redundant target switches drop repeat calls from ~81 s to < 1.0 s.
- Added resilient fallback to public AX hierarchy traversal when the private snapshot selector is missing.
- Updated UI tree benchmark with honest per-screen measurements across distinct scroll states, verifying 92.7% reduction vs raw driver JSON and 94.6% vs idb.

## 0.4.0 — 2026-09-26

- Added interactive Control mode to `agent stream`: click to tap, drag to swipe, debounced typing into focused fields, and hardware home button.
- Fixed `agent stream --daemon` exiting prematurely by keeping the server running in the background.
- Added structured feedback prompt export: `FeedbackPrompt.render`, `cosmokit feedback prompt [--seq N]`, and a "Copy prompt" button on the stream page.
- Added `cosmokit throttle <preset|custom>` and `cosmokit offline <on|off>` via the app's loopback control server, plus `network_conditions` MCP tool (53 tools total).
- Fixed driver targeting so `ui tree` and UI actions inspect the target app rather than the test host, supporting `--app <bundle>` and automatic persistence across driver restarts.
- Added reproducible UI-tree size and timing benchmark (`cli/scripts/benchmark.sh` and `cli/BENCHMARK.md`), documenting a 93.0% output size reduction vs raw driver trees.
- The release archive now ships the driver sources under `share/cosmokit/Driver`; the binary finds them next to itself, via `COSMOKIT_DRIVER_DIR`, or in a checkout.

## 0.3.0 — 2026-09-08

- Added client-side screen hash to `ui tree` and `--screen` guard to UI actions (`screenChanged` error).
- Added `ui wait` to block on element appearance or disappearance (`--gone`) without polling trees.
- Added `ui do` to run sequential UI action steps stopping on first failure with step index and final tree.
- Added `ui_wait` and `ui_do` MCP tools and `--screen` parameter to actions (52 tools total, 18,038 bytes `tools/list`).
- Added `agent stream`: loopback MJPEG HTTP server with per-session token path and crosshair click-to-element feedback.
- Added `feedback next|list|ack|clear`: read and acknowledge human comments from the stream without keeping it running.
- Added `agent_stream` and `feedback` MCP tools.
- Updated `cosmokit-simulator` skill and Cursor rule with screen guard, wait, and do flow.

## 0.2.0 — 2026-09-03

- Added the XCUITest simulator driver and cached agent lifecycle.
- Added compact UI tree inspection and tap, press, swipe, type, button, alert,
  screenshot, and find commands.
- Added MCP tools and the `cosmokit-simulator` Agent Skill.
