FROM eclipse-temurin:25-jre

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      coreutils \
      curl \
      findutils \
      iproute2 \
      procps \
      tmux \
      unzip \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 989 hytale \
 && useradd --uid 989 --gid 989 --create-home --shell /bin/bash hytale

COPY entrypoint.sh /usr/local/bin/hytale-entrypoint
RUN chmod 0755 /usr/local/bin/hytale-entrypoint

USER 989:989
WORKDIR /data/Server

ENTRYPOINT ["/usr/local/bin/hytale-entrypoint"]
