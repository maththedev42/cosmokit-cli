# MCP client example

`mcp.json` is a ready-to-paste configuration for an MCP client that launches
CosmoKit as a stdio server. The `cosmokit` executable must be on your `PATH`,
or replace the command with its absolute path. The server needs Xcode's
command line tools installed because it shells out to `xcrun simctl`.
