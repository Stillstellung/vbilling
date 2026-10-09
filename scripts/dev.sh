#!/usr/bin/env bash
# Development loop against the loft-cluster control plane cluster.
#
# Builds the working tree into an image on ghcr.io/stillstellung/vbilling and
# runs it as the vbilling-dev release (namespace vbilling-dev), next to the
# stable vbilling release (namespace vbilling-system, upstream image).
#
# Usage: scripts/dev.sh <command>
#   kubeconfig     write .dev/loft-cluster.kubeconfig through the vCluster Platform CLI
#   check          lint and test (gofmt, go vet, go test -race, helm lint)
#   image          build the working tree for linux/amd64 and push it, tagged dev-<sha>[-dirty-<time>]
#   deploy [tag]   install or upgrade vbilling-dev with an image tag (default: the last pushed one)
#   up             check, image and deploy in one go
#   stable         upgrade the stable release with the shared values (upstream image)
#   status [dev|stable]   pods and /api/v1/status
#   logs [dev|stable]     follow the logs
#   forward [dev|stable]  port-forward to 127.0.0.1 (stable 8080, dev 8081)
#   kubectl ...    run kubectl against loft-cluster
#
# Every kubectl and helm call uses .dev/loft-cluster.kubeconfig, never
# ~/.kube/config, and the kubeconfig is refused unless it points at
# $PLATFORM_HOST, so nothing here can reach another cluster.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLATFORM_HOST=${PLATFORM_HOST:-3e2vnbp.loft.host}
PLATFORM_CLUSTER=${PLATFORM_CLUSTER:-loft-cluster}
DEV_IMAGE=${DEV_IMAGE:-ghcr.io/stillstellung/vbilling}
DEV_DIR=$ROOT/.dev
KUBECONFIG_FILE=$DEV_DIR/loft-cluster.kubeconfig
VALUES=$ROOT/deploy/dev/loft-cluster-values.yaml
CHART=$ROOT/deploy/helm/vbilling

die() { echo "dev.sh: $*" >&2; exit 1; }

release() { # dev|stable -> "<release> <namespace> <local port>"
  case ${1:-dev} in
    dev) echo "vbilling-dev vbilling-dev 8081" ;;
    stable) echo "vbilling vbilling-system 8080" ;;
    *) die "unknown target $1 (dev or stable)" ;;
  esac
}

kubeconfig() {
  mkdir -p "$DEV_DIR"
  local tmp
  tmp=$(mktemp "$DEV_DIR/kubeconfig.XXXXXX")
  vcluster platform connect cluster "$PLATFORM_CLUSTER" --print >"$tmp"
  chmod 600 "$tmp"
  grep -q "server: https://$PLATFORM_HOST/" "$tmp" || {
    rm -f "$tmp"
    die "the vcluster CLI is not logged into $PLATFORM_HOST; refusing to write a kubeconfig"
  }
  mv "$tmp" "$KUBECONFIG_FILE"
  echo "wrote $KUBECONFIG_FILE"
}

kube_env() {
  [[ -f $KUBECONFIG_FILE ]] || kubeconfig >&2
  grep -q "server: https://$PLATFORM_HOST/" "$KUBECONFIG_FILE" ||
    die "$KUBECONFIG_FILE does not point at $PLATFORM_HOST"
  export KUBECONFIG=$KUBECONFIG_FILE
}

check() {
  cd "$ROOT"
  make lint
  go test -race ./...
  helm lint "$CHART"
}

image() {
  cd "$ROOT"
  local sha tag
  sha=$(git rev-parse --short HEAD)
  tag=dev-$sha
  [[ -z $(git status --porcelain) ]] || tag=$tag-dirty-$(date -u +%Y%m%d%H%M%S)
  docker build --platform linux/amd64 --build-arg VERSION="0.2.0-$tag" -t "$DEV_IMAGE:$tag" .
  docker push "$DEV_IMAGE:$tag" ||
    die "push failed; log in once with: gh auth refresh -h github.com -s write:packages && gh auth token | docker login ghcr.io -u Stillstellung --password-stdin"
  mkdir -p "$DEV_DIR"
  echo "$tag" >"$DEV_DIR/last-tag"
  echo "pushed $DEV_IMAGE:$tag"
}

deploy() {
  local tag=${1:-}
  [[ -n $tag ]] || tag=$(cat "$DEV_DIR/last-tag" 2>/dev/null) || die "no tag given and no image pushed yet"
  kube_env
  helm upgrade --install vbilling-dev "$CHART" -n vbilling-dev --create-namespace \
    -f "$VALUES" --set image.repository="$DEV_IMAGE" --set image.tag="$tag" --wait --timeout 5m
  kubectl -n vbilling-dev rollout status statefulset/vbilling-dev --timeout 3m
}

stable() {
  kube_env
  helm upgrade --install vbilling "$CHART" -n vbilling-system --create-namespace -f "$VALUES" --wait --timeout 5m
}

status() {
  read -r rel ns _ < <(release "${1:-dev}")
  kube_env
  kubectl -n "$ns" get pods,pvc
  kubectl -n "$ns" get statefulset "$rel" -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
  local port=18099 pf
  kubectl -n "$ns" port-forward "svc/$rel" "$port:8080" >/dev/null 2>&1 &
  pf=$!
  trap 'kill $pf 2>/dev/null' RETURN
  for _ in $(seq 1 20); do curl -fs "localhost:$port/readyz" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fs "localhost:$port/api/v1/status"
  echo
}

logs() {
  read -r rel ns _ < <(release "${1:-dev}")
  kube_env
  kubectl -n "$ns" logs -f "statefulset/$rel"
}

forward() {
  read -r rel ns port < <(release "${1:-dev}")
  kube_env
  echo "http://127.0.0.1:$port/  (from another machine: ssh -N -L $port:localhost:$port <user>@<this host>)"
  kubectl -n "$ns" port-forward "svc/$rel" "$port:8080" --address 127.0.0.1
}

cmd=${1:-}
[[ -n $cmd ]] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
shift
case $cmd in
  kubeconfig) kubeconfig ;;
  check) check ;;
  image) image ;;
  deploy) deploy "$@" ;;
  up) check && image && deploy ;;
  stable) stable ;;
  status) status "$@" ;;
  logs) logs "$@" ;;
  forward) forward "$@" ;;
  kubectl) kube_env; kubectl "$@" ;;
  *) die "unknown command $cmd" ;;
esac
