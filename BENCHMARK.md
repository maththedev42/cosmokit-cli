# CosmoKit UI tree benchmark

- Date (UTC): 2026-09-26
- macOS: 26.4
- Xcode: Xcode 26.4.1 Build version 17E202
- Simulator: iPhone 16 Pro (B5029438-33A9-47E0-ACA4-C7B790A12E64), 
- CLI version: 0.4.0
- Test app commit: 3b54f749eb988fe839e91b45129297089871ecf0
- idb: installed
- Reproduce: `bash cli/scripts/benchmark.sh --udid B5029438-33A9-47E0-ACA4-C7B790A12E64 --app apps.mjkweber.CosmoKitTestApp --screens home,list,form,modal --write`

Bytes are UTF-8 output bytes. Tokens are approximate bytes ÷ 4, matching the
README convention; this is not a tokenizer-exact count. Timing is the median
of five runs and is wall-clock `real` time.

| Screen | act bytes (≈ tokens) | nav bytes (≈ tokens) | debug bytes (≈ tokens) | raw driver JSON bytes (≈ tokens) | idb bytes (≈ tokens) | screenshot PNG bytes | act vs raw | act vs idb | act median (s) | raw median (s) | idb median (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| home | 2240 (560) | 6105 (1526) | 6105 (1526) | 32665 (8166) | 2029 (507) | 1790447 | 93.1% | -10.4% | 87.42 | 88.35 | 0.25 |
| list | 2240 (560) | 6105 (1526) | 6105 (1526) | 32714 (8178) | 44053 (11013) | 2257720 | 93.2% | 94.9% | 85.89 | 83.73 | 0.44 |
| form | 2240 (560) | 6105 (1526) | 6105 (1526) | 31678 (7920) | 44053 (11013) | 2188925 | 92.9% | 94.9% | 79.43 | 80.00 | 0.47 |
| modal | 2240 (560) | 6105 (1526) | 6105 (1526) | 31174 (7794) | 44053 (11013) | 2160829 | 92.8% | 94.9% | 77.38 | 78.69 | 0.65 |
| **Mean** | — | — | — | — | — | — | **93.0%** | **68.6%** | — | — | — |

The quoted percentages are for this four-screen test app run on this date:
act vs raw driver JSON = 93.0%; act vs idb = 68.6%.
