#
# This is unofficial dockerized precompiled TorrServer
#
FROM alpine:latest

LABEL maintainer="John Karpn"

ENV TS_PORT="8090"
ENV TS_UPDATE="true"
ENV LINUX_UPDATE="true"
ENV TS_RELEASE="latest"
ENV USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"

ENV TS_CONF_PATH=/TS/db
ENV TS_TORR_DIR=/TS/db/torrents

# On linux systems you need to set this environment variable before run:
ENV GODEBUG="madvdontneed=1"

COPY start_TS.sh /start_TS.sh
COPY update_TS.sh /update_TS.sh

RUN apk update \
&& apk upgrade \
&& apk add --no-cache ffmpeg wget curl ca-certificates jq unzip tzdata \
&& mkdir /TS && chmod -R 666 /TS \
&& mkdir -p $TS_CONF_PATH && chmod -R 666 $TS_CONF_PATH

HEALTHCHECK --interval=5s --timeout=10s --retries=3 CMD curl -sS 127.0.0.1:${TS_PORT}/echo || exit 1

VOLUME ${TS_CONF_PATH}

EXPOSE ${TS_PORT}

ENTRYPOINT ["/start_TS.sh"]
