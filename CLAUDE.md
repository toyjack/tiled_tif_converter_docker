# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

这是一个基于 Docker 的 libvips 图像处理项目，用于批量将 TIFF 图像转换为压缩的金字塔 TIFF 格式。该项目使用 Alpine Linux 作为基础镜像，集成了 libvips、ImageMagick 和 GNU Parallel 来实现高效的并行图像处理。

## 架构结构

- **容器化架构**: 使用 Docker 容器化部署，通过 Docker Compose 管理
- **输入/输出分离**: 使用卷挂载分离输入和输出目录
- **并行处理**: 使用 GNU Parallel 实现多线程并行处理
- **错误处理**: 实现了严格的错误处理和日志记录机制

## 核心组件

### 1. Docker 配置
- `dockerfile`: 基于 Alpine Linux，安装 libvips、vips-tools、imagemagick、parallel 等工具
- `docker-compose.yaml`: 定义服务配置和环境变量

### 2. 图像处理脚本
- `process_images.sh`: 主要的图像处理脚本，包含：
  - 线程数管理和验证
  - 递归文件查找和处理
  - 错误处理和日志记录
  - 进度条和ETA显示

### 3. 目录结构
- `input/`: 输入图像文件目录（通过卷挂载）
- `output/`: 输出图像文件目录（通过卷挂载）

## 常用命令

### 构建和运行
```bash
# 构建镜像
docker-compose build

# 运行图像处理（使用默认配置）
docker-compose up

# 使用自定义线程数
DEFAULT_THREADS=8 docker-compose up

# 设置输入输出目录
INPUT_FOLDER=/path/to/input OUTPUT_FOLDER=/path/to/output docker-compose up
```

### 环境变量配置
- `DEFAULT_THREADS`: 默认线程数（默认: 4）
- `MAX_THREADS`: 最大线程数限制（默认: 16）
- `INPUT_FOLDER`: 输入目录路径（默认: ./input）
- `OUTPUT_FOLDER`: 输出目录路径（默认: ./output）

### 监控和调试
```bash
# 查看处理日志
docker exec -it container_name tail -f /tmp/tiff_conversion.log

# 进入容器调试
docker exec -it container_name /bin/bash
```

## 图像处理详情

### 转换参数
- 输入格式: TIFF (.tif, .tiff)
- 输出格式: 压缩的金字塔 TIFF
- 压缩方式: deflate 压缩
- 瓦片大小: 256x256
- 金字塔结构: 启用多级金字塔

### vips 命令
```bash
vips im_vips2tiff input.tif output.tif:deflate,tile:256x256,pyramid
```

## 错误处理机制

脚本实现了严格的错误处理：
- 使用 `set -Eeuo pipefail` 确保任何错误都会导致脚本退出
- 跳过已存在的输出文件
- 失败时清理不完整的输出文件
- 详细的日志记录和作业日志

## 性能特性

- 自动检测 CPU 核心数
- 可配置的线程数（带最大限制）
- 内存高效的文件处理
- 进度条和ETA显示
- 跳过已处理的文件避免重复工作

## 项目文件结构

### 核心文件
- `dockerfile`: Alpine Linux 3.22 基础镜像，固定版本 libvips 8.16.1、vips-tools、parallel 等
- `docker-compose.yaml`: 服务配置，包含资源限制、安全配置和健康检查
- `process_images.sh`: 主处理脚本，支持缓存模式和直接模式，包含严格错误处理
- `prd.md`: 完整的产品需求文档，包含技术规格和业务需求

### 目录结构
- `input/`: 输入 TIFF 文件目录（通过卷挂载，只读）
- `output/`: 转换后的输出文件目录
- `logs/`: 处理日志文件目录

## 重要配置更新

### 实际环境变量配置
基于当前 docker-compose.yaml 的实际配置：

**目录挂载配置**:
- `INPUT_FOLDER`: 输入目录路径（默认: ./input）
- `OUTPUT_FOLDER`: 输出目录路径（默认: ./output）
- `LOG_FOLDER`: 日志目录路径（默认: ./logs）

**处理配置**:
- `THREADS`: 处理线程数（默认: 4）
- `USE_LOCAL_CACHE`: 启用本地缓存模式（默认: true）
- `LOG_LEVEL`: 日志级别（默认: INFO）
- `TZ`: 时区设置（默认: UTC）

**资源限制配置**:
- `MEMORY_LIMIT`: 内存限制（默认: 2G）
- `CPU_LIMIT`: CPU 限制（默认: 6.0）

**配置文件**: 
所有环境变量都可以在 `.env.example` 文件中找到完整说明和配置示例。

### 处理模式选择
脚本支持两种处理模式，通过 `USE_LOCAL_CACHE` 环境变量控制：

1. **本地缓存模式** (`USE_LOCAL_CACHE=true`): 
   - 适用于 NFS 环境优化
   - 先复制到本地缓存 `/tmp/cache` 处理，再复制回 NFS
   - 减少网络 I/O，提高性能

2. **直接模式** (`USE_LOCAL_CACHE=false`):
   - 适用于本地存储环境
   - 直接在目标位置处理文件
   - 节省磁盘空间和复制时间

## 脚本核心特性

### 错误处理机制
- 使用 `set -Eeuo pipefail` 严格错误处理
- 原子文件操作，使用临时文件确保数据完整性
- 失败时自动清理不完整的文件
- 支持断点续传，跳过已存在的输出文件

### 安全配置
- 容器以非 root 用户 `vipsuser` 运行
- 使用 `no-new-privileges:true` 安全选项
- tmpfs 挂载 `/tmp` 目录，防止敏感数据泄露
- 资源限制防止系统过载

## 调试和故障排除

### 常用调试命令
```bash
# 查看容器状态
docker-compose ps

# 查看实时日志
docker-compose logs -f

# 进入容器调试
docker exec -it libvips-processor /bin/bash

# 查看详细处理日志
docker exec -it libvips-processor tail -f /tmp/logs/tiff_conversion.log

# 检查处理进度
docker exec -it libvips-processor ps aux | grep parallel
```

### 性能调优
```bash
# 根据 CPU 核数调整线程
THREADS=$(nproc) docker-compose up

# 大内存环境优化
MEMORY_LIMIT=8G THREADS=16 docker-compose up

# NFS 环境优化（启用缓存）
USE_LOCAL_CACHE=true docker-compose up
```

# important-instruction-reminders
Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.