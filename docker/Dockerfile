FROM debian:trixie AS builder

LABEL maintainer="Fulcrum-Alpha Development"

ARG MAKEFLAGS

RUN apt update -y && \
    apt install -y \
        openssl git build-essential pkg-config zlib1g-dev libbz2-dev libjemalloc-dev libzmq3-dev qtbase5-dev \
        qt5-qmake libminiupnpc-dev

WORKDIR /src

COPY . .

RUN qmake -makefile PREFIX=/usr Fulcrum.pro && \
    make $MAKEFLAGS install

FROM ghcr.io/unicitynetwork/ssl-manager:latest

# ssl-manager is based on debian:trixie-slim and already includes:
#   certbot, openssl, curl, jq, netcat-openbsd, python3, procps, ca-certificates
#
# Fulcrum-specific runtime dependencies only:
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libqt5network5 \
        zlib1g \
        libbz2-1.0 \
        libjemalloc2 \
        libzmq5 \
        libminiupnpc18 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=builder /src/Fulcrum /usr/bin/Fulcrum
COPY --from=builder /src/FulcrumAdmin /usr/bin/FulcrumAdmin

# Create directory for fulcrum config and data
RUN mkdir -p /etc/fulcrum /data

# Copy the default configuration file
COPY docker/fulcrum.conf.default /etc/fulcrum/fulcrum.conf.default

VOLUME ["/data"]
VOLUME ["/etc/letsencrypt"]
ENV DATA_DIR=/data

# Fulcrum Electrum protocol ports
EXPOSE 50001 50002 50003 50004

# Port 80 is used by ssl-manager's HTTP reverse proxy (EXPOSE'd by base image)

# Health check - verify Fulcrum is responding on TCP port
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD nc -z localhost 50001 || exit 1

COPY docker/docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

CMD ["Fulcrum"]
