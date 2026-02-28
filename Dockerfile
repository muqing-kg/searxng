# syntax=docker/dockerfile:1

# 基于官方 SearXNG 构建流程，保留本地修改
ARG CONTAINER_IMAGE_ORGANIZATION="searxng"
ARG CONTAINER_IMAGE_NAME="searxng"

# ============================================
# Stage 1: Builder - 构建 Python 环境
# ============================================
FROM ghcr.io/searxng/base:searxng-builder AS builder

WORKDIR /usr/local/searxng

COPY ./requirements.txt ./requirements-server.txt ./

ENV UV_NO_MANAGED_PYTHON="true"
ENV UV_NATIVE_TLS="true"

ARG TIMESTAMP_VENV="0"

RUN --mount=type=cache,id=uv,target=/root/.cache/uv set -eux -o pipefail; \
    export SOURCE_DATE_EPOCH="${TIMESTAMP_VENV:-$(date +%s)}"; \
    uv venv; \
    uv pip install --requirements ./requirements.txt --requirements ./requirements-server.txt; \
    uv cache prune --ci; \
    find ./.venv/lib/ -type f -exec strip --strip-unneeded {} + || true; \
    find ./.venv/lib/ -type d -name "__pycache__" -exec rm -rf {} +; \
    find ./.venv/lib/ -type f -name "*.pyc" -delete; \
    python -m compileall -q -f -j 0 --invalidation-mode=unchecked-hash ./.venv/lib/; \
    find ./.venv/lib/python*/site-packages/*.dist-info/ -type f -name "RECORD" -exec sort -t, -k1,1 -o {} {} \;; \
    find ./.venv/ -exec touch -h --date="@${SOURCE_DATE_EPOCH}" {} +

# 复制源代码（包含本地修改）
COPY ./searx/ ./searx/

ARG TIMESTAMP_SETTINGS="0"

RUN set -eux -o pipefail; \
    python -m compileall -q -f -j 0 --invalidation-mode=unchecked-hash ./searx/; \
    find ./searx/static/ -type f \
    \( -name "*.html" -o -name "*.css" -o -name "*.js" -o -name "*.svg" \) \
    -exec gzip -9 -k {} + \
    -exec brotli -9 -k {} + \
    -exec gzip --test {}.gz + \
    -exec brotli --test {}.br +; \
    touch -c --date="@${TIMESTAMP_SETTINGS:-$(date +%s)}" ./searx/settings.yml

# ============================================
# Stage 2: Distribution - 最终镜像
# ============================================
FROM ghcr.io/searxng/base:searxng AS dist

WORKDIR /usr/local/searxng

# 从 builder 复制构建产物
COPY --chown=977:977 --from=builder /usr/local/searxng/.venv/ ./.venv/
COPY --chown=977:977 --from=builder /usr/local/searxng/searx/ ./searx/
COPY --chown=977:977 ./container/entrypoint.sh ./entrypoint.sh

# 确保 entrypoint 可执行
RUN chmod +x ./entrypoint.sh

# 构建参数
ARG SEARXNG_GIT_VERSION="unknown"
ARG LABEL_DATE="unknown"
ARG CREATED
ARG VERSION
ARG VCS_URL
ARG VCS_REVISION

# 设置标签
LABEL org.opencontainers.image.created="${CREATED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
      org.opencontainers.image.description="SearXNG (Custom Build) - A privacy-respecting metasearch engine" \
      org.opencontainers.image.documentation="https://docs.searxng.org/admin/installation-docker" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.revision="${VCS_REVISION:-$SEARXNG_GIT_VERSION}" \
      org.opencontainers.image.source="${VCS_URL:-https://github.com/muqing-kg/searxng}" \
      org.opencontainers.image.title="SearXNG Custom" \
      org.opencontainers.image.url="https://searxng.org" \
      org.opencontainers.image.version="${VERSION:-$LABEL_DATE}" \
      maintainer="muqing-kg"

# 环境变量
ENV SEARXNG_VERSION="${VERSION:-$LABEL_DATE}" \
    SEARXNG_SETTINGS_PATH="$CONFIG_PATH/settings.yml" \
    GRANIAN_PROCESS_NAME="searxng" \
    GRANIAN_INTERFACE="wsgi" \
    GRANIAN_HOST="::" \
    GRANIAN_PORT="8080" \
    GRANIAN_WEBSOCKETS="false" \
    GRANIAN_BLOCKING_THREADS="4" \
    GRANIAN_WORKERS_KILL_TIMEOUT="30s" \
    GRANIAN_BLOCKING_THREADS_IDLE_TIMEOUT="5m"

# 数据卷
VOLUME $CONFIG_PATH
VOLUME $DATA_PATH

# 暴露端口
EXPOSE 8080

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost:8080/healthz || exit 1

# 入口点
ENTRYPOINT ["/usr/local/searxng/entrypoint.sh"]
