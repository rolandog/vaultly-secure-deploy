#!/usr/bin/env bash
# ci-install-tools.sh --- install pinned scanners into $TOOLS_DIR/bin (CI and local checks)
# Binaries are checked against a pinned sha256. Each Python tool gets its own venv
# because checkov and semgrep pin conflicting dependencies.
set -euo pipefail; set -C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROG=${0##*/}
VERSION=0.1.0
# shellcheck source=lib.sh
. "$ROOT/scripts/lib.sh"

readonly TRIVY_VERSION=0.76.2
readonly TRIVY_SHA256=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf
readonly GITLEAKS_VERSION=8.30.1
readonly GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
readonly CHECKOV_VERSION=3.4.4
readonly YAMLLINT_VERSION=1.37.1
readonly SEMGREP_VERSION=1.185.0
readonly PIP_AUDIT_VERSION=2.10.1
readonly ALL_TOOLS=(trivy gitleaks checkov yamllint semgrep pip-audit)

TOOLS_DIR=${TOOLS_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rg-tools}

usage() {
  cat <<USAGE
Usage: $PROG [--help|--version] TOOL...
Installs pinned scanners into \$TOOLS_DIR/bin (now: $TOOLS_DIR/bin).
TOOL is one of: ${ALL_TOOLS[*]}
Binaries (trivy, gitleaks) need x86_64 and are verified against a pinned sha256.
In GitHub Actions the bin directory is appended to \$GITHUB_PATH.
Env: TOOLS_DIR
USAGE
}

# download, verify, extract one binary named like the tool
fetch_bin() {
  local name=$1 url=$2 sum=$3 tmp
  if [ -x "$TOOLS_DIR/bin/$name" ]; then log "$name: already installed"; return 0; fi
  tmp=$(mktemp -d)
  curl -fsSL --retry 3 -o "$tmp/pkg.tar.gz" "$url" || die "download failed: $url"
  printf '%s  %s\n' "$sum" "$tmp/pkg.tar.gz" | sha256sum -c --status - \
    || die "sha256 mismatch for $name"
  tar -xzf "$tmp/pkg.tar.gz" -C "$tmp" "$name"
  install -m 0755 "$tmp/$name" "$TOOLS_DIR/bin/$name"
  rm -rf "$tmp"
  log "$name: installed"
}

install_py() {
  local pkg=$1 ver=$2 venv="$TOOLS_DIR/venv/$1"
  if [ -x "$TOOLS_DIR/bin/$pkg" ]; then log "$pkg: already installed"; return 0; fi
  python3 -m venv "$venv" || die "python3 -m venv failed (Debian: apt install python3-venv)"
  "$venv/bin/pip" install --quiet --disable-pip-version-check "$pkg==$ver"
  ln -s "$venv/bin/$pkg" "$TOOLS_DIR/bin/$pkg"
  log "$pkg: installed"
}

install_tool() {
  case $1 in
    trivy) fetch_bin trivy \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
      "$TRIVY_SHA256" ;;
    gitleaks) fetch_bin gitleaks \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
      "$GITLEAKS_SHA256" ;;
    checkov) install_py checkov "$CHECKOV_VERSION" ;;
    yamllint) install_py yamllint "$YAMLLINT_VERSION" ;;
    semgrep) install_py semgrep "$SEMGREP_VERSION" ;;
    pip-audit) install_py pip-audit "$PIP_AUDIT_VERSION" ;;
    *) die "unknown tool: $1" ;;
  esac
  [ -x "$TOOLS_DIR/bin/$1" ] || die "$1 missing after install"
}

tools=()
for a in "$@"; do
  case $a in
    -h|--help) usage; exit 0 ;;
    -V|--version) print_version; exit 0 ;;
    -*) usage >&2; die "unknown option: $a" ;;
    *) tools+=("$a") ;;
  esac
done
if [ "${#tools[@]}" -eq 0 ]; then usage >&2; die "name at least one tool"; fi
[ "$(uname -m)" = x86_64 ] || die "x86_64 only (pinned amd64 checksums)"

mkdir -p "$TOOLS_DIR/bin"
for t in "${tools[@]}"; do install_tool "$t"; done
if [ -n "${GITHUB_PATH:-}" ]; then printf '%s\n' "$TOOLS_DIR/bin" >> "$GITHUB_PATH"; fi
log "ok: tools in $TOOLS_DIR/bin"
