# unsloth-studio-wrapper
 
A thin Docker wrapper around [`unsloth/unsloth`](https://github.com/unslothai/unsloth) that fixes data persistence for Unsloth Studio. Tested on Unraid 7.x.
 
## The problem
 
The official `unsloth/unsloth` image mixes build-time artifacts and runtime data under the same directory trees. Mounting any of those paths as a Docker volume overwrites the baked-in Python venvs and llama.cpp binaries, breaking Studio on startup. Additionally, supervisord does not inherit the parent process environment, so cache path variables set via `-e` flags are invisible to Studio — causing it to fall back to hardcoded paths that may not be writable. See [issue #4396](https://github.com/unslothai/unsloth/issues/4396).
 
## What this image does
 
1. **Redirects all runtime-writable paths into `/data`** via symlinks created at container startup, before Studio launches. `/data` is safe to volume-mount — nothing in it is a build-time artifact.
2. **Patches the supervisord config at build time** to explicitly pass `HF_HOME`, `TRANSFORMERS_CACHE`, `HF_DATASETS_CACHE`, and `TORCH_HOME` to the Studio and Jupyter processes, since supervisord isolates each child's environment.
3. **Fixes ownership at runtime** — when a host directory is mounted over `/data`, Docker replaces the container's directory ownership with the host's. The entrypoint runs `chown -R 1001:1001 /data` before handing off to supervisord so the `unsloth` user can always write there.
 
## Directory layout
 
Everything Studio and Jupyter write at runtime ends up under `/data`:
 
```
/data/
├── cache/
│   ├── huggingface/   # Model weights (Studio + Jupyter unified)
│   ├── datasets/      # HuggingFace datasets cache
│   └── torch/         # PyTorch hub cache
├── studio/
│   ├── cache/         # Studio's internal model cache
│   ├── outputs/       # Trained LoRA / full model outputs
│   ├── exports/       # Exported models (GGUF, merged, etc.)
│   ├── auth/          # Studio login credentials
│   ├── runs/          # Training run history
│   └── assets/        # Studio assets
└── work/              # Jupyter workspace files
```
 
## Build
 
```bash
git clone https://github.com/Cyberschorsch/unsloth-studio-wrapper
cd unsloth-studio-wrapper
docker build -t unsloth-studio-wrapper .
```
 
When Unsloth releases a new version, rebuild with `--no-cache` to pick up the latest base image:
 
```bash
docker pull unsloth/unsloth:latest
docker build --no-cache -t unsloth-studio-wrapper .
```
 
All data in `/data` survives the rebuild.
 
## Usage
 
### Docker Compose
 
```yaml
services:
  unsloth:
    image: unsloth-studio-wrapper
    build: .
    container_name: unsloth-studio
    restart: unless-stopped
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              capabilities: [gpu]
    environment:
      - JUPYTER_PASSWORD=changeme
    ports:
      - "8000:8000"   # Unsloth Studio UI
      - "8888:8888"   # Jupyter
    volumes:
      - ./data:/data
```
 
### Docker run
 
```bash
docker run -d \
  --name unsloth-studio \
  --restart unless-stopped \
  -e JUPYTER_PASSWORD=changeme \
  -p 8000:8000 \
  -p 8888:8888 \
  -v $(pwd)/data:/data \
  --gpus all \
  unsloth-studio-wrapper
```
 
## Unraid setup
 
Build the image on your Unraid server via SSH:
 
```bash
cd /mnt/cache/appdata/unsloth-studio-wrapper
docker build -t unsloth-studio-wrapper .
```
 
Then add the container via the Unraid Docker UI (Advanced View) with these path mappings:
 
| Container path | Host path | Mode |
|---|---|---|
| `/data` | `/mnt/cache/appdata/unsloth/data` | Read/Write |
 
Or mount subdirectories individually for finer control:
 
| Container path | Host path | Mode |
|---|---|---|
| `/data/cache` | `/mnt/cache/appdata/unsloth/cache` | Read/Write |
| `/data/studio` | `/mnt/cache/appdata/unsloth/studio` | Read/Write |
| `/data/work` | `/mnt/cache/appdata/unsloth/work` | Read/Write |
 
**Use `/mnt/cache/appdata/` rather than `/mnt/user/appdata/`** to bypass Unraid's FUSE/mergerfs layer. Model files are large and read/written heavily during training — the direct SSD cache pool path gives noticeably better I/O performance.
 
**No environment variables need to be set in the Unraid template.** All cache paths are configured inside the image.
 
## Environment variables
 
These are baked into the image and do not need to be set manually:
 
| Variable | Value |
|---|---|
| `HF_HOME` | `/data/cache/huggingface` |
| `TRANSFORMERS_CACHE` | `/data/cache/huggingface` |
| `HF_DATASETS_CACHE` | `/data/cache/datasets` |
| `TORCH_HOME` | `/data/cache/torch` |
| `UNSLOTH_DATA_DIR` | `/data` |
 
The only variable you may want to set is `JUPYTER_PASSWORD`.
 
## Notes
 
- SSH (`port 22`) is disabled by default in this setup — the base image's sshd fails without an `SSH_KEY` env var, and supervisord gives up after a few retries. This is harmless; Studio and Jupyter are unaffected.
- The symlink approach depends on the base image not radically changing its internal paths between releases. If a future Unsloth update moves things around, `entrypoint.sh` may need updating.
- This wrapper will become unnecessary if Unsloth officially fixes path separation upstream ([issue #4396](https://github.com/unslothai/unsloth/issues/4396)).
