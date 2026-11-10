# 多阶段构建，使用固定版本标签
FROM alpine:3.22 AS base

# 设置标签信息
LABEL maintainer="libvips-docker" \
      version="1.0.0" \
      description="High-performance TIFF image processing with libvips"

# 安装运行时依赖
RUN apk add --no-cache \
    vips=8.16.1-r0 \
    vips-tools=8.16.1-r0 \
    parallel \
    bash \
    python3 \
    findutils \
    pv \
    tini \
    && rm -rf /var/cache/apk/* \
    && rm -rf /tmp/*

# Create the runtime user before COPY --chown and prepare writable directories.
RUN addgroup -S -g 1000 vipsuser \
    && adduser -S -D -u 1000 -G vipsuser vipsuser \
    && mkdir -p /app/input /app/output /app/logs /app/cache /app/tmp \
    && chown -R vipsuser:vipsuser /app

# 设置工作目录
WORKDIR /app

# 复制处理脚本并设置权限
COPY --chown=vipsuser:vipsuser process_images.sh /app/
COPY --chown=vipsuser:vipsuser scan_completed_images.py /app/
RUN chmod +x /app/process_images.sh

# 设置环境变量
ENV INPUT_DIR=/app/input \
    OUTPUT_DIR=/app/output \
    THREADS=4

# USER vipsuser:vipsuser

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD pgrep -f "process_images.sh" > /dev/null || exit 1

# 使用 tini 作为 init 进程
ENTRYPOINT ["/sbin/tini", "--", "/app/process_images.sh"]
