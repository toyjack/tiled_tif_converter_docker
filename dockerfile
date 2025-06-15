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
    pv \
    tini \
    && rm -rf /var/cache/apk/* \
    && rm -rf /tmp/*

# 创建必要的目录
RUN mkdir -p /app/input /app/output /app/logs

# 设置工作目录
WORKDIR /app

# 复制处理脚本并设置权限
COPY --chown=vipsuser:vipsuser process_images.sh /app/
RUN chmod +x /app/process_images.sh

# 保持 root 用户以处理权限问题
# USER vipsuser

# 设置环境变量
ENV INPUT_DIR=/app/input \
    OUTPUT_DIR=/app/output \
    THREADS=4

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD pgrep -f "process_images.sh" > /dev/null || exit 1

# 使用 tini 作为 init 进程
ENTRYPOINT ["/sbin/tini", "--", "/app/process_images.sh"]