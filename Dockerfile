FROM unsloth/unsloth:latest
 
USER root
 
RUN mkdir -p \
    /data/cache/huggingface \
    /data/cache/datasets \
    /data/cache/torch \
    /data/studio/cache \
    /data/studio/outputs \
    /data/studio/exports \
    /data/studio/auth \
    /data/studio/runs \
    /data/studio/assets \
    /data/outputs \
    /data/exports \
    /data/auth \
    /data/runs \
    /data/assets \
    /data/work \
    && chown -R 1001:1001 /data \
    && chmod -R 755 /data \
    && mkdir -p /home/unsloth/.unsloth/studio \
    && chown -R 1001:1001 /home/unsloth/.unsloth \
    && chmod -R 755 /home/unsloth/.unsloth
 
# Patch supervisord config to explicitly pass cache env vars to studio and
# jupyter processes. supervisord does NOT inherit the parent environment —
# only variables listed in each [program:x] environment= clause are passed.
# Without this, HF_HOME etc. are invisible to Studio and it falls back to
# its hardcoded default of /home/unsloth/.cache/huggingface/hub.
RUN sed -i \
    's|environment=HOME="/home/unsloth",USER="unsloth",UNSLOTH_STUDIO_HOME="/workspace/studio"|environment=HOME="/home/unsloth",USER="unsloth",UNSLOTH_STUDIO_HOME="/workspace/studio",HF_HOME="/data/cache/huggingface",TRANSFORMERS_CACHE="/data/cache/huggingface",HF_DATASETS_CACHE="/data/cache/datasets",TORCH_HOME="/data/cache/torch"|' \
    /etc/supervisor/conf.d/supervisord.conf \
    && sed -i \
    's|environment=HOME="/home/unsloth",USER="unsloth"$|environment=HOME="/home/unsloth",USER="unsloth",HF_HOME="/data/cache/huggingface",TRANSFORMERS_CACHE="/data/cache/huggingface",HF_DATASETS_CACHE="/data/cache/datasets",TORCH_HOME="/data/cache/torch"|' \
    /etc/supervisor/conf.d/supervisord.conf
 
ENV HF_HOME=/data/cache/huggingface \
    TRANSFORMERS_CACHE=/data/cache/huggingface \
    HF_DATASETS_CACHE=/data/cache/datasets \
    TORCH_HOME=/data/cache/torch \
    UNSLOTH_DATA_DIR=/data
 
COPY --chmod=755 entrypoint.sh /usr/local/bin/unsloth-entrypoint.sh
 
ENTRYPOINT ["/usr/local/bin/unsloth-entrypoint.sh"]
CMD ["supervisord", "-n", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
