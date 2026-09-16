# Hydra iOS (B2a/B2b)

Minimal iOS app target introduced in sub-project B2a. Shares the cross-platform
service layer with the macOS app; the device-list and terminal UI (B2b) are now
wired up, making this the iPad SSH terminal MVP.

## Build (simulator)
    cd Hydra
    xcodegen generate            # regenerate Hydra.xcodeproj from project.yml
    xcodebuild -project Hydra.xcodeproj -scheme HydraiOS \
      -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

## Terminal input tests
    xcodebuild -project Hydra.xcodeproj -scheme TerminalInputTests \
      -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=latest' \
      test CODE_SIGNING_ALLOWED=NO

`TerminalInputValidation` runs both the native unit/raster tests and UI keyboard
tests in one Xcode scheme. Keep the real device unlocked and do not mix manual
keyboard input into an automated run. After automated tests, verify the external
keyboard separately; software-key taps do not establish Bluetooth/USB behavior.

For real Citadel/TerminalSession UTF-8, resize and reconnect integration on macOS:

    Tests/smoke/citadel-input-integration.sh

This requires a running Docker engine and an already cached
`lscr.io/linuxserver/openssh-server` image. It uses a localhost-only ephemeral
container and generated test key/password, cleans them up on exit, and does not read user
SSH credentials or change known_hosts. Arguments pass through to `swift test`.

Input uses the native UIKit editor with its draft displayed immediately at the
terminal cursor. There is no separate bottom input row. The provisional display
wraps on terminal cells, follows the cursor/viewport, and is removed before
committed text is sent; it never enters the remote-output grid or scrollback.
The `전송` button beside the terminal accessory keys commits the current draft
without adding a space or Return.

**Live display is separate from SSH transmission.** Korean keyboards revise text
even when `markedTextRange` is nil, so their unfinished word still stays local
until space, punctuation, Return, a terminal control key, or an input-language
switch. English input is sent immediately. This does not claim per-syllable
Korean SSH transmission. Paste retains the terminal's bracketed-paste behavior.
We retain the tested native editor: switching to WebKit alone does not establish
a reliable Korean composition boundary ([WebKit issue 274700](https://bugs.webkit.org/show_bug.cgi?id=274700)).
External-keyboard Control+Space is left to iPadOS for input-language switching,
instead of being encoded as a terminal NUL. Control+letter shortcuts still go
to the terminal. Shift key lifecycles remain with the native editor.

The iOS renderer draws transparent glyph content over its layer background, so
it must not advertise an opaque backing store. `TerminalRenderingTests` compares
actual UIKit raster images after Latin deletion/Korean replacement and CR/EL
line redraws, preventing deleted glyphs from reappearing under later frames.
`ExternalPreeditTests` and `InlineTerminalInputTests` separately verify immediate
draft display, CJK wrapping, cursor tracking, teardown, and no provisional bytes.

`TerminalInputUITests` opens a Debug-only local echo screen and taps real Korean
software-keyboard keys. It is not an SSH test. The screen records only its test
input in `Documents/terminal-input-test-trace.txt`; the normal terminal does not
record input. Keep the iPad unlocked and don't type manually during the run.
Synthesizing hardware keys with `typeKey` is not an IME test: it produced raw
jamo even in a plain native UITextView on the same device.

For manual external-keyboard diagnosis, launch with `--terminal-input-ui-test`;
add `--native-keyboard-baseline` to compare an ordinary UITextView without any
terminal key routing. Both diagnostic modes save a bounded UIKit trace and an
app-view screenshot in Documents. They do not access GCKeyboard by default.
The separate `--observe-hardware-keyboard` flag opts into GameController key/Shift
observation for controlled comparisons only: the observer itself must be treated
as an experimental variable, not assumed passive. No automated typing should run
during a manual comparison. Missing hardware state is recorded as unavailable.

The Debug app also exposes Settings → 개발자 진단 → 키보드 입력 비교
(`--clean-keyboard-comparison` when launched from the development tools).
Test A 기본 first, then B 입력 설정, then C 터미널 with the same external
keyboard and text (`어떨까?`, English `ER?`). A/B have no delegates, hardware
observers, typing logs or continuous screenshots; C is constructed lazily.
Only pressing 결과 저장 reads the editors and writes
`Documents/clean-keyboard-comparison.json` and an app-only screenshot
`Documents/clean-keyboard-comparison.png` (no continuous capture). C records
emitted bytes separately from its unsent inline draft and displays a local line
echo (not an SSH connection). To verify live display, save once after typing
`어떨까` without punctuation or space, then commit and save again.
The saved sample also includes the active input language. The
`CleanKeyboardSwitchUITests` test synthesizes only Control+Space and checks that
the language changes without emitting terminal bytes; it does not verify
physical-keyboard Korean composition. These manual results are required before attributing a
missing modifier to the device or choosing the terminal input implementation.

If a draft extends below the viewport, only its preview shifts upward to keep
the draft caret visible; earlier output is temporarily covered, not modified.
Candidate windows and native touch selection across wrapped drafts still need
separate real-device CJK checks before claiming complete inline-IME parity.

## Notes
- `project.yml` is the source of truth; `Hydra.xcodeproj` is generated (gitignored).
- The iOS primary icon is `HydraiOS/Assets.xcassets/AppIcon.appiconset` and is
  explicitly selected by `ASSETCATALOG_COMPILER_APPICON_NAME`. Its 1024px image
  reuses the existing macOS Hydra artwork, with the unused opaque alpha channel
  removed for iOS packaging; it is not a redesigned logo.
- iOS uses the pure-Swift Citadel SSH backend (libssh2 is macOS-only).
- SwiftTerm is kept in `Packages/SwiftTerm` so Hydra can test and maintain its
  UIKit marked-text integration. See `Packages/SwiftTerm/VENDORED.md`.
- macOS build is unchanged: `make hydra-app` (SwiftPM).
- Device install / code signing: B2b.

## Using it (B2b)
1. Settings tab → set server URL (`http://<mac-LAN-IP>:8080`) and SSH username.
2. Settings → SSH 키 관리 → paste your ed25519 private key (or import from Files) → 저장.
3. Devices tab → tap an SSH-enabled node → trust the host key → shell.

## Language, theme and Tailscale refresh

Settings includes System/Korean/English display language and System/Light/Dark
theme. Preferences persist and apply without rebuilding the root navigation or
changing the iPad's keyboard/system language. English and Korean resources cover
the main navigation, settings and SSH registration instructions/error messages.

Settings → Tailscale → **기기 정보 업데이트 / Update device information** requests
`GET /api/devices?refresh=tailscale`. This bypasses both server inventory caches
without running SSH metrics collection. A successful response must include
`X-Hydra-Tailscale-Refresh: fresh`; otherwise the app reports an unsupported older
server instead of claiming a fresh update. Failures keep the previous displayed
list and last successful timestamp. Settings, Devices and Dashboard share the
updated device array; an older request cannot overwrite a manual refresh result.

The server forces `TAILSCALE_BE_CLI=1` for Tailscale child processes, as documented
in the [Tailscale CLI reference](https://tailscale.com/docs/reference/tailscale-cli?tab=macos).
Without it, the bundled macOS executable can attempt GUI launch from a background
server and return non-JSON output, leaving the app on an old inventory snapshot.

## Registering the iPad key on a server

Settings → SSH 키 관리 → 서버에 공개키 등록 opens registration for the currently
saved private key (Ed25519 or RSA; unencrypted keys). Select an SSH-enabled device
or enter its address, check the account, and enter that server account's password.
The registration account starts with Settings' SSH username; editing it here does
not change the username used by the terminal. The port is 22, as in the terminal.

Confirm the target account and public-key fingerprint. For a new host, compare
the displayed host fingerprint before trusting it. The host check runs before
password authentication; the password is not saved. Registration appends to that
account's `~/.ssh/authorized_keys`, preserves existing entries and key restrictions,
and verifies a fresh key-authenticated connection before reporting success.

The iOS app stores its host trust records in
`Library/Application Support/Hydra/SSH/known_hosts`. Registration and the terminal
share this path and create its parent folders when needed. A readable legacy
app-root `.ssh/known_hosts` is migrated atomically with its original bytes retained;
the old copy remains for recovery. Corrupt or unreadable records stop the connection
instead of becoming an unknown host. Trust must be saved before opening a terminal.

The Debug-only `--ssh-trust-storage-probe` launch flag checks local root-directory
creation and read/write/append in the production support directory using temporary
probe files. It reports only stage and error domain/code in
`Documents/ssh-trust-storage-diagnostic.json`; no credentials or host entries are
included and no server connection is made.

If password authentication is disabled, use **서버 등록 명령 복사** and run the
command in an existing session on that server as the chosen account. The command
contains only the public key and checks the current account before writing.
Cancellation or connection loss after submission may leave the key installed;
the screen reports that uncertainty instead of claiming a completed login.

Registration errors include the cause and a next step: DNS/network failure,
connection refusal/timeout, authentication rejection, unsupported password
authentication, local trust-record failure, and remote path/permission/write
errors remain distinct. A generic authentication rejection does not prove the
password is wrong: the account or server login policy can also cause it.
The screen separately reports a confirmed registration followed by failed key
login, and an interrupted command whose registration outcome is still unknown.
Only fixed diagnostic text and remote exit codes are displayed; raw server
errors and credentials are never included in these messages.

`SSHKeyRegistrationIntegrationTests` covers registration, fresh key login,
idempotent retry and host rejection against the disposable OpenSSH fixture above.
`SSHKeyRegistrationUITests` uses an injected synthetic key/service to verify the
confirmation and host-trust screens without accessing saved credentials.

Real device install requires signing (automatic signing + your Apple ID team in
Xcode; free personal team re-signs weekly). Citadel needs your ed25519 key
authorized on the target node.
