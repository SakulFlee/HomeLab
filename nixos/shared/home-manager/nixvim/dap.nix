{ pkgs, ... }: {
  programs.nixvim = {
    plugins.dap = {
      enable = true;
      adapters = {
        executables.codelldb = {
          command = "${pkgs.vscode-extensions.vadimcn.vscode-lldb.adapter}/bin/codelldb";
          args    = [ "--port" "13000" ];
        };
      };
      configurations = {
        rust = [
          {
            type          = "codelldb";
            request       = "launch";
            name          = "Launch";
            cwd           = ''''${workspaceFolder}'';
            program.__raw = ''
              function()
                return vim.fn.input(
                  "Path: ",
                  vim.fn.getcwd() .. "/",
                  "file"
                )
              end
            '';
            args.__raw = ''
              function()
                local args = {}
                for _, arg in ipairs(vim.fn.input("Args: "):gmatch("%S+")) do
                  table.insert(args, arg)
                end
                return args
              end
            '';
            runInTerminal = true;
          }
        ];
      };
    };
    plugins.dap-ui.enable           = true;
    plugins.dap-virtual-text.enable = true;
  };
}
