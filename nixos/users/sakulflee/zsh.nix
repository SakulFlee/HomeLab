{ pkgs, lib, ... }: {
  imports = [ ../../shared/home-manager/zsh.nix ];

  programs.zsh = {
    shellAliases = {
      s = "stream";
      v = "video";
      ve = "video_exit";
      m = "music";
      lg = "lazygit";
      q = "qwen";
      n = "nvim";
      w = "workspace";
      clms = "claude_lmstudio";
    };

    initContent = lib.mkMerge [
      ''
        if [ -n "$SSH_AUTH_SOCK" ]; then
          :
        else
          eval "$(ssh-agent >/dev/null 2>&1)"
        fi

        export PATH="$PATH:$HOME/.local/bin:/opt/miniconda3/bin:$HOME/.cargo/bin:$HOME/.lmstudio/bin"
      ''

      (lib.mkOrder 1150 ''
        stream() {
          local url="$1"
          local output_template="%(title)s.%(ext)s"
          local max_retries=10
          local retry_delay=5
          local retry_count=0

          while [[ $retry_count -lt $max_retries ]]; do
            echo "Starting download attempt $((retry_count + 1)) of $max_retries..."
            local start_time=$(date +%s)
            yt-dlp --cookies-from-browser brave -o "~/Videos/NSFW/Streams/$output_template" --merge-output-format mkv "$url"
            local end_time=$(date +%s)
            local execution_time=$((end_time - start_time))

            if [[ $execution_time -gt 30 ]]; then
              echo "Last execution took longer than 30s, resetting retry count."
              retry_count=0
            else
              retry_count=$((retry_count + 1))
            fi

            if [[ $retry_count -lt $max_retries ]]; then
              echo "Waiting $retry_delay seconds before retrying..."
              sleep $retry_delay
              retry_delay=$((retry_delay + 5))
            fi
          done

          if [[ $retry_count -eq $max_retries ]]; then
            echo "Max retries ($max_retries) reached. Exiting."
          else
            echo "Download completed successfully."
          fi
        }

        video() {
          local url="$1"
          local output_template="%(title)s.%(ext)s"
          echo "Starting video download..."
          yt-dlp --cookies-from-browser brave -o "~/Videos/$output_template" --merge-output-format mkv "$url"
          echo "Video download completed."
        }

        video_exit() {
          video "$1"
          exit $?
        }

        music() {
          local url="$1"
          local output_template="%(title)s.%(ext)s"
          echo "Starting audio extraction..."
          yt-dlp --cookies-from-browser brave -o "~/Music/$output_template" -x --audio-format flac --embed-metadata --embed-thumbnail "$url"
          echo "Audio extraction completed."
        }

        workspace() {
          local name="$1"
          cd "$HOME/Workspace/$name" || {
            echo "ERROR: Project '$name' not found in workspace folder!"
            return
          }
          nvim .
        }

        claude_lmstudio() {
          export ANTHROPIC_BASE_URL=http://localhost:1234
          export ANTHROPIC_AUTH_TOKEN=lmstudio
          claude --model "$1"
        }

        reencode_videos_range() {
          local range_start=$1
          local range_end=$2
          for i in $(seq "$range_start" "$range_end"); do
            echo "> $i"
            ffmpeg -i "''${i}_1.mp4" -i "''${i}_2.mp4" -vcodec copy "out_''${i}.mp4"
          done
        }
      '')
    ];
  };
}
