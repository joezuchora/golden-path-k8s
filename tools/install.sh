#!/usr/bin/env bash
# install.sh: install the pinned CLIs into ./.bin (D-048).
#
# Every download is checked twice:
#   1. against the checksum the project publishes for that release, and
#   2. against tools/checksums.lock, which is committed, so a re-published asset can't change silently.
# `--lock` records missing entries in the lock file (only after check 1 passes). Review the diff before committing it.
# `--lock-platform <os>-<arch>` records lock entries for another platform from the publisher's checksum files, without
# downloading or installing (the first real install on that platform then proves the file matches).
#
# Usage: bash tools/install.sh [--lock | --lock-platform <os>-<arch>] [tool ...]
# Platforms: linux-amd64, linux-arm64, darwin-amd64, darwin-arm64, windows-amd64 (Git Bash or WSL)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.bin"
LOCK="$ROOT/tools/checksums.lock"
# Pins come from tools/versions.env; any of them can be overridden from the environment for an upgrade trial, e.g.
#   CROSSPLANE_CLI_VERSION=v2.5.0 bash tools/install.sh --lock crossplane
# An environment variable that is already set wins over the file.
while IFS='=' read -r k val; do
  [[ $k =~ ^[A-Z0-9_]+$ ]] || continue
  [ -n "${!k:-}" ] || printf -v "$k" '%s' "$val"
done <"$ROOT/tools/versions.env"

WRITE_LOCK=0; LOCK_ONLY=0
case "${1:-}" in
  --lock) WRITE_LOCK=1; shift ;;
  --lock-platform) WRITE_LOCK=1; LOCK_ONLY=1; PLATFORM="${2:?--lock-platform needs <os>-<arch>}"; shift 2 ;;
esac

if [ $LOCK_ONLY -eq 1 ]; then
  OS="${PLATFORM%-*}"; ARCH="${PLATFORM#*-}"
else
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    Linux)  OS=linux ;;
    Darwin) OS=darwin ;;
    *) echo "unsupported OS: $(uname -s)"; exit 2 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) echo "unsupported architecture: $(uname -m)"; exit 2 ;;
  esac
fi
case "$OS-$ARCH" in
  linux-amd64|linux-arm64|darwin-amd64|darwin-arm64|windows-amd64) ;;
  *) echo "unsupported platform: $OS-$ARCH (supported: linux-amd64, linux-arm64, darwin-amd64, darwin-arm64, windows-amd64)"; exit 2 ;;
esac
EXE=; [ "$OS" = windows ] && EXE=.exe

mkdir -p "$BIN" && touch "$LOCK"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# upstream_sum <checksum-url> <asset-name>: the hash the project publishes for one asset
upstream_sum() {
  if [ -f "$1" ]; then cp "$1" "$TMP/sums"; else fetch "$1" "$TMP/sums"; fi
  local line
  line="$(grep -E "(^|[ *./])$2\$" "$TMP/sums" | head -1 || true)"
  if [ -z "$line" ] && [ "$(wc -w <"$TMP/sums")" -eq 1 ]; then line="$(cat "$TMP/sums")"; fi
  [ -n "$line" ] || { echo "no checksum for $2 in $1" >&2; return 1; }
  echo "${line%% *}"
}

verify() { # <tool> <version> <file> <asset> <checksum-url>
  local tool=$1 v=$2 file=$3 asset=$4 sumurl=$5 got want key locked
  got="$(sha "$file")"
  want="$(upstream_sum "$sumurl" "$asset")"
  [ "$got" = "$want" ] || { echo "FAIL $tool: $asset sha256 $got != upstream $want"; exit 1; }
  key="$tool $v $OS-$ARCH $asset"
  locked="$(grep -F "$key " "$LOCK" | awk '{print $5}' || true)"
  if [ -z "$locked" ]; then
    if [ $WRITE_LOCK -eq 1 ]; then echo "$key $got" >>"$LOCK"; echo "LOCK  $key"
    else echo "FAIL $tool: no entry in tools/checksums.lock for '$key' (run: bash tools/install.sh --lock $tool)"; exit 1; fi
  elif [ "$locked" != "$got" ]; then
    echo "FAIL $tool: $asset sha256 $got != lock $locked"; exit 1
  fi
}

# extract <archive> <member-basename> <dest>
extract() {
  local a=$1 m=$2 d=$3 dir="$TMP/x"; rm -rf "$dir"; mkdir -p "$dir"
  case "$a" in *.zip) unzip -q -o "$a" -d "$dir" ;; *) tar -xzf "$a" -C "$dir" ;; esac
  local f; f="$(find "$dir" -type f -name "$m" | head -1)"
  [ -n "$f" ] || { echo "member $m not found in $a"; exit 1; }
  mv "$f" "$d"
}

install_one() {
  local tool=$1 v url asset sumurl member arch_k8s
  local dest="$BIN/$tool$EXE"
  case "$tool" in
    kind) v=$KIND_VERSION; asset="kind-$OS-$ARCH"
      url="https://github.com/kubernetes-sigs/kind/releases/download/$v/$asset"; sumurl="$url.sha256sum" ;;
    kubectl) v=$KUBECTL_VERSION; asset="kubectl$EXE"
      url="https://dl.k8s.io/release/$v/bin/$OS/$ARCH/$asset"; sumurl="$url.sha256" ;;
    helm) v=$HELM_VERSION
      if [ "$OS" = windows ]; then asset="helm-$v-$OS-$ARCH.zip"; else asset="helm-$v-$OS-$ARCH.tar.gz"; fi
      url="https://get.helm.sh/$asset"; sumurl="$url.sha256sum"; member="helm$EXE" ;;
    kyverno) v=$KYVERNO_VERSION; arch_k8s=x86_64; [ "$ARCH" = arm64 ] && arch_k8s=arm64
      if [ "$OS" = windows ]; then asset="kyverno-cli_${v}_${OS}_${arch_k8s}.zip"; else asset="kyverno-cli_${v}_${OS}_${arch_k8s}.tar.gz"; fi
      url="https://github.com/kyverno/kyverno/releases/download/$v/$asset"
      sumurl="https://github.com/kyverno/kyverno/releases/download/$v/checksums.txt"; member="kyverno$EXE" ;;
    chainsaw) v=$CHAINSAW_VERSION; asset="chainsaw_${OS}_${ARCH}.tar.gz"
      url="https://github.com/kyverno/chainsaw/releases/download/$v/$asset"
      sumurl="https://github.com/kyverno/chainsaw/releases/download/$v/checksums.txt"; member="chainsaw$EXE" ;;
    # The bundle, not the bare binary: on Linux and Windows the bare binary's published .sha256 doesn't match it (F34).
    crossplane) v=$CROSSPLANE_CLI_VERSION; asset="crossplane-cli.tar.gz"
      url="https://cli.crossplane.io/stable/$v/bundle/${OS}_${ARCH}/$asset"; sumurl="$url.sha256"; member="crossplane$EXE" ;;
    # Infrastructure engine for infra/ (D-088, ADR-0009). HashiCorp publishes one SHA256SUMS per release.
    terraform) v=$TERRAFORM_VERSION; asset="terraform_${v#v}_${OS}_${ARCH}.zip"
      url="https://releases.hashicorp.com/terraform/${v#v}/$asset"
      sumurl="https://releases.hashicorp.com/terraform/${v#v}/terraform_${v#v}_SHA256SUMS"; member="terraform$EXE" ;;
    tflint) v=$TFLINT_VERSION; asset="tflint_${OS}_${ARCH}.zip"
      url="https://github.com/terraform-linters/tflint/releases/download/$v/$asset"
      sumurl="https://github.com/terraform-linters/tflint/releases/download/$v/checksums.txt"; member="tflint$EXE" ;;
    kubeconform) v=$KUBECONFORM_VERSION
      if [ "$OS" = windows ]; then asset="kubeconform-$OS-$ARCH.zip"; else asset="kubeconform-$OS-$ARCH.tar.gz"; fi
      url="https://github.com/yannh/kubeconform/releases/download/$v/$asset"
      sumurl="https://github.com/yannh/kubeconform/releases/download/$v/CHECKSUMS"; member="kubeconform$EXE" ;;
    cosign) v=$COSIGN_VERSION; asset="cosign-$OS-$ARCH$EXE"
      url="https://github.com/sigstore/cosign/releases/download/$v/$asset"
      sumurl="https://github.com/sigstore/cosign/releases/download/$v/cosign_checksums.txt" ;;
    jq) v=$JQ_VERSION
      if [ "$OS" = darwin ]; then asset="jq-macos-$ARCH"; else asset="jq-$OS-$ARCH$EXE"; fi
      url="https://github.com/jqlang/jq/releases/download/$v/$asset"
      sumurl="https://github.com/jqlang/jq/releases/download/$v/sha256sum.txt" ;;
    yq) v=$YQ_VERSION; asset="yq_${OS}_${ARCH}$EXE"
      url="https://github.com/mikefarah/yq/releases/download/$v/$asset"
      sumurl="https://github.com/mikefarah/yq/releases/download/$v/checksums" ;;
    cilium) v=$CILIUM_CLI_VERSION
      if [ "$OS" = windows ]; then asset="cilium-$OS-$ARCH.zip"; else asset="cilium-$OS-$ARCH.tar.gz"; fi
      url="https://github.com/cilium/cilium-cli/releases/download/$v/$asset"; sumurl="$url.sha256sum"; member="cilium$EXE" ;;
    argocd) v=$ARGOCD_CLI_VERSION; asset="argocd-$OS-$ARCH$EXE"
      url="https://github.com/argoproj/argo-cd/releases/download/$v/$asset"
      sumurl="https://github.com/argoproj/argo-cd/releases/download/$v/cli_checksums.txt" ;;
    # Entra ID login for AKS clusters with local accounts disabled (D-084). Windows assets are named win-, not windows-.
    kubelogin) v=$KUBELOGIN_VERSION; local kplat="$OS-$ARCH"; [ "$OS" = windows ] && kplat="win-$ARCH"; asset="kubelogin-$kplat.zip"
      url="https://github.com/Azure/kubelogin/releases/download/$v/$asset"; sumurl="$url.sha256"; member="kubelogin$EXE" ;;
    *) echo "unknown tool: $tool"; exit 2 ;;
  esac

  # yq publishes a multi-column 'checksums' file; its SHA-256 column is resolved via checksums_hashes_order.
  if [ "$tool" = yq ]; then
    fetch "https://github.com/mikefarah/yq/releases/download/$v/checksums_hashes_order" "$TMP/order"
    fetch "$sumurl" "$TMP/yqsums"
    local col; col=$(( $(grep -n '^SHA-256$' "$TMP/order" | cut -d: -f1) + 1 ))
    awk -v a="$asset" -v c="$col" '$1==a {print $c "  " a}' "$TMP/yqsums" >"$TMP/yq.sha256"
    sumurl="$TMP/yq.sha256"
  fi

  if [ $LOCK_ONLY -eq 1 ]; then
    local key="$tool $v $OS-$ARCH $asset" want
    if grep -qF "$key " "$LOCK"; then echo "OK    $key (already locked)"; return; fi
    want="$(upstream_sum "$sumurl" "$asset")"
    echo "$key $want" >>"$LOCK"; echo "LOCK  $key (from published checksum)"; return
  fi

  # The stamp binds the cached binary to the lock entry it was verified against: "<version> <locked asset sha> <binary sha>".
  # A changed or removed lock entry, or a modified binary, forces a fresh download and verification.
  local stamp="$BIN/.$tool.version" lockkey="$tool $v $OS-$ARCH $asset" locknow=""
  locknow="$(grep -F "$lockkey " "$LOCK" 2>/dev/null | awk '{print $5}' || true)"
  if [ -x "$dest" ] && [ -n "$locknow" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$v $locknow $(sha "$dest")" ]; then
    echo "OK    $tool $v (cached, lock and binary digest unchanged)"; return
  fi
  fetch "$url" "$TMP/$asset"
  verify "$tool" "$v" "$TMP/$asset" "$asset" "$sumurl"
  if [ -n "${member:-}" ]; then extract "$TMP/$asset" "$member" "$dest"; else mv "$TMP/$asset" "$dest"; fi
  chmod +x "$dest"
  locknow="$(grep -F "$lockkey " "$LOCK" | awk '{print $5}')"
  echo "$v $locknow $(sha "$dest")" >"$stamp"
  echo "OK    $tool $v"
}

TOOLS=("$@")
[ ${#TOOLS[@]} -gt 0 ] || TOOLS=(kind kubectl helm kyverno chainsaw crossplane terraform tflint kubeconform cosign jq yq cilium argocd kubelogin)
for t in "${TOOLS[@]}"; do member=""; install_one "$t"; done
