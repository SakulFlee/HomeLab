# Ollama with the Mesa Vulkan ICD for the host's AMD iGPU.
#
# The official image ships libvulkan1 and Ollama's Vulkan backend, but not the
# vendor ICD: without mesa-vulkan-drivers, Vulkan only sees llvmpipe (CPU) and
# Ollama falls back to CPU. RADV is what exposes the Radeon iGPU.
#
# vulkan-tools is only for debugging; `vulkaninfo --summary` inside the
# container should name the AMD device when the ICD is working.
FROM ollama/ollama:0.40.18

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libdrm-amdgpu1 \
        mesa-vulkan-drivers \
        vulkan-tools \
    && rm -rf /var/lib/apt/lists/*
