# CosmoKit UI tree benchmark

- Date (UTC): 2026-09-28
- macOS: 26.4
- Xcode: Xcode 26.4.1 Build version 17E202
- Simulator: iPhone 16 Pro (B5029438-33A9-47E0-ACA4-C7B790A12E64), iOS 26.4
- CLI version: 0.4.1
- Driver start: already running
- Test app commit: 7d2e529575824b450cd1c5a2cb06d2b769bdf3ed
- idb: installed
- Reproduce: `bash cli/scripts/benchmark.sh --udid B5029438-33A9-47E0-ACA4-C7B790A12E64 --app apps.mjkweber.CosmoKitTestApp --screens home,list,form,modal --write`

Bytes are UTF-8 output bytes. Tokens are approximate bytes ÷ 4, matching the
README convention; this is not a tokenizer-exact count. Timing is the median
of five runs and is wall-clock `real` time.

| Screen | act bytes (≈ tokens) | nav bytes (≈ tokens) | debug bytes (≈ tokens) | raw driver JSON bytes (≈ tokens) | idb bytes (≈ tokens) | screenshot PNG bytes | act vs raw | act vs idb | act median (s) | raw median (s) | idb median (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| home | 2184 (546) | 5803 (1451) | 5803 (1451) | 33694 (8424) | 45727 (11432) | 2340914 | 93.5% | 95.2% | 0.81 | 0.53 | 0.53 |
| list | 2743 (686) | 5804 (1451) | 5804 (1451) | 35675 (8919) | 48758 (12190) | 1710782 | 92.3% | 94.4% | 0.82 | 0.43 | 0.55 |
| form | 2775 (694) | 5814 (1454) | 5814 (1454) | 35821 (8955) | 48978 (12244) | 1576693 | 92.3% | 94.3% | 0.93 | 0.45 | 0.78 |
| modal | 2524 (631) | 5854 (1464) | 5854 (1464) | 34766 (8692) | 47272 (11818) | 1296821 | 92.7% | 94.7% | 0.76 | 0.48 | 0.48 |
| **Mean** | — | — | — | — | — | — | **92.7%** | **94.6%** | — | — | — |

The quoted percentages are for this four-screen test app run on this date:
act vs raw driver JSON = 92.7%; act vs idb = 94.6%.

## Appendix: First 3 lines of act output per screen

### home (hash: c4eda23f)

```
screen: c4eda23f
[9] image "rectangle.3.group.bubble" (186,61 29×28) value="" placeholder=""
[16] image "Favorito" (67,248 12×11) value="" placeholder=""
```

### list (hash: 5f9befb4)

```
screen: 5f9befb4
[9] image "rectangle.3.group.bubble" (186,-591 29×28) value="" placeholder=""
[16] image "Favorito" (67,-404 12×11) value="" placeholder=""
```

### form (hash: 7fd4d483)

```
screen: 7fd4d483
[9] image "rectangle.3.group.bubble" (186,-1262 29×28) value="" placeholder=""
[16] image "Favorito" (67,-1075 12×11) value="" placeholder=""
```

### modal (hash: c0bde181)

```
screen: c0bde181
[9] image "rectangle.3.group.bubble" (186,-1919 29×28) value="" placeholder=""
[16] image "Favorito" (67,-1731 12×11) value="" placeholder=""
```
