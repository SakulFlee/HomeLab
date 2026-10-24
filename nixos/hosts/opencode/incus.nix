let
  devices = {
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.117";
    };

    home = {
      type = "disk";
      pool = "persistent";
      source = "opencode-home";
      path = "/var/lib/opencode";
    };

    workspace = {
      type = "disk";
      pool = "persistent";
      source = "opencode-workspace";
      path = "/srv/workspace";
    };
  };
in
{
  description = "OpenCode headless web server";

  autostart = true;

  limits = {
    memory = "4GiB";
    cpu = "2";
  };

  volumes = [
    {
      pool = "persistent";
      name = "opencode-home";
      description = "OpenCode config, sessions and caches";
    }
    {
      pool = "persistent";
      name = "opencode-workspace";
      description = "Git checkouts and uncommitted work";
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  renderedSecrets = [
    {
      file = "opencode-server-env";
      env = "OPENCODE_SERVER_PASSWORD";
      source = "/run/secrets/opencode_server_password";
    }
    {
      file = "opencode-openrouter-env";
      env = "OPENROUTER_API_KEY";
      source = "/run/secrets/opencode_openrouter_api_key";
    }
    {
      format = "raw";
      file = "forgejo-token";
      source = "/run/secrets/opencode_forgejo_token";
      mode = "0440";
      group = "opencode";
    }
  ];

  secretConsumers = [ "opencode.service" ];

  devices = devices;
}
