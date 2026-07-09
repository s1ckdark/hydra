# Smoke tests

Opt-in, real-network smoke tests. These never run in CI by default; they are
gated behind environment variables so `swift test` stays hermetic unless a
human explicitly opts in.

## Citadel backend smoke (B1)

Repeatable (Docker):

    Hydra/Tests/smoke/citadel-openssh-docker.sh 2222
    HYDRA_CITADEL_SMOKE_HOST=127.0.0.1 HYDRA_CITADEL_SMOKE_PORT=2222 HYDRA_CITADEL_SMOKE_USER=smoke \
      swift test --package-path Hydra --filter CitadelSessionSmokeTests
    docker rm -f hydra-citadel-smoke

Real node (one-off — Citadel needs your ed25519 authorized there):

    ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<node>
    HYDRA_CITADEL_SMOKE_HOST=<node> HYDRA_CITADEL_SMOKE_USER=<user> \
      swift test --package-path Hydra --filter CitadelSessionSmokeTests

Or eyeball it in the app:

    HYDRA_SSH_BACKEND=citadel <launch the mac app>   # terminal tab now uses Citadel

Without `HYDRA_CITADEL_SMOKE_HOST` set, `CitadelSessionSmokeTests` reports
`XCTSkip` (not a failure) — safe to leave in the default test filter.
