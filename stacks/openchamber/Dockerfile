# OpenChamber's web app is the @openchamber/web npm package (the install script
# in their docs is a wrapper around it). Pinned rather than :latest so a deploy
# cannot change the UI under us; Renovate does not track npm inside a
# Dockerfile, so bump this by hand with the release notes.
FROM node:26-bookworm-slim

# git backs the diff/walkthrough/git features. curl is only for debugging
# inside the container. The web app needs Node >= 24.14.
# OpenChamber requires the opencode CLI on PATH even when it does not start a
# server (it is used for version and capability checks). Keep it on the same
# version as stacks/opencode: Renovate updates both through the annotation
# below and groups them in renovate.json.
# renovate: datasource=npm depName=@opencode/cli
ARG OPENCODE_VERSION=2.3.2
# renovate: datasource=npm depName=@openchamber/web
ARG OPENCHAMBER_VERSION=2.8.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g "@openchamber/web@${OPENCHAMBER_VERSION}" "@opencode/cli@${OPENCODE_VERSION}" \
 && mkdir -p /data /srv/workspace \
 && chown node:node /data /srv/workspace

USER node
WORKDIR /home/node
EXPOSE 3000

# --foreground keeps the server attached to the container instead of letting
# the CLI daemonise. Everything else comes from the environment.
CMD ["openchamber", "--foreground"]
