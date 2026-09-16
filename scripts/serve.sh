#!/bin/bash
# Tailscale Serve로 Cluster Manager 실행
# Tailnet 내부에서만 접근 가능 (자동 인증)

set -euo pipefail

PORT=${PORT:-8080}
BINARY="./build/hydra-server"

# 항상 재빌드 — build/ 에 남은 낡은 산출물이 조용히 실행되는 것을 막는다
echo "Building server..."
make build-server

# 서버 시작 (백그라운드)
# PORT 는 서버에도 같이 넘긴다 — 안 넘기면 tailscale serve 만 $PORT 로 프록시하고
# 서버는 config 의 기본 포트에서 듣는 조용한 오설정이 된다.
echo "Starting Cluster Manager on port $PORT..."
HYDRA_SERVER_PORT="$PORT" $BINARY &
SERVER_PID=$!

# trap 은 PID 를 얻자마자 건다 — 아래 tailscale serve 가 실패하면 set -e 로 즉시
# 종료되는데, 그때 trap 이 없으면 서버가 고아로 남아 포트를 계속 물고 있다.
trap 'kill $SERVER_PID 2>/dev/null; tailscale serve reset 2>/dev/null' EXIT

# Tailscale Serve 설정
echo "Exposing via Tailscale Serve..."
tailscale serve --bg $PORT

echo ""
echo "✅ Cluster Manager is running!"
echo ""
echo "Access URLs:"
echo "  - Local:     http://localhost:$PORT"
echo "  - Tailscale: https://$(tailscale status --self --json | jq -r '.Self.DNSName' | sed 's/\.$//')/"
echo ""
echo "Only users in your Tailnet can access the Tailscale URL."
echo ""
echo "To stop: kill $SERVER_PID && tailscale serve reset"

# 서버 대기
wait $SERVER_PID
