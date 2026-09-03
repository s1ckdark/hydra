# Vendored: Termux terminal emulator and view

Upstream: https://github.com/termux/termux-app
Commit:   3b66f8799635a4dba4a206563048ff0e6792c487

## License

`termux-app` is GPLv3, but its root `LICENSE.md` carves out an exception:
`terminal-view` and `terminal-emulator` derive from
[Terminal Emulator for Android](https://github.com/jackpal/Android-Terminal-Emulator)
and are **Apache-2.0**. Only those two directories are vendored here.

## Why vendored at all

Maven Central publishes no Android terminal-emulator or terminal-view library
(`terminal-emulator`, `terminalview`, `ansi-terminal` all return zero results;
`org.connectbot:sshlib` is an SSH library, not a view). Vendoring is the only
realistic option.

## What is vendored

`src/main/java/com/termux/**` — 20 files, copied byte-for-byte and never edited.

From `terminal-emulator/src/main/java/com/termux/terminal/` (12 of 14):

    ByteQueue, KeyHandler, Logger, TerminalBuffer, TerminalColorScheme,
    TerminalColors, TerminalEmulator, TerminalOutput, TerminalRow,
    TerminalSessionClient, TextStyle, WcWidth

From `terminal-view/src/main/java/com/termux/view/` (8):

    TerminalView, TerminalRenderer, GestureAndScaleRecognizer, TerminalViewClient,
    support/PopupWindowCompatGingerbread,
    textselection/{CursorController, TextSelectionCursorController, TextSelectionHandleView}

## What is excluded, and why

- `JNI.java` and `TerminalSession.java` — upstream's `TerminalSession` is
  `final` and creates a **local pty** through `JNI.createSubprocess`, backed by
  native `libtermux.so`. It cannot be subclassed or reused for an SSH channel.
- `terminal-emulator/src/main/jni/` — the C sources behind that JNI. Excluding
  them means this app needs no NDK at all.

## What we replaced

`src/main/kotlin/com/termux/terminal/TerminalSession.kt` is **ours**. It occupies
the same package and class name so the vendored `TerminalView` links against it
unmodified.

`TerminalView` is 1,500 lines but calls only four members on a session:

    mTermSession.write(...)          x3
    mTermSession.getEmulator()       x2
    mTermSession.writeCodePoint(...) x1
    mTermSession.updateSize(...)     x1

Satisfying those four is enough, so the patch surface is exactly one file.

`src/main/kotlin/com/hydra/android/core/terminal/HydraSessionClient.kt` implements
the vendored `TerminalSessionClient` interface (16 methods, mostly logging).
`setTerminalShellPid` is pty-specific and is a deliberate no-op.

## Re-vendoring

1. Re-download the file list above at the new commit.
2. Re-check the four `mTermSession.` call sites in `TerminalView.java` and the
   `TerminalEmulator` constructor signature against our `TerminalSession.kt`.
3. Update the commit hash at the top of this file.

Never edit a file under `src/main/java/` — that is what keeps step 1 a plain
overwrite.
