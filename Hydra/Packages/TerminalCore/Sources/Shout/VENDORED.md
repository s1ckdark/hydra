# Vendored Shout

This directory contains a vendored copy of [jakeheis/Shout](https://github.com/jakeheis/Shout) licensed under the MIT License.

## Local Patches

The following modifications have been made for Hydra's SSH terminal functionality:
- Public shell/PTY API for SSH shell session management
- SSH.hostKeyRaw() accessor to retrieve raw host keys
- Session.rawHostKey() accessor for Hydra's Trust-on-First-Use (TOFU) validation

Do not edit files in this directory directly. Updates should be submitted upstream or as patches to the Hydra integration layer.
