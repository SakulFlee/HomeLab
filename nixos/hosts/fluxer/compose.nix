# Run Fluxer via Docker Compose using official upstream files.
# Upstream files (docker-compose.yml, Caddyfile, livekit.yaml, .env.example)
# are vendored in the VM image under /opt/fluxer/.
{ config, lib, pkgs, ... }:
let
  fluxerDir = "/opt/fluxer";
in
{
  # Install Docker and Compose v2.
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
  };

  environment.systemPackages = with pkgs; [
    docker-compose
  ];

  # Ensure Docker data dir exists and has correct permissions.
  systemd.tmpfiles.rules = [
    "d /var/lib/docker 0711 root root -"
    "d ${fluxerDir} 0755 root root -"
  ];

  systemd.services.fluxer-env = {
    description = "Render Fluxer .env from sops secrets";
    after = [ "network-online.target" ];
    before = [ "fluxer-compose.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -e
      # Secrets land in /var/lib/incus-secrets via renderedSecrets in incus.nix
      # (apply.sh copies them from the host's /run/secrets). There is no sops
      # decryption inside this VM and no /run/secrets here.
      SECDIR=/var/lib/incus-secrets
      cat > ${fluxerDir}/.env << 'EOF'
FLUXER_DOMAIN=fluxer.sakul-flee.de
FLUXER_PUBLIC_SCHEME=https
FLUXER_PUBLIC_PORT=443
FLUXER_CADDY_SITE_ADDRESS=fluxer.sakul-flee.de
FLUXER_APP_ORIGIN_ALIASES=https://fluxer-next.sakul-flee.de
LIVEKIT_API_KEY=fluxer
EOF

      # Append secrets from rendered files if they exist
      if [ -r $SECDIR/fluxer_postgres_password ]; then
        echo "POSTGRES_PASSWORD=$(cat $SECDIR/fluxer_postgres_password)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_search_api_key ]; then
        echo "MEILI_MASTER_KEY=$(cat $SECDIR/fluxer_search_api_key)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_s3_secret_access_key ]; then
        echo "FLUXER_S3_SECRET_KEY=$(cat $SECDIR/fluxer_s3_secret_access_key)" >> ${fluxerDir}/.env
        echo "FLUXER_S3_ACCESS_KEY=fluxer" >> ${fluxerDir}/.env
        echo "AWS_SECRET_ACCESS_KEY=$(cat $SECDIR/aws_secret_access_key 2>/dev/null || cat $SECDIR/fluxer_s3_secret_access_key)" >> ${fluxerDir}/.env
        echo "AWS_ACCESS_KEY_ID=fluxer" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_sudo_mode_secret ]; then
        echo "FLUXER_SUDO_MODE_SECRET=$(cat $SECDIR/fluxer_sudo_mode_secret)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_connection_initiation_secret ]; then
        echo "FLUXER_CONNECTION_INITIATION_SECRET=$(cat $SECDIR/fluxer_connection_initiation_secret)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_profile_pseudonym_secret ]; then
        echo "FLUXER_PROFILE_PSEUDONYM_SECRET=$(cat $SECDIR/fluxer_profile_pseudonym_secret)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_gateway_rpc_auth_token ]; then
        echo "FLUXER_GATEWAY_RPC_AUTH_TOKEN=$(cat $SECDIR/fluxer_gateway_rpc_auth_token)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_media_proxy_secret_key ]; then
        echo "FLUXER_MEDIA_PROXY_SECRET_KEY=$(cat $SECDIR/fluxer_media_proxy_secret_key)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_media_proxy_upload_relay_secret_base64 ]; then
        echo "FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64=$(cat $SECDIR/fluxer_media_proxy_upload_relay_secret_base64)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_admin_secret_key_base ]; then
        echo "FLUXER_ADMIN_SECRET_KEY_BASE=$(cat $SECDIR/fluxer_admin_secret_key_base)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_admin_oauth_client_secret ]; then
        echo "FLUXER_ADMIN_OAUTH_CLIENT_SECRET=$(cat $SECDIR/fluxer_admin_oauth_client_secret)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_vapid_public_key ]; then
        echo "FLUXER_VAPID_PUBLIC_KEY=$(cat $SECDIR/fluxer_vapid_public_key)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_vapid_private_key ]; then
        echo "FLUXER_VAPID_PRIVATE_KEY=$(cat $SECDIR/fluxer_vapid_private_key)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/livekit_api_secret ]; then
        echo "LIVEKIT_API_SECRET=$(cat $SECDIR/livekit_api_secret)" >> ${fluxerDir}/.env
      fi
      if [ -r $SECDIR/fluxer_erlang_cookie ]; then
        echo "FLUXER_ERLANG_COOKIE=$(cat $SECDIR/fluxer_erlang_cookie)" >> ${fluxerDir}/.env
      fi
      chmod 0600 ${fluxerDir}/.env
    '';
  };

  # Place upstream stack files in the image.
  # These will be copied from the repo at build time via environment.etc
  # or we can just ensure directory exists; files are small and vendored.
  # We'll add environment.etc entries in default.nix or write them here.
  # For now, define service.
  systemd.services.fluxer-compose = {
    description = "Fluxer Docker Compose stack";
    after = [
      "network-online.target"
      "docker.service"
      "fluxer-data-format.service"
      "var-lib-docker.mount"
      "fluxer-env.service"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "docker.service"
      "var-lib-docker.mount"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      WorkingDirectory = fluxerDir;
      Restart = "on-failure";
      RestartSec = "10s";
      TimeoutStartSec = "5min";
    };

    path = with pkgs; [ docker docker-compose bash coreutils findutils gnugrep ];

    script = ''
      set -e

      # Start the stack using the official proxy overlay if present
      if [ -f docker-compose.yml ] && [ -f docker-compose.proxy.yml ]; then
        exec docker compose -f docker-compose.yml -f docker-compose.proxy.yml up -d
      elif [ -f docker-compose.yml ] && [ -f cloudflared.compose.yml ]; then
        exec docker compose -f docker-compose.yml -f cloudflared.compose.yml up -d
      elif [ -f docker-compose.yml ]; then
        exec docker compose up -d
      else
        echo "No docker-compose.yml found in ${fluxerDir}"
        exit 1
      fi
    '';

    preStop = ''
      cd ${fluxerDir}
      if [ -f docker-compose.yml ] && [ -f docker-compose.proxy.yml ]; then
        docker compose -f docker-compose.yml -f docker-compose.proxy.yml down || true
      elif [ -f docker-compose.yml ] && [ -f cloudflared.compose.yml ]; then
        docker compose -f docker-compose.yml -f cloudflared.compose.yml down || true
      elif [ -f docker-compose.yml ]; then
        docker compose down || true
      fi
    '';
  };
}