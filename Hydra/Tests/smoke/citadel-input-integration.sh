#!/usr/bin/env bash
# Run the Swift tests against an isolated, localhost-only OpenSSH fixture.
# Uses a cached image and a disposable key; never reads ~/.ssh or reuses/removes
# an existing container. Extra arguments are forwarded to `swift test`.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/hydra-citadel-qa.XXXXXX")"
fixture_id=""
cleanup() {
    if [[ "$fixture_id" =~ ^[0-9a-f]{64}$ ]]; then
        docker stop -t 2 "$fixture_id" >/dev/null 2>&1 || true
        docker rm -v "$fixture_id" >/dev/null 2>&1 || true
    fi
    # Only known generated files inside our fresh mktemp directory are removed.
    if [[ "$fixture_dir" == */hydra-citadel-qa.* ]]; then
        [[ ! -e "$fixture_dir/client_key" ]] || unlink "$fixture_dir/client_key"
        [[ ! -e "$fixture_dir/client_key.pub" ]] || unlink "$fixture_dir/client_key.pub"
        rmdir "$fixture_dir" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker info --format '{{.ServerVersion}}' >/dev/null
image_id="$(docker image inspect lscr.io/linuxserver/openssh-server:latest --format '{{.Id}}')"
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Cached OpenSSH image unavailable" >&2; exit 1; }
ssh-keygen -q -t ed25519 -N '' -C hydra-citadel-qa -f "$fixture_dir/client_key"
public_key="$(< "$fixture_dir/client_key.pub")"
# This password belongs only to the disposable, localhost-bound test account.
# It is never printed or written to a credential store.
fixture_password="$(openssl rand -base64 24)"
fixture_id="$(docker run --pull never -d --label codex.task=hydra-citadel-qa \
    -p 127.0.0.1::2222 --tmpfs /config \
    -e "PUBLIC_KEY=$public_key" -e USER_NAME=smoke \
    -e SUDO_ACCESS=false -e PASSWORD_ACCESS=true \
    -e "USER_PASSWORD=$fixture_password" "$image_id")"
[[ "$fixture_id" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid fixture container ID" >&2; exit 1; }
binding="$(docker port "$fixture_id" 2222/tcp)"
[[ "$binding" =~ ^127\.0\.0\.1:([0-9]+)$ ]] || { echo "Fixture is not localhost-only" >&2; exit 1; }
fixture_port="${BASH_REMATCH[1]}"
ready=false
for ((attempt = 0; attempt < 30; attempt++)); do
    if ssh-keyscan -T 1 -p "$fixture_port" 127.0.0.1 >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.2
done
[[ "$ready" == true ]] || { echo "OpenSSH fixture did not become ready" >&2; exit 1; }

echo "Running tests against disposable SSH fixture on localhost:$fixture_port"
cd "$project_dir"
HYDRA_CITADEL_SMOKE_HOST=127.0.0.1 \
HYDRA_CITADEL_SMOKE_PORT="$fixture_port" \
HYDRA_CITADEL_SMOKE_USER=smoke \
HYDRA_CITADEL_SMOKE_KEY="$fixture_dir/client_key" \
HYDRA_CITADEL_SMOKE_FIXTURE=disposable-localhost \
HYDRA_CITADEL_SMOKE_PASSWORD="$fixture_password" \
    swift test "$@"
