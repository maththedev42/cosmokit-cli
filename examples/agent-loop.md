# Agent loop example

This is the compact transcript shape produced by the driver on the dedicated
iOS simulator:

```text
$ cosmokit launch com.apple.Preferences
Launched com.apple.Preferences
$ cosmokit ui tree --mode act
[1] cell "Settings" (0,0 390×50)
[2] cell "General" (0,50 390×50)
$ cosmokit ui tap 2
OK
$ cosmokit ui tree --mode act
[1] button "General" (0,59 390×50)
[2] cell "About" (0,109 390×50)
$ cosmokit ui find General
[1] button General
$ cosmokit ui screenshot --output ./artifacts
./artifacts/CosmoKit-UI-1760000000.png
```

The tree is the cheap assertion surface. The screenshot is reserved for a
visual check after the navigation assertion.
