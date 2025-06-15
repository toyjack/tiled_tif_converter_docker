#!/bin/bash

# 脚本配置
readonly INPUT_DIR="/app/input"
readonly OUTPUT_DIR="/app/output"
readonly THREADS=${THREADS:-4}
readonly LOCAL_CACHE_DIR="/tmp/cache"
readonly BATCH_SIZE=${BATCH_SIZE:-10}  # 每批处理的文件数量
readonly USE_LOCAL_CACHE=${USE_LOCAL_CACHE:-true}  # 是否启用本地缓存

# 更严格的错误处理
# -E: 如果 trap 使用 ERR，则继承 ERR
# -u: 未定义变量视为错误
# -o pipefail: 管道中任一命令失败则整个管道失败
set -Eeuo pipefail

# 脚本退出时调用的清理函数
trap 'cleanup' EXIT
cleanup() {
  # 可在此处添加需要清理的逻辑，例如删除临时文件
  # log "脚本执行完毕，正在清理..."
  : # 空命令，什么都不做
}

# 日志函数
log() {
  echo >&2 "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 获取并验证线程数
get_thread_count() {
  local requested_threads="$1"
  local cpu_cores
  cpu_cores=$(nproc)

  if [[ "$requested_threads" == "auto" ]]; then
    requested_threads=$cpu_cores
  elif ! [[ "$requested_threads" =~ ^[0-9]+$ ]]; then
    log "错误: 线程数必须是一个正整数。"
    exit 1
  fi

  # 限制最大线程数为 CPU 核心数的 2 倍
  local max_threads=$((cpu_cores * 2))
  if [[ "$requested_threads" -gt $max_threads ]]; then
    log "警告: 请求的线程数 ($requested_threads) 超过推荐最大值 ($max_threads)，将使用最大值。"
    requested_threads=$max_threads
  fi

  if [[ "$requested_threads" -lt 1 ]]; then
    requested_threads=1
  fi

  echo "$requested_threads"
}

# 本地缓存处理单个文件
process_single_file_cached() {
  local input_file="$1"
  local filename
  filename=$(basename "$input_file")
  local relative_dir
  relative_dir=$(dirname "${input_file#$INPUT_DIR/}")

  # 构建输出路径
  local output_dir="$OUTPUT_DIR/$relative_dir"
  local output_file="$output_dir/${filename%.*}.tif"

  # 跳过已存在的文件
  if [[ -f "$output_file" ]]; then
    return 0
  fi

  # 确保输出目录存在
  mkdir -p "$output_dir"

  # 本地缓存路径
  local cache_input="$LOCAL_CACHE_DIR/input/$filename"
  local cache_output="$LOCAL_CACHE_DIR/output/${filename%.*}.tif"
  
  # 创建缓存目录
  mkdir -p "$LOCAL_CACHE_DIR/input" "$LOCAL_CACHE_DIR/output"

  # 复制到本地缓存
  if ! cp "$input_file" "$cache_input" 2>/dev/null; then
    log "✗ 复制到缓存失败: $input_file"
    return 1
  fi

  # 本地处理
  if vips im_vips2tiff "$cache_input" "$cache_output:deflate,tile:256x256,pyramid" >/dev/null 2>&1; then
    # 复制回NFS
    if cp "$cache_output" "$output_file" 2>/dev/null; then
      # 清理本地缓存
      rm -f "$cache_input" "$cache_output"
      return 0
    else
      log "✗ 复制回NFS失败: $input_file"
      rm -f "$cache_input" "$cache_output" "$output_file"
      return 1
    fi
  else
    log "✗ 转换失败: $input_file"
    rm -f "$cache_input" "$cache_output" "$output_file"
    return 1
  fi
}

# 直接处理单个文件（无缓存）
process_single_file_direct() {
  local input_file="$1"
  local filename
  filename=$(basename "$input_file")
  local relative_dir
  relative_dir=$(dirname "${input_file#$INPUT_DIR/}")

  # 构建输出路径
  local output_dir="$OUTPUT_DIR/$relative_dir"
  local output_file="$output_dir/${filename%.*}.tif"

  # 跳过已存在的文件
  if [[ -f "$output_file" ]]; then
    return 0
  fi

  # 确保输出目录存在
  mkdir -p "$output_dir"

  # 执行转换
  if vips im_vips2tiff "$input_file" "$output_file:deflate,tile:256x256,pyramid" >/dev/null; then
    return 0
  else
    log "✗ 转换失败: $input_file"
    rm -f "$output_file"
    return 1
  fi
}

# 单个文件处理函数 (已简化)
process_single_file() {
  local input_file="$1"
  # 使用 basename 和 dirname 提高可读性和稳健性
  local filename
  filename=$(basename "$input_file")
  local relative_dir
  relative_dir=$(dirname "${input_file#$INPUT_DIR/}")

  # 构建输出路径
  local output_dir="$OUTPUT_DIR/$relative_dir"
  local output_file="$output_dir/${filename%.*}.tif"

  # ✅ 核心优化：在任务内部检查文件是否存在，而不是预先计算
  if [[ -f "$output_file" ]]; then
    # GNU Parallel 的 --joblog 会记录此信息，无需手动打印日志
    # echo "SKIP: $input_file"
    return 0 # 返回成功状态码，表示“已处理”
  fi

  # 确保输出目录存在
  mkdir -p "$output_dir"

  # 执行转换，隐藏 vips 的标准输出，但保留标准错误用于调试
  if vips im_vips2tiff "$input_file" "$output_file:deflate,tile:256x256,pyramid" >/dev/null; then
    # 成功，无需日志，joblog会记录
    return 0
  else
    # 失败，记录错误并清理
    log "✗ 转换失败: $input_file"
    rm -f "$output_file"
    return 1 # 返回失败状态码
  fi
}

# 包装函数，根据配置选择处理方式
process_file_wrapper() {
  if [[ "$USE_LOCAL_CACHE" == "true" ]]; then
    process_single_file_cached "$@"
  else
    process_single_file "$@"
  fi
}

# 导出函数和只读变量给 parallel 使用
export -f process_file_wrapper process_single_file_cached process_single_file_direct process_single_file log
export INPUT_DIR OUTPUT_DIR LOCAL_CACHE_DIR USE_LOCAL_CACHE

# 主函数
main() {
  local thread_count_req="$THREADS"
  local thread_count
  thread_count=$(get_thread_count "$thread_count_req")

  # 检查输入目录
  if [[ ! -d "$INPUT_DIR" ]]; then
    log "错误: 输入目录不存在: $INPUT_DIR"
    exit 1
  fi

  # 创建输出目录
  mkdir -p "$OUTPUT_DIR"

  log "正在查找 TIFF 文件..."
  # ✅ 核心优化：使用 NUL 分隔符处理特殊文件名
  # 将文件列表读入数组，避免多次调用 find
  mapfile -d '' files_to_process < <(find "$INPUT_DIR" -type f \( -iname "*.tif" -o -iname "*.tiff" \) -print0)

  local total_files=${#files_to_process[@]}

  if [[ "$total_files" -eq 0 ]]; then
    log "在 $INPUT_DIR 中未找到 TIFF 文件，任务完成。"
    exit 0
  fi

  # 初始化本地缓存
  if [[ "$USE_LOCAL_CACHE" == "true" ]]; then
    log "启用本地缓存模式，缓存目录: $LOCAL_CACHE_DIR"
    mkdir -p "$LOCAL_CACHE_DIR/input" "$LOCAL_CACHE_DIR/output"
    # 清理旧缓存
    rm -rf "$LOCAL_CACHE_DIR"/*
    mkdir -p "$LOCAL_CACHE_DIR/input" "$LOCAL_CACHE_DIR/output"
  fi

  log "找到 $total_files 个文件。开始使用 $thread_count 个线程进行处理..."
  log "可以使用 'tail -f /tmp/tiff_conversion.log' 查看详细任务日志。"

  # ✅ 核心优化：使用 parallel 的内置功能
  # --bar: 显示进度条
  # --eta: 显示预计剩余时间
  # --joblog: 将每个任务的详细信息（开始/结束时间、退出码、标准输出/错误）记录到文件
  # --null: 表示输入由 NUL (\0) 字符分隔
  # printf "%s\0" ... | parallel: 安全地将数组内容通过管道传递给 parallel
  if printf "%s\0" "${files_to_process[@]}" | \
    parallel \
      --null \
      --bar \
      --eta \
      -j "$thread_count" \
      --joblog /tmp/tiff_conversion.log \
      process_file_wrapper {}; then
    log "✅ 所有文件处理成功。"
  else
    log "⚠️ 部分文件处理失败。请检查日志 /tmp/tiff_conversion.log 获取详情。"
    exit 1
  fi
}

# 执行主函数，并传递所有命令行参数
main "$@"