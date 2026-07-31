{ ... }: {
    services.open-webui = {
        enable = true;
        port = 30002;
        openFirewall = false;
        environment = {
            OLLAMA_API_BASE_URL = "http://127.0.0.1:30001";
        };
    };
}
