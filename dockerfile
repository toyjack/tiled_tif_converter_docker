FROM alpine:latest

# 安装 libvips 和依赖
RUN apk update && \
    apk add --no-cache \
    vips-dev \
    vips-tools \
    imagemagick \
    parallel \
    bash \
    pv

# 设置工作目录
WORKDIR /app

# 复制处理脚本（确保脚本存在）
COPY process_images.sh /app/process_images.sh
RUN chmod +x /app/process_images.sh

ENTRYPOINT ["/app/process_images.sh"]