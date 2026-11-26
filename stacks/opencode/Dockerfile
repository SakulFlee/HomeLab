# The upstream image is Alpine with only the opencode binary: no git, curl or
# jq. A coding agent needs git for snapshots, worktrees and diffs, and Forgejo
# PRs need an HTTP client. tea is the Forgejo CLI for interactive PR work.
# renovate: datasource=docker depName=ghcr.io/anomalyco/opencode
FROM ghcr.io/anomalyco/opencode:2.4.2

USER root
RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      git \
      jq \
      openssh-client \
      tea \
      tzdata \
 && git config --system user.name "SakulFlee" \
 && git config --system user.email "sakulflee@noreply.forgejo.sakul-flee.de" \
 && git config --system credential.helper '!f() { echo username=SakulFlee; echo "password=$FORGEJO_TOKEN"; }; f'

# Compose sets user 990:990 as well; keep the image consistent with it.
USER 990
