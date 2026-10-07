# hydra Makefile

# Variables
BINARY_NAME=hydra
SERVER_BINARY=hydra-server
VERSION=$(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
BUILD_TIME=$(shell date -u '+%Y-%m-%dT%H:%M:%SZ')
LDFLAGS=-ldflags "-X main.Version=$(VERSION) -X main.BuildTime=$(BUILD_TIME)"

# Go parameters
GOCMD=go
GOBUILD=$(GOCMD) build
GOTEST=$(GOCMD) test
GOMOD=$(GOCMD) mod
GOVET=$(GOCMD) vet
GOFMT=gofmt

# Build directories
BUILD_DIR=./build
CMD_CLI=./cmd/clusterctl
CMD_SERVER=./cmd/server

.PHONY: all build build-cli build-server clean test lint fmt vet deps run-server help hydra-app hydra-app-run android-build android-test android-instrumented-test

# Default target
all: deps build

## Build targets

build: build-cli build-server ## Build all binaries

build-cli: ## Build CLI binary
	@echo "Building CLI..."
	@mkdir -p $(BUILD_DIR)
	$(GOBUILD) $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME) $(CMD_CLI)

build-server: ## Build server binary
	@echo "Building server..."
	@mkdir -p $(BUILD_DIR)
	$(GOBUILD) $(LDFLAGS) -o $(BUILD_DIR)/$(SERVER_BINARY) $(CMD_SERVER)

## Development targets

deps: ## Download dependencies
	@echo "Downloading dependencies..."
	$(GOMOD) tidy
	$(GOMOD) download

run-server: ## Run server locally
	$(GOCMD) run $(CMD_SERVER)

run-cli: ## Run CLI locally
	$(GOCMD) run $(CMD_CLI)

## Test targets

test: ## Run tests
	@echo "Running tests..."
	$(GOTEST) -v ./...

test-coverage: ## Run tests with coverage
	@echo "Running tests with coverage..."
	$(GOTEST) -v -coverprofile=coverage.out ./...
	$(GOCMD) tool cover -html=coverage.out -o coverage.html

## Code quality targets

lint: ## Run linter (requires golangci-lint)
	@echo "Running linter..."
	@which golangci-lint > /dev/null || (echo "Installing golangci-lint..." && go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest)
	golangci-lint run ./...

fmt: ## Format code
	@echo "Formatting code..."
	$(GOFMT) -s -w .

vet: ## Run go vet
	@echo "Running go vet..."
	$(GOVET) ./...

check: fmt vet lint test ## Run all checks

## Installation targets

install: build-cli ## Install CLI to GOPATH/bin
	@echo "Installing $(BINARY_NAME)..."
	cp $(BUILD_DIR)/$(BINARY_NAME) $(GOPATH)/bin/

## Clean targets

clean: ## Remove build artifacts
	@echo "Cleaning..."
	rm -rf $(BUILD_DIR)
	rm -f coverage.out coverage.html

## Database targets

db-init: ## Initialize database with migrations
	@echo "Initializing database..."
	@mkdir -p ~/.hydra
	sqlite3 ~/.hydra/hydra.db < migrations/001_init.sql

## Tailscale Serve

serve: build-server ## Run server with Tailscale Serve (Tailnet-only access)
	@./scripts/serve.sh

## macOS app bundling

hydra-app: ## Build the Hydra macOS .app bundle (icon + Info.plist)
	@cd Hydra && ./scripts/bundle-app.sh release

hydra-app-run: hydra-app ## Build and launch the Hydra .app
	@open "Hydra/.build/arm64-apple-macosx/release/Hydra.app" || \
		open "Hydra/.build/release/Hydra.app"

## Docker targets

# 배포 대상 노드가 모두 x86_64 이므로 기본 플랫폼을 고정한다.
# 맥(arm64)에서 빌드해도 대상에서 그대로 실행되도록 하기 위함 — 덮어쓰려면 PLATFORM=linux/arm64
PLATFORM ?= linux/amd64

docker-build: ## Build Docker image (기본 linux/amd64)
	@echo "Building Docker image for $(PLATFORM)..."
	docker build --platform $(PLATFORM) --build-arg VERSION=$(VERSION) -t hydra:$(VERSION) .

# tailscaled 소켓 경로는 배포판마다 다르다 (Synology 등). 필요하면 덮어쓴다.
TS_SOCKET_DIR ?= /var/run/tailscale

# --network host 라 호스트 포트를 그대로 쓴다. 이미 점유된 포트가 있으면 바꿀 것.
# (예: racknerd 는 127.0.0.1:8080 을 crowdsec 이 쓰고 있어 SERVER_PORT=8081 필요)
SERVER_PORT ?= 8080

# tailnet 인터페이스에만 바인딩한다. 0.0.0.0 으로 열면 공인 IP 를 가진 호스트에서
# 방화벽에만 기대게 되는데, 그건 앱 밖에 있는 보장이라 배포처마다 달라진다.
# tailscale 이 없으면 루프백으로 떨어뜨린다 — 조용히 전체 공개되는 것보다 낫다.
SERVER_HOST ?= $(shell tailscale ip -4 2>/dev/null | head -1 || true)
ifeq ($(strip $(SERVER_HOST)),)
SERVER_HOST := 127.0.0.1
endif

# 컨테이너에는 USER 환경변수가 없어 config 의 기본 SSH 사용자(os.Getenv("USER"))가
# 빈 문자열이 된다. 호스트 사용자명을 명시적으로 넘긴다.
SSH_USER ?= $(shell id -un)

# 기본값은 config 의 ~/.ssh/id_rsa 지만, 최신 OpenSSH 가 ssh-rsa 서명을 기본 거부하는
# 배포판이 있어 ed25519 를 명시한다. 컨테이너 안 경로 기준.
SSH_KEY ?= /root/.ssh/id_ed25519

# ~/.ssh 는 읽기 전용으로 붙인다 — 컨테이너가 호스트 개인키를 건드리지 못하게.
# 대신 known_hosts 는 쓰기가 필요하므로 HYDRA_SSH_KNOWN_HOSTS 로 ~/.hydra 안으로 돌린다.
# 주의: 이 컨테이너는 root 로 호스트 netns 와 tailscaled 소켓을 공유한다.
# 소켓에 닿으면 호스트의 tailnet 정체성을 바꿀 수 있으므로(up/down/set) 신뢰 수준은
# 사실상 호스트 root 와 같다. 신뢰하는 이미지만 여기서 실행할 것.
docker-run: ## Run Docker container (Linux 호스트 전용 — 상시 데몬)
	@test "$$(uname -s)" = "Linux" || { echo "ERROR: --network host 는 Linux 호스트에서만 동작합니다 (Docker Desktop for Mac 불가)"; exit 1; }
	@test -S "$(TS_SOCKET_DIR)/tailscaled.sock" || { echo "ERROR: $(TS_SOCKET_DIR)/tailscaled.sock 없음 — tailscaled 가 떠 있는지, TS_SOCKET_DIR 이 맞는지 확인하세요"; exit 1; }
	@ss -lnt 2>/dev/null | grep -q ":$(SERVER_PORT) " && { echo "ERROR: 포트 $(SERVER_PORT) 이미 사용 중 — SERVER_PORT=<다른포트> 로 지정하세요"; exit 1; } || true
	docker rm -f hydra 2>/dev/null || true
	docker run -d --name hydra --restart unless-stopped \
		--network host \
		--security-opt no-new-privileges \
		-e HYDRA_SERVER_HOST=$(SERVER_HOST) \
		-e HYDRA_SERVER_PORT=$(SERVER_PORT) \
		-e HYDRA_SSH_KNOWN_HOSTS=/root/.hydra/known_hosts \
		-e HYDRA_SSH_USER=$(SSH_USER) \
		-e HYDRA_SSH_KEY=$(SSH_KEY) \
		-v $(TS_SOCKET_DIR):/var/run/tailscale \
		-v ~/.hydra:/root/.hydra \
		-v ~/.ssh:/root/.ssh:ro \
		hydra:$(VERSION)
	@echo "started. logs: make docker-logs"

docker-logs: ## Tail hydra container logs
	docker logs -f hydra

docker-stop: ## Stop and remove the hydra container
	docker rm -f hydra

## Help

help: ## Show this help
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

## Android targets
# Not wired into `build:` or `test:` on purpose — the Go CI must not acquire a
# JDK/Android SDK dependency.

ANDROID_JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS

# Only modules with instrumented tests. A bare `connectedDebugAndroidTest` also
# installs empty test APKs for every other module, which fail without a runner.
ANDROID_INSTRUMENTED_TASKS=$(shell cd android && find . -path '*/build' -prune -o -type d -path '*/src/androidTest' -print \
	| sed -e 's|^\./||' -e 's|/src/androidTest$$||' -e 's|/|:|g' -e 's|^|:|' -e 's|$$|:connectedDebugAndroidTest|' | sort)

android-build: ## Build the Android debug APK
	@echo "Building Android client..."
	cd android && JAVA_HOME=$(ANDROID_JAVA_HOME) ./gradlew :app:assembleDebug

android-instrumented-test: ## Run Android instrumented (on-device) tests — needs a running emulator or device
	@echo "Running Android instrumented tests..."
	cd android && JAVA_HOME=$(ANDROID_JAVA_HOME) ./gradlew $(ANDROID_INSTRUMENTED_TASKS)

android-test: ## Run Android unit tests
	@echo "Testing Android client..."
	cd android && JAVA_HOME=$(ANDROID_JAVA_HOME) ./gradlew testDebugUnitTest
