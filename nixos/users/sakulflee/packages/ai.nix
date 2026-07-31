{ pkgs, inputs, ... }: {
  home.packages = with pkgs; [
    (pkgs.lmstudio)
    opencode
    opencode-desktop
    cursor-cli
    claude-code

    # Forces Vulkan
    (inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan)

    # pi-coding-agent with NodeJS
    ((symlinkJoin {
      name = "pi-coding-agent-with-nodejs";
      paths = [ pkgs.pi-coding-agent ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/pi \
          --prefix PATH : ${lib.makeBinPath [ nodejs ]}
      '';
    }) // {
      meta = (pkgs.pi-coding-agent.meta or {}) // {
        mainProgram = "pi";
      };
    })
  ];
}
