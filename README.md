opencore-amr-iOS
================

[![Build and Release XCFramework](https://github.com/feuvan/opencore-amr-iOS/actions/workflows/build_xcframework.yml/badge.svg)](https://github.com/feuvan/opencore-amr-iOS/actions/workflows/build_xcframework.yml)

Download pre-built XCFrameworks from [Release](https://github.com/feuvan/opencore-amr-iOS/releases) page.

iOS port of opencore-amr

Refer to `README` for opencore-amr info which is from original package.

Run `build_ios.sh` to build all five targets in parallel (iOS device arm64,
iOS simulator arm64 + x86_64, macOS arm64 + x86_64), package both
XCFrameworks, and verify every slice (Swift `import` compile per slice,
compile + link + run on the host macOS slice, framework-style textual
include). Environment overrides: `OUTPUT_DIR`, `IPHONEOS_DEPLOYMENT_TARGET`
(default 12.0), `MACOSX_DEPLOYMENT_TARGET` (default 10.13), `MAKE_JOBS`,
`BUILD_PARALLEL`.

Then use `opencore-amrnb.xcframework` or `opencore-amrwb.xcframework` in `output` directory.

Every XCFramework slice contains a static framework bundle — the canonical
modular binary layout, with exactly one Clang module map:

```
<slice>/opencore_amrnb.framework/
    opencore_amrnb               # static archive (bundle name == module name)
    Headers/                     # public headers + generated opencore-amrnb.h umbrella
    Modules/module.modulemap     # framework module opencore_amrnb { umbrella header }
    Info.plist
```

Link the XCFramework in your Xcode target and import it directly (module names
use `_` because Clang module names cannot contain `-`):

```swift
import opencore_amrnb   // Encoder_Interface_* / Decoder_Interface_*
import opencore_amrwb   // D_IF_*
```

```objc
@import opencore_amrnb;                       // modular
#include <opencore_amrnb/opencore-amrnb.h>    // or textual: generated umbrella header
```

SwiftPM: both XCFrameworks work as `binaryTarget`s — including **both** in the
same package. Framework bundles keep their headers and module map
self-contained, so they avoid the merged-include-dir collision that
static-library XCFrameworks hit in SwiftPM; the static archive is auto-linked.

For AMR-WB encoding, refer to http://sourceforge.net/projects/opencore-amr/files/vo-amrwbenc/ or AMR Codecs as Shared Libraries http://www.penguin.cz/~utx/amr
