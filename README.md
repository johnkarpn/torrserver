# torrserver

### Unofficial Docker Image for TorrServer

"TorrServer, stream torrent to http" — unofficial dockerized
precompiled [TorrServer](https://github.com/YouROK/TorrServer) on Ubuntu 26.04 LTS.

![TorrServer](https://raw.githubusercontent.com/johnkarpn/torrserver/main/ts.jpg)

Compared to the [official image](https://github.com/YouROK/TorrServer#running-in-docker--docker-compose) it adds:

- automatic TorrServer updates at start and by schedule, with a backup of the previous version and rollback if the new
  one doesn't start;
- peers blocklist auto-update (eMule ipfilter, P2P or plain lists);
- supervisor: TorrServer is restarted if it crashes, `docker stop` shuts it down gracefully;
- `ffmpeg`/`ffprobe` for media info;
- `PUID`/`PGID`/`UMASK` and a ready template for Unraid;
- multi-arch: `linux/amd64`, `linux/arm64`, `linux/arm/v7`. The image is rebuilt weekly with fresh packages and the
  latest TorrServer.

### Image tags

- `latest` — the latest build, rebuilt weekly.
- `1`, `1.0`, `1.0.0`... — image versions ([semver](https://semver.org/)), not related to the TorrServer version.
  TorrServer itself is updated automatically, see `TS_RELEASE` and `TS_UPDATE`.

### Requirements

* server with docker
* ~256 Mb RAM, ~512 Mb disk space + disk cache (`CacheSize` in settings, 5 Gb by default)

### Installing

#### docker run

```
docker run --name torrserver -e TZ=Europe/Moscow -d --restart=unless-stopped --net=host \
  -v /torrserver/db:/TS/db ghcr.io/johnkarpn/torrserver:latest
```

Web UI: `http://<host>:8090`. Host network is recommended for DLNA, UPnP and peers discovery,
with bridge network publish the web port: `-p 8090:8090`.

#### docker compose

```yaml
services:
  torrserver:
    image: ghcr.io/johnkarpn/torrserver:latest
    container_name: torrserver
    network_mode: host
    restart: unless-stopped
    environment:
      - TZ=Europe/Moscow
    volumes:
      - /torrserver/db:/TS/db
```

#### Unraid

Download the template from the Unraid terminal:

```
wget -O /boot/config/plugins/dockerMan/templates-user/my-TorrServer.xml \
  https://raw.githubusercontent.com/johnkarpn/torrserver/main/unraid/torrserver.xml
```

Then Docker → Add Container → Template → **User templates** → **TorrServer**.

### Configuration

Settings are taken from docker environment variables, then from `ts.ini` in the config directory, then defaults.
Empty environment variables are ignored. `ts.ini` with all options described is created on the first start.

| Variable       | Default                       | Description                                                                                                        |
|----------------|-------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `TS_PORT`      | `8090`                        | Web port                                                                                                           |
| `TS_RELEASE`   | `latest`                      | TorrServer version: `latest` or a [release](https://github.com/YouROK/TorrServer/releases) name, e.g. `MatriX.147` |
| `TS_UPDATE`    | `true`                        | Update TorrServer to `TS_RELEASE` at start and by schedule                                                         |
| `cron_task`    | from `ts.ini`: `20 4 * * *`   | Schedule for updates in cron format, `none` — disabled                                                             |
| `BIP_URL`      | from `ts.ini`: eMule ipfilter | Peers blocklist source (zip, gz or text), `none` — disabled                                                        |
| `TS_OPTIONS`   | empty                         | Extra [TorrServer options](https://github.com/YouROK/TorrServer#server-args), e.g. `-a` for http auth              |
| `PUID`, `PGID` | `0`                           | User and group to run TorrServer as (Unraid: `99`/`100`)                                                           |
| `UMASK`        | empty                         | Permissions mask for created files, e.g. `000` or `022`                                                            |
| `LINUX_UPDATE` | `false`                       | `apt-get upgrade` at start                                                                                         |
| `TZ`           | UTC                           | Time zone for logs and schedule, e.g. `Europe/Moscow`                                                              |

Files in the config directory (`/TS/db`):

| File            | Description                                               |
|-----------------|-----------------------------------------------------------|
| `ts.ini`        | Container settings (see above)                            |
| `settings.json` | TorrServer settings, also editable from the web UI        |
| `config.db`     | Torrents and viewed history                               |
| `accs.db`       | Users for http auth (`-a` option): `{"user": "password"}` |
| `blocklist`     | Peers blocklist, generated from `BIP_URL`                 |
| `torrents/`     | Disk cache and autoload directory for `.torrent` files    |
| `backup/`       | Previous TorrServer version, used for rollback            |

### Notes

- If TorrServer fails to start, the container retries without `TS_OPTIONS`, then with the version from `backup/`.
  To fix a broken binary manually, download it from [releases](https://github.com/YouROK/TorrServer/releases),
  rename to `TorrServer`, put to `backup/` and restart the container.
- Logs of TorrServer, updates and scheduled tasks: `docker logs torrserver`.

More info:

- https://github.com/YouROK/TorrServer
