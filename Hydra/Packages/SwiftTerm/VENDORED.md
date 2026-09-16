# SwiftTerm

Library sources and MIT license copied from s1ckdark/SwiftTerm at
54b436a6231976fa64d7c3859d0b197a6ccfcb91. Only the library target is packaged.

Hydra maintains this local copy because the iOS UITextInput implementation is
not overridable from a host application. Local changes replace the Korean
composition heuristics with UIKit marked-range handling, display preedit in a
separate label instead of feeding it into the terminal grid, and remove the
unconditional input-content file logger. macOS AppKit input is unchanged.

Hydra iOS now routes keyboard input through `NativeTerminalInputView`, a native
UITextView, because Korean input on the tested iPad revises text without marked
ranges. The accessory/control commit and keyboard-toggle hooks allow that native
editor to own its draft without modifying the remote terminal grid. UIKit-origin
edits no longer send external-edit notifications back into the keyboard.

The iOS/visionOS view is non-opaque because its drawing surface uses a clear
background over the layer color. This prevents old backing-store glyph pixels
from reappearing after deletion or line redraw; Hydra's TerminalRenderingTests
compare UIKit raster snapshots, separately from input byte tests.

The host can show external native-editor preedit with `setExternalPreedit`.
This uses a separate cell-aligned overlay with UTF-16 selection geometry and
does not alter the emulator buffer, outgoing bytes, or scrollback. The iOS
cursor/layout hooks keep it aligned through remote output, scroll and resize.

Tests in SwiftTermInputTests exercise UIKit callbacks on an iOS simulator.
Real-device IME testing is additionally required; callback tests cannot emulate
the keyboard service's complete behavior.
