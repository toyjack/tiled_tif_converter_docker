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