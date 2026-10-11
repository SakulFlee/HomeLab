# Incus-level definition of the "renovate" instance.
#
# See ../cloudflare-ddns/incus.nix for the closest sibling: that one replaced a
# k3s CronJob with a single-purpose daemon on its own instance, and this is the
# same shape again. Briefly: this file is the container, default.nix is the
# software in it.
#
# A container rather than a VM, which was the open question for the previous two
# migrations and is settled here by what Renovate is. Every manager it drives --
# gradle, maven, cargo, go, node, python -- is a userspace toolchain that
# Renovate execs directly rather than pulling a sidecar image for, so there is
# no kernel of its own to want, no /dev passthrough and no Docker daemon that
# would have forced a privileged guest. (Forgejo Actions runs Docker inside its
# guest and is a VM for exactly this reason; see ../forgejo-runner/incus.nix.)
let
  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address. The profile
    # supplies type/name/network, so the instance still gets a veth on incusbr0
    # with NAT egress.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.54";
    };
  };
in
{
  description = "Renovate dependency updater";

  # Start on boot. Renovate that only runs when someone remembers to start it is
  # a dependency updater that quietly stops updating dependencies, which is the
  # failure mode nobody notices until a CVE lands.
  autostart = true;

  # 2GiB / 2 CPU, well above what the k3s CronJob ever got.
  #
  # The pod it replaces had no requests and no limits at all, so it borrowed
  # whatever the node had spare -- which is a number nobody ever wrote down and
  # cannot now recover. This is a deliberate over-provision instead of a guess:
  # Renovate is idle between runs and its peak is a single-threaded Node process
  # plus, at the busiest moment of a run, one language toolchain at a time
  # (a gradle daemon, a cargo build). Two cores because a run that compiles
  # something and another that does not should not serialise against each other,
  # and 2GiB because that peak -- a JDK alone is ~300MiB of resident heap before
  # it does anything, and cargo/npm caches are not small -- is the case worth
  # surviving rather than the average, which is near zero.
  limits = {
    memory = "2GiB";
    cpu = "2";
  };

  devices = devices;

  # No volumes, and no snapshot policy either. Nothing authoritative lives on
  # this instance's disk: the state that matters is in Forgejo (branches, PRs)
  # and in the repository itself (renovate.json). Everything Renovate writes
  # locally is a cache -- cloned repos under baseDir, package-manager caches --
  # and losing all of it costs the next run some time, not correctness. A
  # recreate therefore loses nothing worth backing up, which is the standard
  # ../syncthing/NOTES.md sets out and the reason nothing is mounted here.

  # No networkForward, for the same reason as the instances above: Renovate only
  # ever dials out to Forgejo and to package registries. Nothing should be able
  # to dial in, so a forward would be the only way to give it an attack surface.

  # The two tokens, in the k3s deployment's own values (apps/renovate/secrets/
  # secret.enc.yaml) -- RENOVATE_TOKEN is the Forgejo bot token Renovate
  # authenticates with, RENOVATE_GITHUB_COM_TOKEN lets it read github.com
  # changelogs and release notes that a Forgejo mirror does not carry.
  #
  # Declared on the host rather than in this instance, for the reason
  # nixos/modules/sops.nix gives for every other rendered secret: the instance
  # gets the rendered bytes and no decryption capability, so a root process here
  # cannot read the restic password, the Forgejo secrets or the PIA credentials
  # out of the host's secrets.yaml.
  #
  # format = "raw" for both. A token is a value to be read, not a KEY=value
  # line: `env` would wrap each in RENOVATE_TOKEN=..., and these are consumed by
  # services.renovate.credentials, which hands each path to systemd as
  # LoadCredential and reads it back with systemd-creds -- not by an
  # EnvironmentFile parser. 0400 root:root, apply.sh's default, is correct for
  # that: systemd opens the credential as root before the unit drops to the
  # renovate user, and renovate itself only ever sees it in $CREDENTIALS_DIRECTORY.
  renderedSecrets = [
    {
      format = "raw";
      file = "renovate-token";
      source = "/run/secrets/renovate_token";
    }
    {
      format = "raw";
      file = "renovate-github-com-token";
      source = "/run/secrets/renovate_github_com_token";
    }
  ];

  # The unit that reads the files above.
  #
  # Not optional in practice, and the same situation as cloudflare-ddns: on a
  # first deploy renovate.service cannot start at all, because systemd fails the
  # unit outright when a LoadCredential source is missing rather than starting it
  # without the credential. apply.sh writes the files and then restarts this,
  # which is why it restarts unconditionally (after `systemctl reset-failed`)
  # instead of using try-restart -- a try-restart on a unit that has never
  # started is a no-op and the token would never be picked up.
  #
  # That restart is also a free smoke test: it is a real Renovate run against
  # real credentials, so a bad token fails here rather than at the next
  # scheduled sweep.
  secretConsumers = [ "renovate.service" ];
}