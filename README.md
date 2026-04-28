# MediaStack — Drop-in Plex + Automation Setup

## Stack
| Service | Purpose | Port |
|---|---|---|
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
- `PLEX_CLAIM` — from https://www.plex.tv/claim
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
zfs create mediapool/tv
zfs create mediapool/movies
zfs create mediapool/music
zfs create mediapool/downloads
```

Option 2 - Create the data folders without ZFS (Less recommended):
```bash
mkdir -p /media/mediapool/{tv,movies,music,downloads}
```

### 3. Spin up
```bash
docker compose up -d
```

### 4. Configure (in order)
1. **Prowlarr** (`:9696`) — add your indexers
2. **qBittorrent** (`:8080`) — note the temp password from logs: `docker logs qbittorrent`
3. **Sonarr** (`:8989`) — add qBittorrent as download client, connect Prowlarr
4. **Radarr** (`:7878`) — same as Sonarr
5. **Bazarr** (`:6767`) — link Sonarr + Radarr, add subtitle providers
6. **Plex** — add libraries pointing to /tv, /movies, /music
7. **Overseerr** (`:5055`) — link to Plex, then Sonarr + Radarr

### (Optional) 5. Setup qBitTorrent proxy
Under qBitTorrent's web interface, go to `Settings` → `Connection` → `Proxy Server`

Example:
```
Type:     SOCKS5 (Windscribe supports this)
Host:     proxy.windscribe.com
Port:     1080
Username: your Windscribe username
Password: your Windscribe password
```

**Disable connections not supported by proxies** ← prevents traffic leaking outside proxy

## Important: Hardlinks
For Sonarr/Radarr to move files without copying (saving disk I/O), downloads
and media must be on the same filesystem.  
If you are using ZFS, That means your DOWNLOAD_DIR should be on the same ZFS pool rather than a separate path

## Updating
```bash
docker compose pull && docker compose up -d
```