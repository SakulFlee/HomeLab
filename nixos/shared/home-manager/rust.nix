{ pkgs, inputs, ... }:
let
  fenix = inputs.fenix.packages.${pkgs.stdenv.hostPlatform.system};

  rust-toolchain = with fenix; combine [
    latest.toolchain
    stable.toolchain
  ];

  cargo-nightly = pkgs.writeShellScriptBin "cargo-nightly" ''
    exec ${fenix.latest.toolchain}/bin/cargo "$@"
  '';

  rustc-nightly = pkgs.writeShellScriptBin "rustc-nightly" ''
    exec ${fenix.latest.toolchain}/bin/rustc "$@"
  '';
in {
  home.packages = [
    rust-toolchain
    cargo-nightly
    rustc-nightly
    pkgs.cargo-flamegraph
    pkgs.cargo-criterion
  ];
}
