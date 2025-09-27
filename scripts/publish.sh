#!/usr/bin/env bash
set -euo pipefail

# One-click: build xray (in Docker), push to MicroK8s registry, update k8s DaemonSet image to :latest
# Requirements: docker available locally; remote MicroK8s registry reachable (REGISTRY=SERVER_IP:32000)

# REGISTRY="${REGISTRY:-10.144.8.65:32000}"
REGISTRY="${REGISTRY:-registry.vpn33.net:32000}" 
IMAGE_NAME="${IMAGE_NAME:-xray-core}"
PATCH_FILE="${PATCH_FILE:-/home/smart-network/k8s/apps/xray/public_in/overlays/dev/patch-daemonset.yaml}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-Dockerfile}"
PUSH_LATEST="${PUSH_LATEST:-true}"

# Resolve script dir and source root (module with go.mod)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: REGISTRY=<server_ip:32000> [IMAGE_NAME=xray-core] [PATCH_FILE=.../patch-daemonset.yaml] $0" 1>&2
  exit 1
}

if [[ -z "$REGISTRY" ]]; then
  echo "[ERR] Please provide REGISTRY env, e.g. REGISTRY=10.144.8.65:32000" 1>&2
  usage
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERR] docker not found. Install Docker first." 1>&2
  exit 2
fi

# Ensure we build in module root (contains go.mod)
cd "$SRC_DIR"
if [[ ! -f go.mod ]]; then
  echo "[ERR] go.mod not found in $SRC_DIR (wrong source directory)" 1>&2
  exit 3
fi

# Ensure Dockerfile exists; if not, create a minimal multi-stage Dockerfile
if [[ ! -f "$DOCKERFILE_PATH" ]]; then
  cat > "$DOCKERFILE_PATH" << 'EOF'
FROM golang:1.25-alpine AS builder
WORKDIR /src
RUN apk add --no-cache git ca-certificates
COPY . .
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '-s -w' -o /out/xray ./main

FROM gcr.io/distroless/base-debian12
WORKDIR /usr/local/etc/xray
COPY --from=builder /out/xray /usr/bin/xray
ENTRYPOINT ["/usr/bin/xray","run","-c","/usr/local/etc/xray/config.json"]
EOF
  echo "[INFO] Dockerfile created at $DOCKERFILE_PATH"
fi

DATE_TAG="dev-$(date +%Y%m%d%H%M)"
IMAGE_BASE="$REGISTRY/$IMAGE_NAME"
IMAGE_DATE_TAG="$IMAGE_BASE:$DATE_TAG"
IMAGE_LATEST_TAG="$IMAGE_BASE:latest"

echo "[INFO] Building image: $IMAGE_DATE_TAG (context: $SRC_DIR, dockerfile: $DOCKERFILE_PATH)"
docker build -t "$IMAGE_DATE_TAG" -f "$DOCKERFILE_PATH" "$SRC_DIR"

if [[ "$PUSH_LATEST" == "true" ]]; then
  docker tag "$IMAGE_DATE_TAG" "$IMAGE_LATEST_TAG"
fi

echo "[INFO] Pushing: $IMAGE_DATE_TAG"
docker push "$IMAGE_DATE_TAG"

if [[ "$PUSH_LATEST" == "true" ]]; then
  echo "[INFO] Pushing: $IMAGE_LATEST_TAG"
  docker push "$IMAGE_LATEST_TAG"
fi

# Done
echo "[DONE] Built & pushed: $IMAGE_DATE_TAG${PUSH_LATEST:+ and $IMAGE_LATEST_TAG}"
echo "[NEXT] 手动在 K8s 中更新镜像并发布，例如："
echo "  microk8s kubectl -n proxy set image ds/xray-daemonset xray=$IMAGE_LATEST_TAG"
echo "  microk8s kubectl -n proxy rollout status ds/xray-daemonset | cat"
