# MediaStack — Drop-in Plex + Automation Setup

## Stack

| Service | Purpose | Port |
| --- | --- | --- |
| Plex | Media server | host networking |
| Sonarr | TV show automation | 8989 |
| Radarr | Movie automation | 7878 |
| Prowlarr | Indexer manager | 9696 |
| qBittorrent | Download client | 8080 |
| Bazarr | Subtitle downloader | 6767 |
| Overseerr | Request portal | 5055 |

## Setup

### 0. Prerequisites

If you are going to use ZFS for the file system and raid, you will need to set it up

```bash
# Install ZFS DKMS (builds against your running kernel)
yay -S zfs-dkms zfs-utils # Or whichever AUR helper you desire

# Enable the kernel module
sudo modprobe zfs # Or reboot the system if this doesn't work, then continue below

# Enable and start the service
sudo systemctl enable --now zfs-import-cache
sudo systemctl enable --now zfs-mount
sudo systemctl enable --now zfs-zed
```

### 1. Edit .env

```bash
# Get your user/group IDs
id $USER

# Edit the env file
cp .env.example .env
vim .env
```

Fill in:

- `PUID` / `PGID` — from `id $USER`
- `TZ` — your timezone
- `PLEX_CLAIM` — from <https://www.plex.tv/claim>
- `MEDIA_DIR` — your ZFS pool mountpoint (e.g. /media/mediapool)

### 2. Create directories

```bash
mkdir -p /opt/mediastack/config/{plex,sonarr,radarr,prowlarr,qbittorrent,bazarr,overseerr}
```

Option 1 - Create the data folders using ZFS datasets, ideally using raid like:

```bash

# Identify your drives first
lsblk -o NAME,SIZE,MODEL
ls -lA /dev/disk/by-id/  # Always use by-id, never /dev/sdX

# Create mirror pool
# Note: you cannot use partitions for this (-part suffixed), it must be the base device.
zpool create mediapool mirror \
  /dev/disk/by-id/drive1 \
  /dev/disk/by-id/drive2

# Verify
zpool status mediapool

# Optimizations
# Enable compression (transparent, saves ~20-30% on media)
zfs set compression=lz4 mediapool

# Disable access time (reduces unnecessary writes)
zfs set atime=off mediapool

# Set mountpoint
zfs set mountpoint=/media mediapool

# Create the data folders
zfs create mediapool/other
zfs create mediapool/tv
zfs create mediapool/movies
zfs create mediapool/music
zfs create mediapool/downloads
```

Option 2 - Create the data folders without ZFS (Less recommended):

```bash
mkdir -p /media/mediapool/{other,tv,movies,music,downloads}
```

### 3. Spin up

You have 2 options when how you want to deploy:

#### Option 1 - Without VPN

```bash
docker compose up -d
```

#### Option 2 - With VPN

Make sure you define these in your .env (Example):

```bash
VPN_SERVICE_PROVIDER=windscribe
VPN_TYPE=openvpn
OPENVPN_USER=WINDSCRIBE_OPENVPN_USER
OPENVPN_PASSWORD=WINDSCRIBE_OPENVPN_PASS
SERVER_REGIONS=Netherlands
```

```bash
docker compose -f docker-compose.vpn.yml up -d
```

**Note:** When using VPN, all of `qbittorrent`'s traffic proxies through `gluetun`, so when you have to refer to `qbittorrent` regarding port traffic such as configurations pointing to the `qbittorrent:8080` host, you should use `gluetun:8080` instead

### 4. Configure (in order)

1. **Prowlarr** (`:9696`) — add your indexers
2. **qBittorrent** (`:8080`) — note the temp password from logs: `docker logs qbittorrent`
3. **Sonarr** (`:8989`) — add qBittorrent as download client, connect Prowlarr
4. **Radarr** (`:7878`) — same as Sonarr
5. **Bazarr** (`:6767`) — link Sonarr + Radarr, add subtitle providers
6. **Plex** — add libraries pointing to /tv, /movies, /music
7. **Overseerr** (`:5055`) — link to Plex, then Sonarr + Radarr

## Important: Hardlinks

For Sonarr/Radarr to move files without copying (saving disk I/O), downloads
and media must be on the same filesystem.  
If you are using ZFS, That means your DOWNLOAD_DIR should be on the same ZFS pool rather than a separate path

## Updating

```bash
docker compose pull && docker compose up -d
```
