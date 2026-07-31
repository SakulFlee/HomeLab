{ ... }: {
  programs.nixvim = {
    lsp = {
      servers = {
        ts_ls.enable = true;
        html.enable = true;
        cssls.enable = true;
        yamlls.enable = true;
        jsonls.enable = true;
        bashls.enable = true;
        pyright.enable = true;
        nil_ls.enable = true;
      };
    };
  };
}
