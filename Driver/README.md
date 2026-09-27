# CosmoKit agent driver

The driver is an XCUITest bundle hosted by the blank `AgentHost` app. Build it
once, then keep the test process alive as a loopback HTTP server:

```sh
xcodebuild build-for-testing -project Driver/CosmoKitAgentDriver.xcodeproj -scheme AgentDriver -destination "id=<udid>" -derivedDataPath <cache>
xcodebuild test-without-building -xctestrun <cache>/Build/Products/*.xctestrun -destination "id=<udid>" TEST_RUNNER_COSMOKIT_DRIVER_PORT=8877
```

The CLI caches this under `~/Library/Caches/cosmokit/driver/<version>-<xcode
build>`. Endpoints are `/status`, `/app`, `/tree`, `/tap`, `/press`, `/swipe`,
`/type`, `/button`, `/alert`, `/screenshot`, and `/quit`.
