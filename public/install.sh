#!/usr/bin/env bash
#
# Olymposuite installer — interactive Docker Compose generator
#
# Asks which suite apps (and optional companion services) you want and one
# base data directory, then generates a ready-to-run docker-compose.yml,
# .env and NEXT_STEPS.md in one directory. App data is wired as subpaths
# under the data root (downloads/, media/adult/, media/series/, ...), extra
# directories can be added freely and are auto-created, and a single
# `docker compose up -d` brings the whole selection up.
# `docker compose down && rm -rf <install dir>` removes it completely.
#
# Usage:
#   curl -fsSL <docs-site>/install.sh | bash
#   bash install.sh [--install-dir DIR] [--namespace NS] [--tag TAG]
#
# Re-running the installer regenerates the compose file (the previous one is
# backed up). Your data directories are never touched.
#
set -euo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_NAMESPACE="olymposuite"
DEFAULT_TAG="latest"
DEFAULT_TZ="Europe/Istanbul"
# Companion services are optional qBittorrent / Prowlarr / Jellyfin containers.
COMPANION_TAG="latest"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

info()  { printf '%s\n' "${C_GREEN}==>${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW}warning:${C_RESET} $*" >&2; }
error() { printf '%s\n' "${C_RED}error:${C_RESET} $*" >&2; }
die()   { error "$*"; exit 1; }
step()  { printf '\n%s\n' "${C_BOLD}${C_BLUE}=== $* ===${C_RESET}" >&2; }

usage() {
  cat <<USAGE
Olymposuite installer v${SCRIPT_VERSION}

Interactive generator for an Olymposuite docker-compose stack.

Options:
  --install-dir DIR   Target directory (default: ./olymposuite)
  --namespace NS      Docker Hub namespace for suite images
                      (default: ${DEFAULT_NAMESPACE})
  --tag TAG           Image tag for suite apps (default: ${DEFAULT_TAG})
  -h, --help          Show this help

The installer is interactive: it asks which apps to install, whether to add
companion services (qBittorrent, Prowlarr, Jellyfin), and where your
downloads/media/archive disks live on the host. It then writes
docker-compose.yml, .env and NEXT_STEPS.md into the install directory.
USAGE
}

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
INSTALL_DIR_ARG=""
NAMESPACE="$DEFAULT_NAMESPACE"
TAG="$DEFAULT_TAG"
while [ $# -gt 0 ]; do
  case "$1" in
    --install-dir) [ $# -ge 2 ] || die "--install-dir needs a value"; INSTALL_DIR_ARG="$2"; shift 2 ;;
    --namespace)   [ $# -ge 2 ] || die "--namespace needs a value";   NAMESPACE="$2";   shift 2 ;;
    --tag)         [ $# -ge 2 ] || die "--tag needs a value";         TAG="$2";         shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Unknown option: $1 (see --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Interactive input — works under "curl | bash" by reading from /dev/tty
# ---------------------------------------------------------------------------
READ_FD=""
# { exec ...; } 2>/dev/null keeps fd2 restorable: a bare `exec 3<>... 2>/dev/null`
# would permanently send the script's stderr to /dev/null.
if [ -c /dev/tty ] && { exec 3<>/dev/tty; } 2>/dev/null; then
  READ_FD=3
elif [ -t 0 ]; then
  READ_FD=0
else
  die "This installer is interactive and needs a terminal.
Download it first, then run:
  curl -fsSL -o install.sh <docs-site>/install.sh && bash install.sh"
fi

# ask QUESTION [DEFAULT] -> prints the answer on stdout
ask() {
  local question="$1" default="${2-}" reply
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$question" "$default" >&2
  else
    printf '%s: ' "$question" >&2
  fi
  if ! IFS= read -r -u "$READ_FD" reply; then
    printf '\n' >&2
    die "Input stream closed - aborting."
  fi
  reply="${reply#"${reply%%[![:space:]]*}"}"   # ltrim
  reply="${reply%"${reply##*[![:space:]]}"}"   # rtrim
  printf '%s\n' "${reply:-$default}"
}

# ask_yn QUESTION [y|n] -> return 0 = yes, 1 = no
ask_yn() {
  local question="$1" default="${2:-y}" reply
  while true; do
    if [ "$default" = "y" ]; then
      printf '%s [Y/n]: ' "$question" >&2
    else
      printf '%s [y/N]: ' "$question" >&2
    fi
    if ! IFS= read -r -u "$READ_FD" reply; then
      printf '\n' >&2
      die "Input stream closed - aborting."
    fi
    reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$reply" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      "")    [ "$default" = "y" ] && return 0 || return 1 ;;
      *)     printf 'Please answer y or n.\n' >&2 ;;
    esac
  done
}

# select_from QUESTION HINT ITEM1 ITEM2 ...
# Prints a numbered list; answer is like "1 3" / "1,3" / "a" (all) / Enter (none).
# Result: MS_SELECTION array with 0-based indices.
MS_SELECTION=""
select_from() {
  local question="$1" hint="$2"; shift 2
  local items=("$@") i answer tok ok
  printf '%s\n' "$question" >&2
  i=0
  for it in "${items[@]}"; do
    printf '  %s[%d]%s %s\n' "$C_BOLD" "$((i+1))" "$C_RESET" "$it" >&2
    i=$((i+1))
  done
  [ -n "$hint" ] && printf '%s\n' "$C_DIM$hint$C_RESET" >&2
  while true; do
    printf 'selection> ' >&2
    if ! IFS= read -r -u "$READ_FD" answer; then
      printf '\n' >&2
      die "Input stream closed - aborting."
    fi
    answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    case "$answer" in
      a|all)
        MS_SELECTION=""
        for i in "${!items[@]}"; do MS_SELECTION="$MS_SELECTION $i"; done
        MS_SELECTION="${MS_SELECTION# }"
        return 0 ;;
      ""|none)
        MS_SELECTION=""
        return 0 ;;
    esac
    answer="${answer//,/ }"
    local sel="" ok=1
    for tok in $answer; do
      if [ "$tok" -eq "$tok" ] 2>/dev/null && [ "$tok" -ge 1 ] 2>/dev/null && [ "$tok" -le "${#items[@]}" ] 2>/dev/null; then
        sel="$sel $((tok-1))"
      else
        ok=0
        break
      fi
    done
    if [ "$ok" = "1" ] && [ -n "${sel// /}" ]; then
      MS_SELECTION="${sel# }"
      return 0
    fi
    printf 'Invalid selection. Enter numbers (e.g. "1 3"), "a" for all, or Enter for none.\n' >&2
  done
}
in_selection() { case " $MS_SELECTION " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N 24 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || \
      { printf 'installer needs openssl or /dev/urandom\n' >&2; return 1; }
  fi
}

# random_password -> 6 chars from an unambiguous alphanumeric set
random_password() {
  local charset='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789' pw="" i
  for i in 1 2 3 4 5 6; do
    pw="$pw${charset:$((RANDOM % ${#charset})):1}"
  done
  printf '%s\n' "$pw"
}

# qbit_password_hash PASSWORD -> the qBittorrent WebUI Password_PBKDF2 value.
# qBittorrent >= 5.0 format: base64(salt):base64(PBKDF2-HMAC-SHA512 key,
# 100000 iterations, 64 bytes). Uses python3 when available, OpenSSL 3's
# kdf command otherwise; returns 1 when neither can do it.
qbit_password_hash() {
  local password="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$password" <<'PYEOF'
import base64, hashlib, os, sys
pw = sys.argv[1].encode()
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac("sha512", pw, salt, 100000, 64)
sys.stdout.write(base64.b64encode(salt).decode() + ":" + base64.b64encode(key).decode())
PYEOF
    return 0
  fi
  if command -v openssl >/dev/null 2>&1 \
     && openssl kdf -keylen 8 -kdfopt digest:SHA512 -kdfopt iter:1 -kdfopt pass:x -kdfopt salt:x PBKDF2 >/dev/null 2>&1; then
    local salt_hex key_hex key_esc
    salt_hex=$(openssl rand -hex 16) || return 1
    key_hex=$(openssl kdf -keylen 64 -kdfopt digest:SHA512 -kdfopt iter:100000 \
              -kdfopt "pass:$password" -kdfopt "salt:$salt_hex" PBKDF2 2>/dev/null | tr -d ':\n')
    [ -n "$key_hex" ] || return 1
    key_esc=$(printf '%s' "$key_hex" | sed 's/../\\x&/g')
    printf '%s:%s\n' \
      "$(printf '%s' "$salt_hex" | base64 | tr -d '\n')" \
      "$(printf '%b' "$key_esc" | base64 | tr -d '\n')"
    return 0
  fi
  return 1
}

port_in_use() {
  local port="$1"
  # subshell only: never touch the parent's tty fd
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || return 1
  return 0
}

abs_path() {
  local p="$1"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#~/}" ;;
  esac
  case "$p" in
    /*) : ;;
    *) p="$PWD/${p#./}" ;;
  esac
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$p"
  else
    printf '%s\n' "$p"
  fi
}

# compose_bind HOST_PATH -> prints the path as it should appear in compose:
# relative (./...) when under the install dir, absolute otherwise.
compose_bind() {
  local p="$1"
  case "$p" in
    "$INSTALL_DIR") printf './' ;;
    "$INSTALL_DIR"/*) printf './%s' "${p#"$INSTALL_DIR"/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# archive_slug HOST_PATH SEEN_SLUGS -> a unique container-side directory name
# under /data for one archive root (lowercase, [a-z0-9-], no leading/trailing -,
# "-2"/"-3" suffix when the basename repeats).
archive_slug() {
  local base="${1##*/}"
  base=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | tr -s '-' '-')
  base="${base%-}"
  base="${base#-}"
  [ -n "$base" ] || base="archive"
  local slug="$base" n=1
  while printf '%s\n' "$2" | grep -qx -- "$slug"; do
    n=$((n+1))
    slug="$base-$n"
  done
  printf '%s' "$slug"
}

# ask_path QUESTION DEFAULT -> absolute path on stdout; sanity-checked.
ask_path() {
  local question="$1" default="$2" p
  while true; do
    p=$(ask "$question" "$default")
    [ -n "$p" ] || return 0
    p=$(abs_path "$p")
    case "$p" in
      *'"'*|*$'\n'*|*$'\t'*)
        warn "Paths containing double quotes or control characters are not supported."
        continue ;;
    esac
    if [ "$p" = "/" ]; then
      warn "Refusing to mount the filesystem root."
      continue
    fi
    printf '%s\n' "$p"
    return 0
  done
}

ensure_dir() {
  local d="$1"
  if [ -e "$d" ] && [ ! -d "$d" ]; then
    warn "$d exists but is not a directory - check before starting the stack."
    return 0
  fi
  if [ ! -d "$d" ]; then
    mkdir -p -- "$d" || { warn "Could not create $d."; return 0; }
  fi
}

ask_number() {
  local question="$1" default="$2" v
  while true; do
    v=$(ask "$question" "$default")
    case "$v" in
      ''|*[!0-9]*) warn "Please enter a number." ;;
      *) printf '%s\n' "$v"; return 0 ;;
    esac
  done
}

# ask_port LABEL DEFAULT -> port on stdout; rejects duplicates among chosen
# ports and warns when the host port appears to be in use.
declare -a USED_PORTS=()
port_registered() {
  local p="$1" u
  for u in "${USED_PORTS[@]-}"; do [ "$u" = "$p" ] && return 0; done
  return 1
}
ask_port() {
  local label="$1" default="$2" p
  while true; do
    p=$(ask_number "$label" "$default")
    if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      warn "Port must be between 1 and 65535."
      continue
    fi
    if port_registered "$p"; then
      warn "Port $p is already used by another service in this stack - pick another."
      continue
    fi
    if port_in_use "$p"; then
      warn "Something on this host appears to be listening on port $p already."
      if ! ask_yn "Use port $p anyway?" "n"; then continue; fi
    fi
    USED_PORTS+=("$p")
    printf '%s\n' "$p"
    return 0
  done
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "Docker is not installed.
Install it first: https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2 plugin) is not available.
Update your Docker installation."
DOCKER_DAEMON_OK=1
docker info >/dev/null 2>&1 || DOCKER_DAEMON_OK=0
if [ "$DOCKER_DAEMON_OK" = "0" ]; then
  warn "The Docker daemon is not reachable right now."
  warn "The installer can still generate the files; 'docker compose up' needs a running daemon."
fi
[ "$(uname -s)" = "Linux" ] || warn "This host is not Linux - the suite images target Linux hosts."

CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
printf '%s' "${C_BOLD}${C_BLUE}"
cat >&2 <<'BANNER'
  ___  _ ___ __  __ _   _  ___  ___  ___
 / _ \| | _ \  \/  | | | |/ _ \|   \| __|
| (_) | |   / |\/| | |_| | (_) | |) | _|
 \___/|_|_|_\_|  |_|____/ \___/|___/|___|
BANNER
printf '%s\n\n' "installer v${SCRIPT_VERSION}${C_RESET}" >&2
cat >&2 <<'INTRO'
This installer asks a few questions and generates a docker-compose stack for
the Olymposuite apps you choose. All questions have defaults - press Enter to
accept them. Nothing is started without your confirmation, and existing data
is never touched.

INTRO

# ---------------------------------------------------------------------------
# Step 1: install location
# ---------------------------------------------------------------------------
step "1/8 - Install location"
DEFAULT_DIR="$PWD/olymposuite"
if [ -n "$INSTALL_DIR_ARG" ]; then
  INSTALL_DIR=$(abs_path "$INSTALL_DIR_ARG")
  info "Using install directory: $INSTALL_DIR"
else
  INSTALL_DIR=$(ask_path "Where should the stack live?" "$DEFAULT_DIR")
fi
mkdir -p -- "$INSTALL_DIR" || die "Cannot create $INSTALL_DIR"

COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
STEPS_FILE="$INSTALL_DIR/NEXT_STEPS.md"

if [ -f "$COMPOSE_FILE" ] || [ -f "$ENV_FILE" ]; then
  warn "An installation already exists in $INSTALL_DIR."
  ask_yn "Regenerate the compose/.env files? (current ones are backed up, data dirs untouched)" "y" \
    || die "Aborted - nothing was changed."
fi

# ---------------------------------------------------------------------------
# Step 2: shared settings
# ---------------------------------------------------------------------------
step "2/8 - Shared settings (images, PUID/PGID, timezone)"
printf 'Suite images are pulled from Docker Hub namespace %s (tag %s).\n' "$NAMESPACE" "$TAG" >&2
if ask_yn "Change the namespace or tag?" "n"; then
  NAMESPACE=$(ask "Docker Hub namespace" "$NAMESPACE")
  TAG=$(ask "Image tag" "$TAG")
fi
PUID=$(ask_number "PUID (user id containers drop privileges to)" "$CURRENT_UID")
PGID=$(ask_number "PGID (group id)" "$CURRENT_GID")
TZ=$(ask "Timezone (IANA name)" "$DEFAULT_TZ")
if [ -d /usr/share/zoneinfo ] && [ ! -e "/usr/share/zoneinfo/$TZ" ]; then
  warn "'$TZ' does not look like a valid zone on this host - double-check the spelling."
fi

# ---------------------------------------------------------------------------
# Step 3: app selection
# ---------------------------------------------------------------------------
step "3/8 - Olymposuite apps"
select_from \
  "Which Olymposuite apps do you want to install?" \
  "Enter numbers (e.g. \"1 3\"), \"a\" for all, or Enter for none." \
  "Zephyrus  - torrent download-phase policy service (port 9695)" \
  "Eros      - adult scene collection manager (port 9697)" \
  "Psyche    - metadata-first TV/movie library automation (port 9698)" \
  "Morpheus  - media archive compression, h264 -> h265 (port 9699)"
APP_ZEPHYRUS=0;  in_selection 0 && APP_ZEPHYRUS=1
APP_EROS=0;      in_selection 1 && APP_EROS=1
APP_PSYCHE=0;    in_selection 2 && APP_PSYCHE=1
APP_MORPHEUS=0;  in_selection 3 && APP_MORPHEUS=1
SELECTED_APP_COUNT=$((APP_ZEPHYRUS + APP_EROS + APP_PSYCHE + APP_MORPHEUS))
[ "$SELECTED_APP_COUNT" -gt 0 ] || die "No apps selected - nothing to install. Aborting."

# ---------------------------------------------------------------------------
# Step 4: companion services
# ---------------------------------------------------------------------------
step "4/8 - Companion services (optional)"
COMPANION_HINT="Recommended if you don't already run these yourself. Apps connect to them"
COMPANION_HINT="$COMPANION_HINT over the shared compose network; skip any you already have."
select_from \
  "Also install companion services in this stack?" \
  "$COMPANION_HINT" \
  "qBittorrent - torrent client (WebUI on 8180) - needed by Eros/Psyche/Zephyrus" \
  "Prowlarr    - indexer manager (9696) - provides search to Eros/Psyche" \
  "Jellyfin    - media server (8096) - browse your organized libraries"
COMP_QBITTORRENT=0; in_selection 0 && COMP_QBITTORRENT=1
COMP_PROWLARR=0;    in_selection 1 && COMP_PROWLARR=1
COMP_JELLYFIN=0;    in_selection 2 && COMP_JELLYFIN=1

if [ "$APP_EROS" = "1" ] || [ "$APP_PSYCHE" = "1" ]; then
  if [ "$COMP_QBITTORRENT" = "0" ]; then
    warn "Eros/Psyche need a torrent client - you chose not to install one here,"
    warn "so make sure your existing client's WebUI is reachable from Docker."
  fi
  if [ "$COMP_PROWLARR" = "0" ]; then
    warn "Eros/Psyche need an indexer for release search (Prowlarr or a Torznab/Newznab endpoint)."
  fi
fi

# ---------------------------------------------------------------------------
# Step 5: ports
# ---------------------------------------------------------------------------
step "5/8 - Ports (host side; Enter accepts the default)"
PORT_ZEPHYRUS=""; PORT_EROS=""; PORT_PSYCHE=""; PORT_MORPHEUS=""
PORT_QBITTORRENT=""; PORT_PROWLARR=""; PORT_JELLYFIN=""
[ "$APP_ZEPHYRUS" = "1" ] && PORT_ZEPHYRUS=$(ask_port "Zephyrus web port" 9695)
[ "$APP_EROS" = "1" ]     && PORT_EROS=$(ask_port "Eros web port" 9697)
[ "$APP_PSYCHE" = "1" ]   && PORT_PSYCHE=$(ask_port "Psyche web port" 9698)
[ "$APP_MORPHEUS" = "1" ] && PORT_MORPHEUS=$(ask_port "Morpheus web port" 9699)
[ "$COMP_QBITTORRENT" = "1" ] && PORT_QBITTORRENT=$(ask_port "qBittorrent WebUI port" 8180)
[ "$COMP_PROWLARR" = "1" ]    && PORT_PROWLARR=$(ask_port "Prowlarr web port" 9696)
[ "$COMP_JELLYFIN" = "1" ]    && PORT_JELLYFIN=$(ask_port "Jellyfin web port" 8096)

# ---------------------------------------------------------------------------
# Step 6: data directory
# ---------------------------------------------------------------------------
step "6/8 - Data directory"
DATA_ROOT=$(ask_path "Base data directory (all app data lives under it)" "$INSTALL_DIR/data")

# Subpaths are derived from the selected apps - there are no per-app
# full-path questions; everything is created automatically under DATA_ROOT.
SUB_DOWNLOADS=0; SUB_ADULT=0; SUB_SERIES=0; SUB_MOVIES=0
NEED_MEDIA=$((APP_PSYCHE + COMP_JELLYFIN))
[ $((APP_EROS + APP_PSYCHE + COMP_QBITTORRENT)) -gt 0 ] && SUB_DOWNLOADS=1
[ "$APP_EROS" = "1" ] && SUB_ADULT=1
[ "$NEED_MEDIA" -gt 0 ] && SUB_SERIES=1
[ "$NEED_MEDIA" -gt 0 ] && SUB_MOVIES=1

printf 'The installer will create and wire these subpaths under %s:\n' "$DATA_ROOT" >&2
[ "$SUB_DOWNLOADS" = "1" ] && printf '    downloads/      torrent downloads (qBittorrent, Eros, Psyche)\n' >&2
[ "$SUB_ADULT" = "1" ]     && printf '    media/adult/    Eros organized output\n' >&2
[ "$SUB_SERIES" = "1" ]    && printf '    media/series/   TV library (Psyche, Jellyfin)\n' >&2
[ "$SUB_MOVIES" = "1" ]    && printf '    media/movies/   movie library (Psyche, Jellyfin)\n' >&2
if [ "$APP_MORPHEUS" = "1" ] && [ $((SUB_ADULT + SUB_SERIES + SUB_MOVIES)) -gt 0 ]; then
  printf '    (media/ is mounted into Morpheus as archive root /data/archive)\n' >&2
fi

JELLYFIN_ADULT=0
if [ "$COMP_JELLYFIN" = "1" ] && [ "$SUB_ADULT" = "1" ]; then
  if ask_yn "Also mount media/adult into Jellyfin?" "n"; then
    JELLYFIN_ADULT=1
  fi
fi

# Extra custom directories: any number, auto-created, mounted into Morpheus
# as additional archive roots (e.g. disks that already hold media).
EXTRA_DIRS=""
if [ "$APP_MORPHEUS" = "1" ]; then
  _default="n"
  if [ $((SUB_ADULT + SUB_SERIES + SUB_MOVIES)) -eq 0 ]; then
    _default="y"
    printf 'Morpheus needs at least one archive root.\n' >&2
  fi
  if ask_yn "Add extra directories as Morpheus archive roots?" "$_default"; then
    printf 'Enter one path per line; Enter on an empty line finishes.\n' >&2
    while true; do
      _d=$(ask_path "Extra directory path (Enter to finish)" "")
      [ -n "$_d" ] || break
      EXTRA_DIRS="$EXTRA_DIRS
$_d"
    done
    EXTRA_DIRS=$(printf '%s\n' "$EXTRA_DIRS" | sed '/^[[:space:]]*$/d')
  fi
fi

# Morpheus mounts: the whole media tree as /data/archive (when any media
# subpath exists) plus one /data/<slug> mount per extra directory.
# MORPHEUS_MOUNTS holds host<TAB>container lines.
MORPHEUS_MOUNTS=""
if [ "$APP_MORPHEUS" = "1" ]; then
  if [ $((SUB_ADULT + SUB_SERIES + SUB_MOVIES)) -gt 0 ]; then
    MORPHEUS_MOUNTS="$DATA_ROOT/media	/data/archive
"
  fi
  _seen="archive"
  while IFS= read -r _root; do
    [ -n "$_root" ] || continue
    _slug=$(archive_slug "$_root" "$_seen")
    _seen="$_seen
$_slug"
    MORPHEUS_MOUNTS="$MORPHEUS_MOUNTS$_root	/data/$_slug
"
  done <<EOF
$EXTRA_DIRS
EOF
fi

# ---------------------------------------------------------------------------
# Step 7: app-specific settings
# ---------------------------------------------------------------------------
step "7/8 - App settings"

# One generated qBittorrent WebUI password, wired into the apps via .env
# (no password questions). qBittorrent 5.x forces you to set a WebUI
# password on first login - set it to this generated one and everything
# lines up (Zephyrus reads it via env:QBIT_PASSWORD).
QBIT_PASSWORD=""
if [ "$COMP_QBITTORRENT" = "1" ] || [ "$APP_ZEPHYRUS" = "1" ]; then
  QBIT_PASSWORD=$(random_password) || die "Could not generate a password."
  info "Generated qBittorrent WebUI password: $QBIT_PASSWORD"
  if [ "$COMP_QBITTORRENT" = "0" ]; then
    warn "You are connecting to an existing qBittorrent - if its WebUI password"
    warn "differs, put the real one into .env (QBIT_PASSWORD) and re-run up -d."
  fi
fi

ZEPHYRUS_TOKEN=""; ZEPHYRUS_CLIENT_URL=""; ZEPHYRUS_CLIENT_USER=""
ZEPHYRUS_GROUPS=""; ZEPHYRUS_EXTRA_HOSTS=0
if [ "$APP_ZEPHYRUS" = "1" ]; then
  printf 'Zephyrus manages ONE qBittorrent 5.x connection (Web API >= 2.11).\n' >&2
  if [ "$COMP_QBITTORRENT" = "1" ]; then
    ZEPHYRUS_CLIENT_URL=$(ask "qBittorrent WebUI URL" "http://qbittorrent:8180")
  else
    ZEPHYRUS_CLIENT_URL=$(ask "qBittorrent WebUI URL reachable from the container" "http://host.docker.internal:8080")
  fi
  case "$ZEPHYRUS_CLIENT_URL" in
    *host.docker.internal*) ZEPHYRUS_EXTRA_HOSTS=1 ;;
  esac
  ZEPHYRUS_CLIENT_USER=$(ask "qBittorrent WebUI username" "admin")
  ZEPHYRUS_DEFAULT_GROUPS=""
  [ "$APP_EROS" = "1" ] && ZEPHYRUS_DEFAULT_GROUPS="eros"
  [ "$APP_PSYCHE" = "1" ] && ZEPHYRUS_DEFAULT_GROUPS="${ZEPHYRUS_DEFAULT_GROUPS:+$ZEPHYRUS_DEFAULT_GROUPS, }psyche"
  [ -z "$ZEPHYRUS_DEFAULT_GROUPS" ] && ZEPHYRUS_DEFAULT_GROUPS="media"
  ZEPHYRUS_GROUPS=$(ask "Torrent groups (qBittorrent categories) Zephyrus should manage" "$ZEPHYRUS_DEFAULT_GROUPS")
  ZEPHYRUS_TOKEN=$(random_secret) || die "Could not generate a random token."
  info "Generated ZEPHYRUS_TOKEN (written to .env)."
fi

EROS_SESSION_SECRET=""
if [ "$APP_EROS" = "1" ]; then
  EROS_SESSION_SECRET=$(random_secret) || die "Could not generate a session secret."
  info "Generated Eros SESSION_SECRET (written to .env)."
fi

MORPHEUS_GPU=0
if [ "$APP_MORPHEUS" = "1" ]; then
  printf 'The management image runs an embedded transcode worker by default (CPU).\n' >&2
  GPU_DEFAULT="n"
  command -v nvidia-smi >/dev/null 2>&1 && GPU_DEFAULT="y"
  if ask_yn "Enable NVIDIA GPU transcoding (requires NVIDIA Container Toolkit on the host)?" "$GPU_DEFAULT"; then
    MORPHEUS_GPU=1
  fi
  if [ "$MORPHEUS_GPU" = "1" ] && ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "No nvidia-smi on this host - the container may fail to start without the NVIDIA runtime."
  fi
fi

# ---------------------------------------------------------------------------
# Step 8: summary & confirmation
# ---------------------------------------------------------------------------
step "8/8 - Summary"
SEP="---------------------------------------------------------------------"
{
  printf '%s\n' "$SEP"
  printf ' Install dir : %s\n' "$INSTALL_DIR"
  printf ' Images      : %s/<app>:%s (companions: linuxserver)\n' "$NAMESPACE" "$TAG"
  printf ' PUID/PGID   : %s/%s    Timezone: %s\n' "$PUID" "$PGID" "$TZ"
  printf ' Apps        :'
  [ "$APP_ZEPHYRUS" = "1" ] && printf ' zephyrus(:%s)' "${PORT_ZEPHYRUS:-9695}"
  [ "$APP_EROS" = "1" ]     && printf ' eros(:%s)' "${PORT_EROS:-9697}"
  [ "$APP_PSYCHE" = "1" ]   && printf ' psyche(:%s)' "${PORT_PSYCHE:-9698}"
  [ "$APP_MORPHEUS" = "1" ] && printf ' morpheus(:%s)' "${PORT_MORPHEUS:-9699}"
  printf '\n'
  printf ' Companions  :'
  [ "$COMP_QBITTORRENT" = "1" ] && printf ' qbittorrent(:%s)' "${PORT_QBITTORRENT:-8180}"
  [ "$COMP_PROWLARR" = "1" ]    && printf ' prowlarr(:%s)' "${PORT_PROWLARR:-9696}"
  [ "$COMP_JELLYFIN" = "1" ]    && printf ' jellyfin(:%s)' "${PORT_JELLYFIN:-8096}"
  printf '\n'
  printf ' Data root   : %s\n' "$DATA_ROOT"
  [ "$SUB_DOWNLOADS" = "1" ] && printf '   downloads/     (qBittorrent, Eros, Psyche)\n'
  [ "$SUB_ADULT" = "1" ]     && printf '   media/adult/   (Eros)\n'
  [ "$SUB_SERIES" = "1" ]    && printf '   media/series/  (Psyche, Jellyfin)\n'
  [ "$SUB_MOVIES" = "1" ]    && printf '   media/movies/  (Psyche, Jellyfin)\n'
  if [ "$APP_MORPHEUS" = "1" ] && [ -n "$MORPHEUS_MOUNTS" ]; then
    printf ' Archive     :'
    printf '%s\n' "$MORPHEUS_MOUNTS" | while IFS=$'\t' read -r _h _c; do
      [ -n "$_h" ] || continue
      printf ' %s -> %s' "$_h" "$_c"
    done
    printf '\n'
  fi
  [ -n "$QBIT_PASSWORD" ] && printf ' qBit passwd : %s (preset in config + .env)\n' "$QBIT_PASSWORD"
  [ "$APP_ZEPHYRUS" = "1" ] && printf ' Zephyrus -> : %s (user: %s, groups: %s)\n' "$ZEPHYRUS_CLIENT_URL" "$ZEPHYRUS_CLIENT_USER" "$ZEPHYRUS_GROUPS"
  [ "$MORPHEUS_GPU" = "1" ] && printf ' GPU        : enabled for Morpheus\n'
  printf '%s\n' "$SEP"
} >&2

ask_yn "Generate the files?" "y" || die "Aborted - nothing was written."

# ---------------------------------------------------------------------------
# Create all data directories (auto-created; never deleted by the installer)
# ---------------------------------------------------------------------------
ALL_DIRS="$INSTALL_DIR/data"
[ "$APP_ZEPHYRUS" = "1" ] && ALL_DIRS="$ALL_DIRS
$INSTALL_DIR/data/zephyrus/config
$INSTALL_DIR/data/zephyrus/data"
[ "$APP_EROS" = "1" ] && ALL_DIRS="$ALL_DIRS
$INSTALL_DIR/data/eros/config
$INSTALL_DIR/data/eros/db
$INSTALL_DIR/data/eros/cross-encoder"
[ "$APP_PSYCHE" = "1" ] && ALL_DIRS="$ALL_DIRS
$INSTALL_DIR/data/psyche/config
$INSTALL_DIR/data/psyche/data"
[ "$APP_MORPHEUS" = "1" ] && ALL_DIRS="$ALL_DIRS
$INSTALL_DIR/data/morpheus/config"
[ "$MORPHEUS_GPU" = "1" ] && ALL_DIRS="$ALL_DIRS
$INSTALL_DIR/data/morpheus/gpu"
[ "$COMP_QBITTORRENT" = "1" ] && ALL_DIRS="$ALL_DIRS
$INSTALL_DIR/data/qbittorrent/config"
[ "$COMP_PROWLARR" = "1" ] && ALL_DIRS="$ALL_DIRS
$INSTALL_DIR/data/prowlarr/config"
[ "$COMP_JELLYFIN" = "1" ] && ALL_DIRS="$ALL_DIRS
$INSTALL_DIR/data/jellyfin/config"
[ "$SUB_DOWNLOADS" = "1" ] && ALL_DIRS="$ALL_DIRS
$DATA_ROOT/downloads"
[ "$SUB_ADULT" = "1" ] && ALL_DIRS="$ALL_DIRS
$DATA_ROOT/media/adult"
[ "$SUB_SERIES" = "1" ] && ALL_DIRS="$ALL_DIRS
$DATA_ROOT/media/series"
[ "$SUB_MOVIES" = "1" ] && ALL_DIRS="$ALL_DIRS
$DATA_ROOT/media/movies"
[ -n "$EXTRA_DIRS" ] && ALL_DIRS="$ALL_DIRS
$EXTRA_DIRS"

printf '%s\n' "$ALL_DIRS" | while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ -d "$d" ] && continue
  ensure_dir "$d"
done
info "Directories ready."

# ---------------------------------------------------------------------------
# Backup existing generated files
# ---------------------------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
for f in "$COMPOSE_FILE" "$ENV_FILE" "$STEPS_FILE"; do
  if [ -f "$f" ]; then
    mv -- "$f" "$f.bak.$TS"
    info "Backed up $(basename "$f") -> $(basename "$f").bak.$TS"
  fi
done

# ---------------------------------------------------------------------------
# Write .env
# ---------------------------------------------------------------------------
ZEPHYRUS_CONFIG_FILE="$INSTALL_DIR/data/zephyrus/config/config.yaml"
if [ "$APP_ZEPHYRUS" = "1" ] && [ -f "$ZEPHYRUS_CONFIG_FILE" ]; then
  mv -- "$ZEPHYRUS_CONFIG_FILE" "$ZEPHYRUS_CONFIG_FILE.bak.$TS"
  info "Backed up existing zephyrus config.yaml"
fi

cat > "$ENV_FILE" <<ENVEOF
# Generated by the Olymposuite installer on $(date '+%Y-%m-%d %H:%M:%S').
# Secrets - keep this file private (permissions are already 600).
IMAGE_NAMESPACE=$NAMESPACE
TAG=$TAG
PUID=$PUID
PGID=$PGID
TZ=$TZ
ENVEOF
[ -n "$QBIT_PASSWORD" ] && printf 'QBIT_PASSWORD=%s\n' "$QBIT_PASSWORD" >> "$ENV_FILE"

[ "$APP_ZEPHYRUS" = "1" ] && cat >> "$ENV_FILE" <<ENVEOF
PORT_ZEPHYRUS=$PORT_ZEPHYRUS
ZEPHYRUS_TOKEN=$ZEPHYRUS_TOKEN
ENVEOF
[ "$APP_EROS" = "1" ] && cat >> "$ENV_FILE" <<ENVEOF
PORT_EROS=$PORT_EROS
EROS_SESSION_SECRET=$EROS_SESSION_SECRET
ENVEOF
[ "$APP_PSYCHE" = "1" ] && cat >> "$ENV_FILE" <<ENVEOF
PORT_PSYCHE=$PORT_PSYCHE
ENVEOF
[ "$APP_MORPHEUS" = "1" ] && cat >> "$ENV_FILE" <<ENVEOF
PORT_MORPHEUS=$PORT_MORPHEUS
ENVEOF
[ "$COMP_QBITTORRENT" = "1" ] && cat >> "$ENV_FILE" <<ENVEOF
PORT_QBITTORRENT=$PORT_QBITTORRENT
ENVEOF
[ "$COMP_PROWLARR" = "1" ] && cat >> "$ENV_FILE" <<ENVEOF
PORT_PROWLARR=$PORT_PROWLARR
ENVEOF
[ "$COMP_JELLYFIN" = "1" ] && cat >> "$ENV_FILE" <<ENVEOF
PORT_JELLYFIN=$PORT_JELLYFIN
ENVEOF
chmod 600 "$ENV_FILE"

# ---------------------------------------------------------------------------
# Preset the qBittorrent WebUI password in its config, so the generated
# password works on the very first start - no temporary-password dance.
# ---------------------------------------------------------------------------
QBIT_PRESET=0
if [ "$COMP_QBITTORRENT" = "1" ] && [ -n "$QBIT_PASSWORD" ]; then
  QBIT_CONF="$INSTALL_DIR/data/qbittorrent/config/qBittorrent/qBittorrent.conf"
  if QBIT_HASH=$(qbit_password_hash "$QBIT_PASSWORD"); then
    if [ ! -f "$QBIT_CONF" ]; then
      mkdir -p -- "$(dirname -- "$QBIT_CONF")"
      cat > "$QBIT_CONF" <<EOF
# qBittorrent configuration - generated by the Olymposuite installer.
# WebUI credentials are preset: Username=admin, Password from .env QBIT_PASSWORD.

[BitTorrent]
Session\\DefaultSavePath=/downloads
Session\\Port=6881

[LegalNotice]
Accepted=true

[WebUI]
Password_PBKDF2=@ByteArray($QBIT_HASH)
Port=8180
Username=admin
HostHeaderValidation=false
EOF
      QBIT_PRESET=1
      info "Preset qBittorrent WebUI credentials (admin / \$QBIT_PASSWORD in .env)"
    else
      cp -- "$QBIT_CONF" "$QBIT_CONF.bak.$TS"
      sed -i \
        -e "s|^WebUI.Password_PBKDF2=.*|Password_PBKDF2=@ByteArray($QBIT_HASH)|" \
        -e "s|^Password_PBKDF2=.*|Password_PBKDF2=@ByteArray($QBIT_HASH)|" \
        -e "s|^WebUI.HostHeaderValidation=.*|HostHeaderValidation=false|" \
        -e "s|^HostHeaderValidation=.*|HostHeaderValidation=false|" \
        "$QBIT_CONF"
      grep -q '^Password_PBKDF2=@ByteArray' "$QBIT_CONF" \
        || sed -i "/^\[WebUI\]/a Password_PBKDF2=@ByteArray($QBIT_HASH)" "$QBIT_CONF"
      grep -q '^HostHeaderValidation=false' "$QBIT_CONF" \
        || sed -i "/^\[WebUI\]/a HostHeaderValidation=false" "$QBIT_CONF"
      QBIT_PRESET=1
      info "Re-synced qBittorrent WebUI password into existing config (backed up)"
    fi
  else
    warn "Could not hash the password (needs python3 or OpenSSL 3)."
    warn "qBittorrent will print a temporary password in its logs on first start;"
    warn "log in with it and set the WebUI password to: $QBIT_PASSWORD"
  fi
fi

# ---------------------------------------------------------------------------
# Write docker-compose.yml
# ---------------------------------------------------------------------------
cat > "$COMPOSE_FILE" <<EOF
# docker-compose.yml - generated by the Olymposuite installer on $(date '+%Y-%m-%d %H:%M:%S').
# Re-run the installer to regenerate (previous file is backed up).
#
# Start:        docker compose up -d
# Stop:         docker compose down
# Logs:         docker compose logs -f <service>
# Update:       docker compose pull && docker compose up -d
# Remove:       docker compose down && rm -rf <this directory>
name: olymposuite

services:
EOF

if [ "$APP_ZEPHYRUS" = "1" ]; then
  ZB_DATA=$(compose_bind "$INSTALL_DIR/data/zephyrus/data")
  ZB_CONFIG=$(compose_bind "$INSTALL_DIR/data/zephyrus/config")
  cat >> "$COMPOSE_FILE" <<EOF
  zephyrus:
    image: \${IMAGE_NAMESPACE:-olymposuite}/zephyrus:\${TAG:-latest}
    container_name: zephyrus
    restart: unless-stopped
    ports:
      - "\${PORT_ZEPHYRUS:-9695}:3030"
    environment:
      ZEPHYRUS_TOKEN: \${ZEPHYRUS_TOKEN:?Set ZEPHYRUS_TOKEN in .env}
      QBIT_PASSWORD: \${QBIT_PASSWORD:-}
      PUID: \${PUID:-1000}
      PGID: \${PGID:-1000}
      TZ: \${TZ:-Europe/Istanbul}
    volumes:
      - "$ZB_DATA:/data"       # SQLite database
      - "$ZB_CONFIG:/config"   # config.yaml (pre-generated by the installer)
EOF
  if [ "$ZEPHYRUS_EXTRA_HOSTS" = "1" ]; then
    cat >> "$COMPOSE_FILE" <<EOF
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF
  fi
  cat >> "$COMPOSE_FILE" <<EOF

EOF
fi

if [ "$APP_EROS" = "1" ]; then
  EB_CONFIG=$(compose_bind "$INSTALL_DIR/data/eros/config")
  EB_DB=$(compose_bind "$INSTALL_DIR/data/eros/db")
  EB_CE=$(compose_bind "$INSTALL_DIR/data/eros/cross-encoder")
  EB_DL=$(compose_bind "$DATA_ROOT/downloads")
  EB_MEDIA=$(compose_bind "$DATA_ROOT/media/adult")
  EROS_DEPENDS=""
  if [ "$COMP_QBITTORRENT" = "1" ] || [ "$COMP_PROWLARR" = "1" ]; then
    EROS_DEPENDS="    depends_on:"
    [ "$COMP_QBITTORRENT" = "1" ] && EROS_DEPENDS="$EROS_DEPENDS
      - qbittorrent"
    [ "$COMP_PROWLARR" = "1" ] && EROS_DEPENDS="$EROS_DEPENDS
      - prowlarr"
    EROS_DEPENDS="$EROS_DEPENDS
"
  fi
  cat >> "$COMPOSE_FILE" <<EOF
  eros:
    image: \${IMAGE_NAMESPACE:-olymposuite}/eros:\${TAG:-latest}
    container_name: eros
    init: true
    restart: unless-stopped
    ports:
      - "\${PORT_EROS:-9697}:3000"
    environment:
      SESSION_SECRET: \${EROS_SESSION_SECRET:-}
      DB_PATH: /config/eros.db
      PUID: \${PUID:-1000}
      PGID: \${PGID:-1000}
      TZ: \${TZ:-Europe/Istanbul}
    volumes:
      - "$EB_CONFIG:/config"        # DB + session secret + backups (back this up)
      - "$EB_DB:/data"              # legacy location, kept empty on new installs
      - "$EB_CE:/cross-encoder"     # similarity model cache (regenerable)
      - "$EB_DL:/downloads"         # shared with the torrent client
      - "$EB_MEDIA:/media"          # organized output
$EROS_DEPENDS
EOF
fi

if [ "$APP_PSYCHE" = "1" ]; then
  PB_CONFIG=$(compose_bind "$INSTALL_DIR/data/psyche/config")
  PB_DATA=$(compose_bind "$INSTALL_DIR/data/psyche/data")
  PB_TV=$(compose_bind "$DATA_ROOT/media/series")
  PB_MOVIES=$(compose_bind "$DATA_ROOT/media/movies")
  PB_DL=$(compose_bind "$DATA_ROOT/downloads")
  cat >> "$COMPOSE_FILE" <<EOF
  psyche:
    image: \${IMAGE_NAMESPACE:-olymposuite}/psyche:\${TAG:-latest}
    container_name: psyche
    restart: unless-stopped
    ports:
      - "\${PORT_PSYCHE:-9698}:3000"
    environment:
      PUID: \${PUID:-1000}
      PGID: \${PGID:-1000}
      TZ: \${TZ:-Europe/Istanbul}
    volumes:
      - "$PB_CONFIG:/config"          # DB + settings + session secret (back this up)
      - "$PB_DATA:/data"              # artwork + model caches (regenerable)
      - "$PB_TV:/media/series"        # TV library root
      - "$PB_MOVIES:/media/movies"    # movie library root
      - "$PB_DL:/media/downloads"     # torrent client downloads

EOF
fi

if [ "$APP_MORPHEUS" = "1" ]; then
  MB_CONFIG=$(compose_bind "$INSTALL_DIR/data/morpheus/config")
  MB_GPU=$(compose_bind "$INSTALL_DIR/data/morpheus/gpu")
  cat >> "$COMPOSE_FILE" <<EOF
  morpheus:
    image: \${IMAGE_NAMESPACE:-olymposuite}/morpheus:\${TAG:-latest}
    container_name: morpheus
    restart: unless-stopped
    ports:
      - "\${PORT_MORPHEUS:-9699}:3000"
    environment:
      MORPHEUS_GPU_CACHE: /data/.morpheus-gpu
      PUID: \${PUID:-1000}
      PGID: \${PGID:-1000}
      TZ: \${TZ:-Europe/Istanbul}
    volumes:
      - "$MB_CONFIG:/config"          # DB + settings + session secret (back this up)
EOF
  if [ "$MORPHEUS_GPU" = "1" ]; then
    cat >> "$COMPOSE_FILE" <<EOF
      - "$MB_GPU:/data/.morpheus-gpu" # NVIDIA encoder cache (re-downloadable)
EOF
  fi
  if [ -n "$MORPHEUS_MOUNTS" ]; then
    printf '%s\n' "$MORPHEUS_MOUNTS" | while IFS=$'\t' read -r root container; do
      [ -n "$container" ] || continue
      cat >> "$COMPOSE_FILE" <<EOF
      - "$(compose_bind "$root"):$container"   # archive root (host: $root)
EOF
    done
  fi
  if [ "$MORPHEUS_GPU" = "1" ]; then
    cat >> "$COMPOSE_FILE" <<EOF
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
EOF
  fi
  cat >> "$COMPOSE_FILE" <<EOF

EOF
fi

if [ "$COMP_QBITTORRENT" = "1" ]; then
  QB_CONFIG=$(compose_bind "$INSTALL_DIR/data/qbittorrent/config")
  QB_DL=$(compose_bind "$DATA_ROOT/downloads")
  cat >> "$COMPOSE_FILE" <<EOF
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:$COMPANION_TAG
    container_name: qbittorrent
    restart: unless-stopped
    environment:
      WEBUI_PORT: "8180"
      TORRENTING_PORT: "6881"
      PUID: \${PUID:-1000}
      PGID: \${PGID:-1000}
      TZ: \${TZ:-Europe/Istanbul}
    ports:
      - "\${PORT_QBITTORRENT:-8180}:8180"   # WebUI
      - "6881:6881"                          # torrenting port
      - "6881:6881/udp"
    stop_grace_period: "10s"
    volumes:
      - "$QB_CONFIG:/config"
      - "$QB_DL:/downloads"    # same host path Eros/Psyche see as their downloads

EOF
fi

if [ "$COMP_PROWLARR" = "1" ]; then
  PR_CONFIG=$(compose_bind "$INSTALL_DIR/data/prowlarr/config")
  cat >> "$COMPOSE_FILE" <<EOF
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:$COMPANION_TAG
    container_name: prowlarr
    restart: unless-stopped
    environment:
      PUID: \${PUID:-1000}
      PGID: \${PGID:-1000}
      TZ: \${TZ:-Europe/Istanbul}
    ports:
      - "\${PORT_PROWLARR:-9696}:9696"
    volumes:
      - "$PR_CONFIG:/config"

EOF
fi

if [ "$COMP_JELLYFIN" = "1" ]; then
  JF_CONFIG=$(compose_bind "$INSTALL_DIR/data/jellyfin/config")
  cat >> "$COMPOSE_FILE" <<EOF
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:$COMPANION_TAG
    container_name: jellyfin
    restart: unless-stopped
    environment:
      PUID: \${PUID:-1000}
      PGID: \${PGID:-1000}
      TZ: \${TZ:-Europe/Istanbul}
    ports:
      - "\${PORT_JELLYFIN:-8096}:8096"
    volumes:
      - "$JF_CONFIG:/config"
EOF
  if [ "$SUB_SERIES" = "1" ]; then
    cat >> "$COMPOSE_FILE" <<EOF
      - "$(compose_bind "$DATA_ROOT/media/series"):/media/series"
EOF
  fi
  if [ "$SUB_MOVIES" = "1" ]; then
    cat >> "$COMPOSE_FILE" <<EOF
      - "$(compose_bind "$DATA_ROOT/media/movies"):/media/movies"
EOF
  fi
  if [ "$JELLYFIN_ADULT" = "1" ]; then
    cat >> "$COMPOSE_FILE" <<EOF
      - "$(compose_bind "$DATA_ROOT/media/adult"):/media/adult"
EOF
  fi
  cat >> "$COMPOSE_FILE" <<EOF

EOF
fi

# ---------------------------------------------------------------------------
# Zephyrus starter config.yaml
# ---------------------------------------------------------------------------
if [ "$APP_ZEPHYRUS" = "1" ]; then
  Z_GROUPS_BLOCK=""
  # shellcheck disable=SC2086  # word splitting is intended here
  for g in $(printf '%s' "$ZEPHYRUS_GROUPS" | tr ',' ' '); do
    g=$(printf '%s' "$g" | tr -d '[:space:]')
    [ -n "$g" ] || continue
    case "$g" in
      *[!a-zA-Z0-9_-]*)
        warn "Skipping invalid group name '$g' (allowed: letters, digits, - _)."
        continue ;;
    esac
    GL=$(printf '%s' "$g" | tr '[:upper:]' '[:lower:]')
    case "$GL" in
      eros)   GD_WEIGHT=10; GD_MAX=4 ;;
      psyche) GD_WEIGHT=5;  GD_MAX=3 ;;
      *)      GD_WEIGHT=5;  GD_MAX=4 ;;
    esac
    Z_GROUPS_BLOCK="$Z_GROUPS_BLOCK
  $GL:
    max_active_downloads: $GD_MAX
    weight: $GD_WEIGHT"
  done
  if [ -z "$Z_GROUPS_BLOCK" ]; then
    Z_GROUPS_BLOCK="
  media:
    max_active_downloads: 4
    weight: 5"
  fi
  cat > "$ZEPHYRUS_CONFIG_FILE" <<EOF
# Zephyrus configuration - generated by the Olymposuite installer.
# Secrets stay in the environment: password is read via env:QBIT_PASSWORD.
# Full reference: Olymposuite docs -> Zephyrus -> Configuration.

client:
  type: qbittorrent
  url: $ZEPHYRUS_CLIENT_URL
  username: $ZEPHYRUS_CLIENT_USER
  password: env:QBIT_PASSWORD
  poll_interval_seconds: 5

timezone: $TZ

global:
  max_active_downloads: 6

groups:$Z_GROUPS_BLOCK

stalled:
  threshold_minutes: 30
  retry:
    interval_minutes: 15
    backoff_multiplier: 2
    max_interval_minutes: 1440
    progress_reset_bytes: 10485760
    give_up_hours: 72
  slow:
    speed_floor_bytes: 5242880
  completion_bias:
    tiers:
      - min_progress: 0.5
        give_up_multiplier: 2
        max_retry_interval_minutes: 360
      - min_progress: 0.9
        give_up_multiplier: 5
        max_retry_interval_minutes: 120
      - min_progress: 0.99
        give_up_multiplier: 10
        max_retry_interval_minutes: 60

schedule:
  profiles:
    full:
      download: 0
      upload: 0
    night_limited:
      download: "25 MB/s"
      upload: "5 MB/s"
  windows:
    - days: [mon, tue, wed, thu, fri, sat, sun]
      from: "00:00"
      to: "23:59"
      profile: full
    # Example: cap bandwidth during weekday office hours -
    # uncomment and adjust:
    # - days: [mon, tue, wed, thu, fri]
    #   from: "08:00"
    #   to: "18:00"
    #   profile: night_limited

server:
  port: 3030
  log_level: info
EOF
  info "Wrote Zephyrus starter config: $ZEPHYRUS_CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# NEXT_STEPS.md
# ---------------------------------------------------------------------------
{
  cat <<MDHEAD
# Olymposuite - next steps

Generated by the installer on $(date '+%Y-%m-%d %H:%M:%S') in \`$INSTALL_DIR\`.

## Start the stack

    docker compose up -d

Useful commands (run inside \`$INSTALL_DIR\`):

| Command | Effect |
|---|---|
| \`docker compose up -d\` | Start / recreate everything |
| \`docker compose down\` | Stop everything |
| \`docker compose logs -f <service>\` | Follow logs (e.g. \`zephyrus\`, \`qbittorrent\`) |
| \`docker compose pull && docker compose up -d\` | Update images |
| \`docker compose ps\` | Status |
| \`docker compose down && rm -rf $INSTALL_DIR\` | Remove the whole stack and all its data |

Secrets live in \`.env\` (mode 600) - edit it, then \`docker compose up -d\` to apply.

## Service URLs

| Service | URL |
|---|---|
MDHEAD
  [ "$APP_ZEPHYRUS" = "1" ]   && printf '| Zephyrus | http://localhost:%s |\n' "$PORT_ZEPHYRUS"
  [ "$APP_EROS" = "1" ]       && printf '| Eros | http://localhost:%s |\n' "$PORT_EROS"
  [ "$APP_PSYCHE" = "1" ]     && printf '| Psyche | http://localhost:%s |\n' "$PORT_PSYCHE"
  [ "$APP_MORPHEUS" = "1" ]   && printf '| Morpheus | http://localhost:%s |\n' "$PORT_MORPHEUS"
  [ "$COMP_QBITTORRENT" = "1" ] && printf '| qBittorrent | http://localhost:%s |\n' "$PORT_QBITTORRENT"
  [ "$COMP_PROWLARR" = "1" ]    && printf '| Prowlarr | http://localhost:%s |\n' "$PORT_PROWLARR"
  [ "$COMP_JELLYFIN" = "1" ]    && printf '| Jellyfin | http://localhost:%s |\n' "$PORT_JELLYFIN"

  printf '\n## First-run setup per app\n\n'
  if [ "$APP_ZEPHYRUS" = "1" ]; then
    cat <<MD
### Zephyrus

1. Open the dashboard, follow the first-run wizard (admin account) if shown.
2. The installer already wrote a starter \`config.yaml\` at
   \`data/zephyrus/config/config.yaml\` pointing at $ZEPHYRUS_CLIENT_URL
   (user \`$ZEPHYRUS_CLIENT_USER\`, password: the generated WebUI password,
   read from \`.env\` as \`QBIT_PASSWORD\`). If the client's password changes
   later, update \`.env\` and run \`docker compose up -d zephyrus\` to apply it.
3. Assign torrents in qBittorrent to the managed categories
   (\`$ZEPHYRUS_GROUPS\`) - Zephyrus only touches torrents in those groups.
4. Verify:

       curl -H "Authorization: Bearer $ZEPHYRUS_TOKEN" http://localhost:$PORT_ZEPHYRUS/api/status

MD
  fi
  if [ "$APP_EROS" = "1" ]; then
    cat <<MD
### Eros

1. Open the URL above - with no admin yet you are routed to \`/setup\`.
2. Create the single admin account.
3. Settings -> Services: add an indexer and a torrent client, then test them.
MD
    if [ "$COMP_QBITTORRENT" = "1" ]; then
      printf '   qBittorrent is at `http://qbittorrent:8180` (username `admin`, password: the generated WebUI password).\n'
    fi
    if [ "$COMP_PROWLARR" = "1" ]; then
      printf '   Prowlarr is at `http://prowlarr:9696` (container-to-container).\n'
    fi
    cat <<MD
4. TPDB / StashDB API keys are optional - without them scenes stay unmapped.

MD
  fi
  if [ "$APP_PSYCHE" = "1" ]; then
    cat <<MD
### Psyche

1. Open the URL above and create the admin account (\`/setup\`).
2. You need a **TMDB API key** (themoviedb.org) - configured after boot in
   Settings -> Services, together with at least one indexer and a torrent
   client. Use the built-in test probes before saving.
3. This stack mounts the TV library at \`/media/series\` and movies at
   \`/media/movies\` - if Psyche expects its default \`/media/tv\`, point the
   TV library path at \`/media/series\` in Settings.
MD
    if [ "$COMP_QBITTORRENT" = "1" ]; then
      printf '   qBittorrent is at `http://qbittorrent:8180` (username `admin`, password: the generated WebUI password).\n'
    fi
    if [ "$COMP_PROWLARR" = "1" ]; then
      printf '   Prowlarr is at `http://prowlarr:9696` (container-to-container).\n'
    fi
    printf '\n'
  fi
  if [ "$APP_MORPHEUS" = "1" ]; then
    cat <<MD
### Morpheus

1. Open the URL above and complete the first-run wizard (admin account).
2. Add your archive roots on the **Libraries** page using the container-side
   paths the installer mounted:
MD
    if [ -n "$MORPHEUS_MOUNTS" ]; then
      printf '%s\n' "$MORPHEUS_MOUNTS" | while IFS=$'\t' read -r root container; do
        [ -n "$container" ] || continue
        printf '   - `%s` (host: %s)\n' "$container" "$root"
      done
    else
      printf '   (no archive roots were configured - mount them and re-run the installer)\n'
    fi
    cat <<MD
3. Run a scan, review expected savings, then enqueue transcodes.
4. The embedded worker transcodes inside this container
MD
    if [ "$MORPHEUS_GPU" = "1" ]; then
      printf '   using the NVIDIA GPU.\n'
    else
      printf '   on CPU.\n'
    fi
    printf '\n'
  fi
  if [ "$COMP_QBITTORRENT" = "1" ]; then
    cat <<MD
### qBittorrent

MD
    if [ "$QBIT_PRESET" = "1" ]; then
      cat <<MD
The WebUI credentials are already preset - no temporary password from the
logs is needed: username \`admin\`, password \`$QBIT_PASSWORD\` (also in
\`.env\` as \`QBIT_PASSWORD\`; Zephyrus uses the same via the generated
config.yaml). The default download location is preset to the shared
\`downloads/\` directory.

1. Open the URL above and log in with admin + the password.
2. If you change the password later, put the new one into \`.env\`
   (\`QBIT_PASSWORD\`) and run \`docker compose up -d\` so Zephyrus follows -
   or re-run the installer to generate and preset a fresh one everywhere.

MD
    else
      cat <<MD
The installer could not preset the WebUI password (python3/OpenSSL 3 not
found). qBittorrent 5.x prints a **temporary password** in the container
logs on first start:

    docker compose logs qbittorrent | grep -i -A2 "temporary password"

Log in with admin + the temporary password, then set the WebUI password to
\`$QBIT_PASSWORD\` (from \`.env\`) so it matches what the apps expect.

MD
    fi
  fi
  if [ "$COMP_PROWLARR" = "1" ]; then
    cat <<MD
### Prowlarr

Open the WebUI, add your indexers, then add Prowlarr as the indexer in
Eros/Psyche (Settings -> Services).

MD
  fi
  if [ "$COMP_JELLYFIN" = "1" ]; then
    cat <<MD
### Jellyfin

Complete the setup wizard, then add libraries from:
MD
    [ "$SUB_SERIES" = "1" ] && printf '    - /media/series (host: %s)\n' "$DATA_ROOT/media/series"
    [ "$SUB_MOVIES" = "1" ] && printf '    - /media/movies (host: %s)\n' "$DATA_ROOT/media/movies"
    [ "$JELLYFIN_ADULT" = "1" ] && printf '    - /media/adult (host: %s)\n' "$DATA_ROOT/media/adult"
    printf '\n'
  fi
  cat <<MDTAIL
## Removing the stack

One line removes the whole stack and everything the installer created:

    docker compose down && rm -rf $INSTALL_DIR

All state lives under the install directory (app configs under \`data/\`,
media and downloads under the data root). Extra archive directories you
added yourself are never deleted automatically.

## Backups

Only these hold state worth backing up:

MDTAIL
  [ "$APP_ZEPHYRUS" = "1" ] && printf '    - data/zephyrus/config (config.yaml) and data/zephyrus/data (SQLite DB)\n'
  [ "$APP_EROS" = "1" ] && printf '    - data/eros/config (DB + session secret + backups)\n'
  [ "$APP_PSYCHE" = "1" ] && printf '    - data/psyche/config (DB + settings + session secret)\n'
  [ "$APP_MORPHEUS" = "1" ] && printf '    - data/morpheus/config (DB + settings + session secret)\n'
  [ "$COMP_QBITTORRENT" = "1" ] && printf '    - data/qbittorrent/config\n'
  [ "$COMP_PROWLARR" = "1" ] && printf '    - data/prowlarr/config\n'
  [ "$COMP_JELLYFIN" = "1" ] && printf '    - data/jellyfin/config\n'
  printf '\nEverything under data/ that is not listed above is regenerable cache.\n'
  case "$DATA_ROOT" in
    "$INSTALL_DIR"|"$INSTALL_DIR"/*) : ;;
    *)
      printf '\nNote: your data root (%s) is OUTSIDE the install directory -\n' "$DATA_ROOT"
      printf 'remove it separately when removing the stack.\n' ;;
  esac
} > "$STEPS_FILE"

# ---------------------------------------------------------------------------
# Validate the generated compose file (no daemon needed)
# ---------------------------------------------------------------------------
if (cd "$INSTALL_DIR" && docker compose -f docker-compose.yml --env-file .env config -q >/dev/null 2>&1); then
  info "docker compose config: valid."
else
  warn "docker compose config reported a problem - inspect with:"
  warn "  cd $INSTALL_DIR && docker compose --env-file .env config"
  (cd "$INSTALL_DIR" && docker compose -f docker-compose.yml --env-file .env config >/dev/null) 2>&1 | head -20 >&2 || true
fi

# ---------------------------------------------------------------------------
# Optionally start
# ---------------------------------------------------------------------------
printf '\n' >&2
info "Files written:"
info "  $COMPOSE_FILE"
info "  $ENV_FILE"
info "  $STEPS_FILE"

if [ "$DOCKER_DAEMON_OK" = "1" ]; then
  if ask_yn "Start the stack now with 'docker compose up -d'?" "y"; then
    if (cd "$INSTALL_DIR" && docker compose up -d); then
      printf '\n' >&2
      (cd "$INSTALL_DIR" && docker compose ps) || true
      printf '\n' >&2
      info "Stack started. Open NEXT_STEPS.md for the first-run checklist."
    else
      warn "'docker compose up -d' failed - check: docker compose logs"
    fi
  else
    info "Start later with: cd $INSTALL_DIR && docker compose up -d"
  fi
else
  info "Docker daemon unreachable - start later with: cd $INSTALL_DIR && docker compose up -d"
fi

printf '\n%s\n' "${C_BOLD}${C_GREEN}Done.${C_RESET} Next: cat $STEPS_FILE" >&2
