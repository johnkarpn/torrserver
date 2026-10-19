#
# This is unofficial dockerized precompiled TorrServer
#
FROM ubuntu:24.04

LABEL maintainer="John Karpn" \
      org.opencontainers.image.title="TorrServer" \
      org.opencontainers.image.description="Unofficial TorrServer image with auto-updates and IP blocklist" \
      org.opencontainers.image.source="https://github.com/johnkarpn/torrserver"

# TorrServer version bundled into the image, e.g. "latest" or "MatriX.147"
ARG TS_RELEASE=latest
# Changing value invalidates the build cache for packages and TorrServer
ARG BUILD_DATE

ENV TS_CONF_PATH=/TS/db \
    TS_TORR_DIR=/TS/db/torrents \
    USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:147.0) Gecko/20100101 Firefox/147.0" \
    GODEBUG="madvdontneed=1"

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       cron \
       curl \
       ffmpeg \
       file \
       jq \
       tini \
       tzdata \
       unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN case $(dpkg --print-architecture) in \
        amd64) ARCH="amd64" ;; \
        arm64) ARCH="arm64" ;; \
        armhf) ARCH="arm7" ;; \
        i386)  ARCH="386" ;; \
        *) echo "Unsupported architecture"; exit 1 ;; \
    esac \
    && if [ "$TS_RELEASE" = "latest" ]; then \
        URL="https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-$ARCH"; \
    else \
        URL="https://github.com/YouROK/TorrServer/releases/download/$TS_RELEASE/TorrServer-linux-$ARCH"; \
    fi \
    && mkdir -p /TS \
    && curl -fsSL --retry 3 -o /TS/TorrServer "$URL" \
    && chmod 755 /TS/TorrServer \
    && /TS/TorrServer --version

COPY --chmod=755 start_TS.sh update_TS.sh healthcheck.sh /
COPY --chmod=644 ts.ini settings.json /defaults/

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/healthcheck.sh"]

VOLUME /TS/db
EXPOSE 8090

ENTRYPOINT ["/usr/bin/tini", "--", "/start_TS.sh"]
