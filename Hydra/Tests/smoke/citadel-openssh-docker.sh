#!/usr/bin/env bash
# Launch a throwaway OpenSSH container authorizing the current user's ed25519
# public key, for the Citadel backend smoke. Prints the HOST/PORT/USER to export.
#   Usage: citadel-openssh-docker.sh [host_port]   (default 2222)
#   Teardown: docker rm -f hydra-citadel-smoke
set -euo pipefail
PORT="${1:-2222}"
PUB="${HYDRA_CITADEL_SMOKE_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
NAME="hydra-citadel-smoke"
[ -f "$PUB" ] || { echo "no ed25519 pubkey at $PUB" >&2; exit 1; }
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "${PORT}:2222" \
  -e PUBLIC_KEY="$(cat "$PUB")" -e USER_NAME=smoke -e SUDO_ACCESS=false \
  lscr.io/linuxserver/openssh-server:latest >/dev/null
# wait for sshd to accept connections
for i in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then exec 3>&- 3<&-; break; fi
  sleep 0.5
done
echo "READY host=127.0.0.1 port=${PORT} user=smoke"
echo "run: HYDRA_CITADEL_SMOKE_HOST=127.0.0.1 HYDRA_CITADEL_SMOKE_PORT=${PORT} HYDRA_CITADEL_SMOKE_USER=smoke swift test --filter CitadelSessionSmokeTests"
