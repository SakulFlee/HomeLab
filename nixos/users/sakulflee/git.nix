{ pkgs, ... }: {
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "@SakulFlee | Lukas Weber";
        email = "dev@sakul-flee.de";
        signingKey = "0A96C9AA72DB019DE171E7F77F0C6AF1F56A9E05";
      };
      commit.gpgsign = true;
      init.defaultBranch = "main";
      pull.rebase = true;
      credential.helper = "store";

      # Fetch other AGIT branches
      remote.origin.fetch = "+refs/pull/*/head:refs/remotes/origin/pr/*";
    };
  };
}
