# syntax=docker/dockerfile:1

# ---- build ----
FROM golang:1.25.6-bookworm AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

# mattn/go-sqlite3 가 cgo 라 CGO_ENABLED=1 이 필수.
# 따라서 런타임 이미지도 같은 glibc 계열(bookworm)이어야 링크가 맞는다 — alpine(musl) 불가.
ARG VERSION=dev
RUN CGO_ENABLED=1 GOOS=linux go build -trimpath \
        -ldflags "-X main.Version=${VERSION} -X main.BuildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        -o /out/hydra-server ./cmd/server

# ---- runtime ----
FROM debian:bookworm-slim

# ca-certificates : AI 프로바이더(Claude/OpenAI) HTTPS 호출용
# openssh-client  : `tailscale ssh` 는 시스템 ssh 를 exec 한다. 없으면
#                   "no system 'ssh' command found" 로 원격 실행이 통째로 실패한다.
#                   기본 경로인 Go 네이티브 SSH 도 known_hosts 해석에 쓰므로 양쪽 다 필요.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssh-client \
 && rm -rf /var/lib/apt/lists/*

# 백엔드가 tailscale CLI 를 셸아웃한다 (status / ssh / scp / file cp).
# tailscaled 는 넣지 않는다 — 호스트의 /var/run/tailscale 소켓을 마운트해 재사용한다.
# 재현성을 위해 stable 대신 버전을 고정한다.
COPY --from=tailscale/tailscale:v1.102.3 /usr/local/bin/tailscale /usr/local/bin/tailscale

COPY --from=build /out/hydra-server /usr/local/bin/hydra-server

# VOLUME 은 두지 않는다 — -v 없이 실행하면 익명 볼륨이 생겼다가 --rm 과 함께
# 삭제되어 DB 가 조용히 날아간다. 마운트는 Makefile/문서에서 강제한다.

# --network host 로 실행하므로 게시 의미는 없고 문서용
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/hydra-server"]
