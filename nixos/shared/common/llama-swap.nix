{ pkgs, inputs, configs, lib, ... }: 
let
  llama-cpp = inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    useVulkan = true;
  };
  llama-server = lib.getExe' llama-cpp "llama-server";
in
{
  services.llama-swap = {
    enable = true;
    port = 30001;
    listenAddress = "0.0.0.0";
    settings = {
      macros = {
        "default" = ''
          ${llama-server} \
            --host 127.0.0.1 \
            --port ''${PORT} \
            -fa on \
            -c 65536
        '';
        "with_fit" = ''
          -fit on
        '';
        "with_mtp" = ''
          --spec-type draft-mtp 
        '';
      };
      models = {        
        "Ornith1.0 9B @Q4_K_M" = {
          cmd = ''
            ''${default} \
            ''${with_fit} \
              -hf deepreinforce-ai/Ornith-1.0-9B-GGUF:Q4_K_M
          '';
        };
        "[unsloth] Qwen3.5 9B @Q4_K_XL [MTP]" = {
          cmd = ''
            ''${default} \
            ''${with_mtp} \
            ''${with_fit} \
              --spec-draft-n-max 6 \
              -np 1 \
              -hf unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_XL 
          '';
        };
        "[unsloth] Qwen3.6 35B-A3B @Q4_K_XL [MTP]" = {
          cmd = ''
            ''${default} \
            ''${with_mtp} \
            ''${with_fit} \
              --spec-draft-n-max 2 \
              -np 1 \
              -hf unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_XL 
          '';
        };
        "[unsloth] Gemma4 26B-A4B @Q4_K_XL [QAT] [MTP]" = {
          cmd = ''
            ''${default} \
            ''${with_mtp} \
            ''${with_fit} \
              --spec-draft-n-max 4 \
              -hf unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL 
          '';
        };
        "Qwythos 9 @Q4_K_M [MTP]" = {
          cmd = ''
            ''${default} \
            ''${with_mtp} \
            ''${with_fit} \
              -hf empero-ai/Qwythos-9B-Claude-Mythos-5-1M-GGUF:Q4_K_M \
              -m Qwythos-9B-Claude-Mythos-5-1M-MTP-Q4_K_M.gguf
          '';
        };
        "[unsloth] Gemma4 E4B @UD-Q4_K_XL [QAT] [MTP]" = {
          cmd = ''
            ''${default} \
            ''${with_mtp} \
            ''${with_fit} \
              -hf unsloth/gemma-4-E4B-it-qat-GGUF:UD-Q4_K_XL
          '';
        };
        "[unsloth] Gemma4 12B @UD-Q4_K_XL [QAT] [MTP]" = {
          cmd = ''
            ''${default} \
            ''${with_mtp} \
            ''${with_fit} \
              -hf unsloth/gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL
          '';
        };
      };
    };
  };

  systemd.services.llama-swap.serviceConfig = {
    # Fixes /proc/meminfo error
    ProcSubset = lib.mkForce "all";

    # Fixes cache location error
    Environment = [ "HOME=/var/lib/llama-swap" ];
    StateDirectory = "llama-swap";

    # Fixes JIT cache compilation errors
    MemoryDenyWriteExecute = lib.mkForce false;
    ProtectControlGroups = lib.mkForce false;

    # GPU access for Vulkan (AMD ROCm, etc.)
    SupplementaryGroups = [ "render" "video" ];
    PrivateDevices = lib.mkForce false;
  };
}
