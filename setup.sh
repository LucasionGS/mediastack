#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

CONFIG_SERVICES=(plex sonarr radarr whisparr prowlarr qbittorrent bazarr seerr)
MEDIA_FOLDERS=(other tv movies music downloads)

info() { printf '\n[info] %s\n' "$*"; }
warn() { printf '\n[warn] %s\n' "$*" >&2; }
die() { printf '\n[error] %s\n' "$*" >&2; exit 1; }

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer

  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer
    printf '%s' "$answer"
  fi
}

ask_required() {
  local prompt="$1"
  local default="${2:-}"
  local answer

  while true; do
    answer="$(ask "$prompt" "$default")"
    if [[ -n "$answer" ]]; then
      printf '%s' "$answer"
      return 0
    fi
    warn "A value is required."
  done
}

confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local suffix answer

  case "${default,,}" in
    y|yes) suffix="Y/n" ;;
    n|no) suffix="y/N" ;;
    *) suffix="y/n" ;;
  esac

  while true; do
    read -r -p "$prompt [$suffix]: " answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

get_env_value() {
  local key="$1"
  local file="${2:-$ENV_FILE}"

  [[ -f "$file" ]] || return 0
  awk -F= -v key="$key" '
    $0 ~ "^[[:space:]]*#" { next }
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^'\''|'\''$/, "", value)
      print value
      exit
    }
  ' "$file"
}

default_from_env() {
  local key="$1"
  local fallback="$2"
  local value=""

  if [[ -f "$ENV_FILE" ]]; then
    value="$(get_env_value "$key" "$ENV_FILE")"
  fi
  if [[ -z "$value" && -f "$ENV_EXAMPLE" ]]; then
    value="$(get_env_value "$key" "$ENV_EXAMPLE")"
  fi
  printf '%s' "${value:-$fallback}"
}

default_domain_value() {
  local key="$1"
  local subdomain="$2"
  local base_domain="$3"
  local value=""

  if [[ -f "$ENV_FILE" ]]; then
    value="$(get_env_value "$key" "$ENV_FILE")"
  fi
  if [[ -z "$value" && -f "$ENV_EXAMPLE" ]]; then
    value="$(get_env_value "$key" "$ENV_EXAMPLE")"
  fi

  if [[ -n "$value" ]]; then
    value="${value//\$\{DOMAIN\}/$base_domain}"
    value="${value//\$DOMAIN/$base_domain}"
  fi

  printf '%s' "${value:-$subdomain.$base_domain}"
}

default_secret_value() {
  local key="$1"
  local value=""

  if [[ -f "$ENV_FILE" ]]; then
    value="$(get_env_value "$key" "$ENV_FILE")"
  fi
  case "$value" in
    claim-XXXXXXXXXXXXXXXXXXXX|WINDSCRIBE_USER|WINDSCRIBE_PASS) value="" ;;
  esac
  printf '%s' "$value"
}

quote_env() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

mkdir_with_sudo() {
  local path="$1"

  if [[ -d "$path" ]]; then
    return 0
  fi

  if mkdir -p "$path" 2>/dev/null; then
    return 0
  fi

  command_exists sudo || die "Cannot create $path without sudo. Install sudo or create it manually."
  sudo mkdir -p "$path"
}

chown_with_sudo() {
  local owner="$1"
  local path="$2"

  if chown -R "$owner" "$path" 2>/dev/null; then
    return 0
  fi

  command_exists sudo || die "Cannot chown $path without sudo."
  sudo chown -R "$owner" "$path"
}

detect_timezone() {
  if command_exists timedatectl; then
    timedatectl show -p Timezone --value 2>/dev/null || true
  elif [[ -f /etc/timezone ]]; then
    tr -d '[:space:]' </etc/timezone
  else
    printf 'UTC'
  fi
}

check_prerequisites() {
  info "Checking prerequisites"

  command_exists docker || warn "Docker was not found. Install Docker before starting the stack."
  if command_exists docker && ! docker compose version >/dev/null 2>&1; then
    warn "Docker Compose v2 was not found. Install the Docker compose plugin before starting the stack."
  fi
}

collect_settings() {
  local default_domain default_media_dir default_config_dir detected_tz
  local default_download_dir default_web_port default_puid default_pgid

  default_puid="$(id -u)"
  default_pgid="$(id -g)"
  detected_tz="$(detect_timezone)"

  PUID="$(ask_required "PUID" "$(default_from_env PUID "$default_puid")")"
  PGID="$(ask_required "PGID" "$(default_from_env PGID "$default_pgid")")"
  TZ="$(ask_required "Timezone" "$(default_from_env TZ "${detected_tz:-UTC}")")"

  default_web_port="$(default_from_env WEB_PORT 80)"
  WEB_PORT="$(ask_required "Traefik HTTP port" "$default_web_port")"

  default_domain="$(default_from_env DOMAIN media.local)"
  DOMAIN="$(ask_required "Base domain" "$default_domain")"

  DOMAIN_PROWLARR="$(ask_required "Prowlarr domain" "$(default_domain_value DOMAIN_PROWLARR prowlarr "$DOMAIN")")"
  DOMAIN_SONARR="$(ask_required "Sonarr domain" "$(default_domain_value DOMAIN_SONARR sonarr "$DOMAIN")")"
  DOMAIN_RADARR="$(ask_required "Radarr domain" "$(default_domain_value DOMAIN_RADARR radarr "$DOMAIN")")"
  DOMAIN_WHISPARR="$(ask_required "Whisparr domain" "$(default_domain_value DOMAIN_WHISPARR whisparr "$DOMAIN")")"
  DOMAIN_BAZARR="$(ask_required "Bazarr domain" "$(default_domain_value DOMAIN_BAZARR bazarr "$DOMAIN")")"
  DOMAIN_PLEX="$(ask_required "Plex domain" "$(default_domain_value DOMAIN_PLEX plex "$DOMAIN")")"
  DOMAIN_QBITTORRENT="$(ask_required "qBittorrent domain" "$(default_domain_value DOMAIN_QBITTORRENT qbit "$DOMAIN")")"
  DOMAIN_SEERR="$(ask_required "Seerr domain" "$(default_domain_value DOMAIN_SEERR seerr "$DOMAIN")")"

  PLEX_CLAIM="$(ask "Plex claim token (leave blank to claim later)" "$(default_secret_value PLEX_CLAIM)")"

  default_config_dir="$(default_from_env CONFIG_DIR /opt/mediastack/config)"
  default_media_dir="$(default_from_env MEDIA_DIR /media/mediapool)"
  default_download_dir="$(default_from_env DOWNLOAD_DIR "$default_media_dir/downloads")"

  CONFIG_DIR="$(ask_required "Config directory" "$default_config_dir")"
  MEDIA_DIR="$(ask_required "Media directory or ZFS mountpoint" "$default_media_dir")"
  DOWNLOAD_DIR="$(ask_required "Download directory" "$default_download_dir")"

  USE_VPN=false
  if confirm "Use VPN mode for qBittorrent through Gluetun?" "n"; then
    USE_VPN=true
    VPN_SERVICE_PROVIDER="$(ask_required "VPN service provider" "$(default_from_env VPN_SERVICE_PROVIDER windscribe)")"
    VPN_TYPE="$(ask_required "VPN type" "$(default_from_env VPN_TYPE openvpn)")"
    OPENVPN_USER="$(ask_required "OpenVPN username" "$(default_secret_value OPENVPN_USER)")"
    OPENVPN_PASSWORD="$(ask_required "OpenVPN password" "$(default_secret_value OPENVPN_PASSWORD)")"
    SERVER_REGIONS="$(ask_required "VPN server regions" "$(default_from_env SERVER_REGIONS Netherlands)")"
  else
    VPN_SERVICE_PROVIDER="$(default_from_env VPN_SERVICE_PROVIDER windscribe)"
    VPN_TYPE="$(default_from_env VPN_TYPE openvpn)"
    OPENVPN_USER="$(default_from_env OPENVPN_USER "")"
    OPENVPN_PASSWORD="$(default_from_env OPENVPN_PASSWORD "")"
    SERVER_REGIONS="$(default_from_env SERVER_REGIONS Netherlands)"
  fi

  ENABLE_ADULT=false
  if confirm "Enable the Whisparr adult profile?" "n"; then
    ENABLE_ADULT=true
  fi
}

write_env_file() {
  local tmp_file
  tmp_file="$(mktemp)"

  cat >"$tmp_file" <<EOF
# Generated by setup.sh

# User/group IDs
PUID=$PUID
PGID=$PGID

# Traefik and domains
WEB_PORT=$WEB_PORT
DOMAIN=$(quote_env "$DOMAIN")
DOMAIN_PROWLARR=$(quote_env "$DOMAIN_PROWLARR")
DOMAIN_SONARR=$(quote_env "$DOMAIN_SONARR")
DOMAIN_RADARR=$(quote_env "$DOMAIN_RADARR")
DOMAIN_WHISPARR=$(quote_env "$DOMAIN_WHISPARR")
DOMAIN_BAZARR=$(quote_env "$DOMAIN_BAZARR")
DOMAIN_PLEX=$(quote_env "$DOMAIN_PLEX")
DOMAIN_QBITTORRENT=$(quote_env "$DOMAIN_QBITTORRENT")
DOMAIN_SEERR=$(quote_env "$DOMAIN_SEERR")

# Timezone
TZ=$(quote_env "$TZ")

# Plex
PLEX_CLAIM=$(quote_env "$PLEX_CLAIM")

# Paths
CONFIG_DIR=$(quote_env "$CONFIG_DIR")
MEDIA_DIR=$(quote_env "$MEDIA_DIR")
DOWNLOAD_DIR=$(quote_env "$DOWNLOAD_DIR")

# VPN mode values, used by docker-compose.vpn.yml
VPN_SERVICE_PROVIDER=$(quote_env "$VPN_SERVICE_PROVIDER")
VPN_TYPE=$(quote_env "$VPN_TYPE")
OPENVPN_USER=$(quote_env "$OPENVPN_USER")
OPENVPN_PASSWORD=$(quote_env "$OPENVPN_PASSWORD")
SERVER_REGIONS=$(quote_env "$SERVER_REGIONS")
EOF

  if [[ -f "$ENV_FILE" ]]; then
    local backup_file
    backup_file="$ENV_FILE.backup.$(date +%Y%m%d%H%M%S)"
    cp "$ENV_FILE" "$backup_file"
    info "Backed up existing .env to $backup_file"
  fi

  mv "$tmp_file" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  info "Wrote $ENV_FILE"
}

setup_zfs_if_requested() {
  USE_ZFS=false
  if ! confirm "Use ZFS for the media folders?" "n"; then
    return 0
  fi
  USE_ZFS=true

  if ! command_exists zpool || ! command_exists zfs; then
    warn "ZFS tools were not found. Install zfs-dkms/zfs-utils or your distro equivalents, then rerun this script."
    if confirm "Continue by creating normal directories instead?" "y"; then
      USE_ZFS=false
      return 0
    fi
    die "ZFS setup requested but ZFS tools are unavailable."
  fi

  info "Available block devices"
  lsblk -o NAME,SIZE,MODEL,TYPE || true
  info "Stable disk IDs"
  ls -lA /dev/disk/by-id/ 2>/dev/null || warn "/dev/disk/by-id is unavailable."

  local pool_name
  pool_name="$(ask_required "ZFS pool name" mediapool)"

  if zpool list -H "$pool_name" >/dev/null 2>&1; then
    info "Using existing ZFS pool $pool_name"
  else
    warn "Pool creation is destructive for the selected devices. Use base /dev/disk/by-id devices, not partition paths ending in -partN."
    if confirm "Create mirrored ZFS pool $pool_name now?" "n"; then
      local drive_one drive_two
      drive_one="$(ask_required "First mirror drive by-id path" "")"
      drive_two="$(ask_required "Second mirror drive by-id path" "")"
      command_exists sudo || die "sudo is required to create a ZFS pool."
      sudo zpool create "$pool_name" mirror "$drive_one" "$drive_two"
    else
      die "Cannot continue ZFS setup without an existing or newly created pool."
    fi
  fi

  command_exists sudo || die "sudo is required to configure ZFS datasets."
  sudo zfs set compression=lz4 "$pool_name"
  sudo zfs set atime=off "$pool_name"
  sudo zfs set mountpoint="$MEDIA_DIR" "$pool_name"

  for folder in "${MEDIA_FOLDERS[@]}"; do
    if ! zfs list -H "$pool_name/$folder" >/dev/null 2>&1; then
      sudo zfs create "$pool_name/$folder"
    fi
  done

  if [[ "$ENABLE_ADULT" == true ]] && ! zfs list -H "$pool_name/adultmovies" >/dev/null 2>&1; then
    sudo zfs create "$pool_name/adultmovies"
  fi
}

create_directories() {
  info "Creating config directories"
  for service in "${CONFIG_SERVICES[@]}"; do
    mkdir_with_sudo "$CONFIG_DIR/$service"
  done

  if [[ "$USE_ZFS" == true ]]; then
    info "ZFS datasets are ready under $MEDIA_DIR"
  else
    info "Creating media directories"
    for folder in "${MEDIA_FOLDERS[@]}"; do
      mkdir_with_sudo "$MEDIA_DIR/$folder"
    done
    if [[ "$ENABLE_ADULT" == true ]]; then
      mkdir_with_sudo "$MEDIA_DIR/adultmovies"
    fi
  fi

  if [[ "$DOWNLOAD_DIR" != "$MEDIA_DIR/downloads" ]]; then
    mkdir_with_sudo "$DOWNLOAD_DIR"
  fi

  if confirm "Set ownership of config/media directories to $PUID:$PGID?" "y"; then
    chown_with_sudo "$PUID:$PGID" "$CONFIG_DIR"
    chown_with_sudo "$PUID:$PGID" "$MEDIA_DIR"
    if [[ "$DOWNLOAD_DIR" != "$MEDIA_DIR/downloads" ]]; then
      chown_with_sudo "$PUID:$PGID" "$DOWNLOAD_DIR"
    fi
  fi
}

add_hosts_entries_if_requested() {
  if ! confirm "Add service domains to /etc/hosts pointing to 127.0.0.1?" "y"; then
    return 0
  fi

  local hosts_file="/etc/hosts"
  local marker_start="# MediaStack domains - setup.sh start"
  local marker_end="# MediaStack domains - setup.sh end"
  local tmp_file
  local domains=(
    "$DOMAIN_PLEX"
    "$DOMAIN_SONARR"
    "$DOMAIN_RADARR"
    "$DOMAIN_WHISPARR"
    "$DOMAIN_PROWLARR"
    "$DOMAIN_QBITTORRENT"
    "$DOMAIN_BAZARR"
    "$DOMAIN_SEERR"
  )
  local clean_domains=()
  local domain
  declare -A seen_domains=()

  for domain in "${domains[@]}"; do
    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"
    domain="${domain%%:*}"

    if [[ -n "$domain" && -z "${seen_domains[$domain]:-}" ]]; then
      clean_domains+=("$domain")
      seen_domains[$domain]=1
    fi
  done

  if [[ "${#clean_domains[@]}" -eq 0 ]]; then
    warn "No service domains were available to add to /etc/hosts."
    return 0
  fi

  tmp_file="$(mktemp)"
  awk -v start="$marker_start" -v end="$marker_end" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$hosts_file" >"$tmp_file"

  {
    printf '\n%s\n' "$marker_start"
    printf '127.0.0.1'
    printf ' %s' "${clean_domains[@]}"
    printf '\n%s\n' "$marker_end"
  } >>"$tmp_file"

  if cp "$tmp_file" "$hosts_file" 2>/dev/null; then
    rm -f "$tmp_file"
  else
    command_exists sudo || die "Cannot update /etc/hosts without sudo."
    sudo cp "$tmp_file" "$hosts_file"
    rm -f "$tmp_file"
  fi

  info "Updated /etc/hosts for: ${clean_domains[*]}"
}

start_stack_if_requested() {
  if ! confirm "Start the stack now?" "y"; then
    return 0
  fi

  command_exists docker || die "Docker is required to start the stack."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required to start the stack."

  local compose_cmd=(docker compose)
  if [[ "$USE_VPN" == true ]]; then
    compose_cmd=(docker compose -f docker-compose.vpn.yml)
  fi

  info "Starting containers"
  if [[ "$ENABLE_ADULT" == true ]]; then
    (cd "$SCRIPT_DIR" && COMPOSE_PROFILES=adult "${compose_cmd[@]}" up -d)
  else
    (cd "$SCRIPT_DIR" && "${compose_cmd[@]}" up -d)
  fi
}

print_summary() {
  cat <<EOF

Setup complete.

Service URLs:
  Plex:         http://$DOMAIN_PLEX
  Sonarr:       http://$DOMAIN_SONARR
  Radarr:       http://$DOMAIN_RADARR
  Whisparr:     http://$DOMAIN_WHISPARR
  Prowlarr:     http://$DOMAIN_PROWLARR
  qBittorrent:  http://$DOMAIN_QBITTORRENT
  Bazarr:       http://$DOMAIN_BAZARR
  Seerr:        http://$DOMAIN_SEERR

Direct ports remain available where exposed by the compose files.
Create DNS records for the service domains so they point at this Docker host.
To find the initial qBittorrent password, run: docker logs qbittorrent
EOF

  if [[ "$USE_VPN" == true ]]; then
    cat <<EOF

VPN mode note:
  qBittorrent's network is attached to Gluetun. Configure other containers to use gluetun:8080 for qBittorrent when an internal hostname is needed.
EOF
  fi

  cat <<EOF

Recommended configuration order:
  1. Prowlarr: add indexers
  2. qBittorrent: log in and set credentials
  3. Sonarr/Radarr: add qBittorrent and connect Prowlarr
  4. Bazarr: link Sonarr and Radarr
  5. Plex: add /tv, /movies, /music libraries
  6. Seerr: link Plex, Sonarr, and Radarr
EOF
}

main() {
  cd "$SCRIPT_DIR"

  check_prerequisites

  if [[ -f "$ENV_FILE" ]]; then
    if confirm ".env already exists. Keep it and only create directories/start services?" "y"; then
      PUID="$(default_from_env PUID "$(id -u)")"
      PGID="$(default_from_env PGID "$(id -g)")"
      TZ="$(default_from_env TZ "$(detect_timezone)")"
      WEB_PORT="$(default_from_env WEB_PORT 80)"
      DOMAIN="$(default_from_env DOMAIN media.local)"
      DOMAIN_PROWLARR="$(default_domain_value DOMAIN_PROWLARR prowlarr "$DOMAIN")"
      DOMAIN_SONARR="$(default_domain_value DOMAIN_SONARR sonarr "$DOMAIN")"
      DOMAIN_RADARR="$(default_domain_value DOMAIN_RADARR radarr "$DOMAIN")"
      DOMAIN_WHISPARR="$(default_domain_value DOMAIN_WHISPARR whisparr "$DOMAIN")"
      DOMAIN_BAZARR="$(default_domain_value DOMAIN_BAZARR bazarr "$DOMAIN")"
      DOMAIN_PLEX="$(default_domain_value DOMAIN_PLEX plex "$DOMAIN")"
      DOMAIN_QBITTORRENT="$(default_domain_value DOMAIN_QBITTORRENT qbit "$DOMAIN")"
      DOMAIN_SEERR="$(default_domain_value DOMAIN_SEERR seerr "$DOMAIN")"
      CONFIG_DIR="$(default_from_env CONFIG_DIR /opt/mediastack/config)"
      MEDIA_DIR="$(default_from_env MEDIA_DIR /media/mediapool)"
      DOWNLOAD_DIR="$(default_from_env DOWNLOAD_DIR "$MEDIA_DIR/downloads")"
      USE_VPN=false
      ENABLE_ADULT=false
      confirm "Use VPN compose mode when starting?" "n" && USE_VPN=true
      confirm "Enable the Whisparr adult profile when starting?" "n" && ENABLE_ADULT=true
    else
      collect_settings
      write_env_file
    fi
  else
    collect_settings
    write_env_file
  fi

  setup_zfs_if_requested
  create_directories
  add_hosts_entries_if_requested
  start_stack_if_requested
  print_summary
}

main "$@"
