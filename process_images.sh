#!/bin/bash

# =================================================================
# TIFF 图像批量处理脚本
# 功能：将 TIFF 图像转换为压缩的金字塔 TIFF 格式
# 支持：本地缓存模式（NFS 优化）、并行处理、断点续传
# =================================================================

# 脚本配置
readonly INPUT_DIR="/app/input"
readonly OUTPUT_DIR="/app/output" 
readonly THREADS=${THREADS:-4}
readonly LOCAL_CACHE_DIR="/tmp/cache"
readonly USE_LOCAL_CACHE=${USE_LOCAL_CACHE:-true}

# 严格错误处理
# -E: trap ERR 信号继承到函数和子shell
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败则整个管道失败
set -Eeuo pipefail

# 设置退出时的清理函数
trap 'cleanup' EXIT

# 清理函数：清理临时文件和缓存
cleanup() {
  if [[ "${USE_LOCAL_CACHE}" == "true" && -d "${LOCAL_CACHE_DIR}" ]]; then
    find "${LOCAL_CACHE_DIR}" -mindepth 1 -delete 2>/dev/null || true
  fi
}

# 日志函数：输出带时间戳的日志到标准错误
log() {
  echo >&2 "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 获取输出文件路径
# 参数: $1 - 输入文件完整路径
# 输出: 对应的输出文件路径
get_output_path() {
  local input_file="$1"
  
  # 检查输入参数
  if [[ -z "$input_file" ]]; then
    echo "错误: get_output_path 缺少输入文件参数" >&2
    return 1
  fi
  
  local filename
  filename=$(basename "$input_file")
  
  # 计算相对路径，处理根目录情况
  local relative_path="${input_file#$INPUT_DIR}"
  # 移除开头的斜杠（如果存在）
  relative_path="${relative_path#/}"
  local relative_dir
  relative_dir=$(dirname "$relative_path")
  
  # 如果是根目录，relative_dir 为 "."
  if [[ "$relative_dir" == "." ]]; then
    echo "$OUTPUT_DIR/${filename%.*}.tif"
  else
    echo "$OUTPUT_DIR/$relative_dir/${filename%.*}.tif"
  fi
}

# 原子文件操作：安全地移动文件
# 参数: $1 - 源文件, $2 - 目标文件
# 返回: 0 成功, 1 失败
atomic_move() {
  local source="$1"
  local target="$2"
  local temp_file="$target.tmp.$$"
  
  if cp "$source" "$temp_file" 2>/dev/null && mv "$temp_file" "$target" 2>/dev/null; then
    return 0
  else
    rm -f "$temp_file" 2>/dev/null || true
    return 1
  fi
}

# 错误处理：清理失败时的临时文件
# 参数: 要清理的文件列表
cleanup_on_error() {
  local file
  for file in "$@"; do
    [[ -f "$file" ]] && rm -f "$file" 2>/dev/null || true
  done
}

# 本地缓存模式处理单个文件
# 适用于 NFS 环境，先缓存到本地处理后再传输回去
# 参数: $1 - 输入文件路径
process_single_file_cached() {
  local input_file="$1"
  local output_file
  output_file=$(get_output_path "$input_file")
  
  # 跳过已存在的文件
  if [[ -f "$output_file" ]]; then
    return 0
  fi
  
  # 确保输出目录存在
  mkdir -p "$(dirname "$output_file")"
  
  # 构建本地缓存路径
  local filename
  filename=$(basename "$input_file")
  local cache_input="$LOCAL_CACHE_DIR/input/$filename"
  local cache_output="$LOCAL_CACHE_DIR/output/${filename%.*}.tif"
  
  # 步骤1: 复制输入文件到本地缓存
  if ! cp "$input_file" "$cache_input" 2>/dev/null; then
    log "✗ 复制到缓存失败: $input_file"
    return 1
  fi
  
  # 步骤2: 在本地执行图像转换
  if ! vips tiffsave "$cache_input" "$cache_output" --compression=deflate --tile --tile-width=256 --tile-height=256 --pyramid >/dev/null 2>&1; then
    log "✗ 图像转换失败: $input_file"
    cleanup_on_error "$cache_input" "$cache_output"
    return 1
  fi
  
  # 步骤3: 原子操作复制结果回 NFS
  if ! atomic_move "$cache_output" "$output_file"; then
    log "✗ 复制回 NFS 失败: $input_file"
    cleanup_on_error "$cache_input" "$cache_output" "$output_file"
    return 1
  fi
  
  # 步骤4: 清理本地缓存
  cleanup_on_error "$cache_input" "$cache_output"
  return 0
}

# 直接模式处理单个文件
# 适用于本地存储，直接在目标位置处理
# 参数: $1 - 输入文件路径
process_single_file_direct() {
  local input_file="$1"
  local output_file
  output_file=$(get_output_path "$input_file")
  
  # 跳过已存在的文件
  if [[ -f "$output_file" ]]; then
    return 0
  fi
  
  # 确保输出目录存在
  mkdir -p "$(dirname "$output_file")"
  
  # 使用临时文件确保原子操作
  local temp_file="$output_file.tmp.$$"
  
  # 执行图像转换到临时文件
  if vips tiffsave "$input_file" "$temp_file" --compression=deflate --tile --tile-width=256 --tile-height=256 --pyramid >/dev/null 2>&1; then
    # 原子移动到最终位置
    if mv "$temp_file" "$output_file" 2>/dev/null; then
      return 0
    else
      log "✗ 文件移动失败: $input_file"
      cleanup_on_error "$temp_file"
      return 1
    fi
  else
    log "✗ 图像转换失败: $input_file"
    cleanup_on_error "$temp_file"
    return 1
  fi
}

# 处理模式选择包装器
# 根据配置自动选择缓存模式或直接模式
# 参数: $1 - 输入文件路径
process_file_wrapper() {
  if [[ "$USE_LOCAL_CACHE" == "true" ]]; then
    process_single_file_cached "$@"
  else
    process_single_file_direct "$@"
  fi
}

# 导出函数和变量供 GNU Parallel 使用
export -f process_file_wrapper process_single_file_cached process_single_file_direct
export -f get_output_path atomic_move cleanup_on_error log
export INPUT_DIR OUTPUT_DIR LOCAL_CACHE_DIR USE_LOCAL_CACHE

# 主函数：脚本的入口点
main() {
  # 显示 LOG_LEVEL
  log "当前日志级别: ${LOG_LEVEL:-INFO}"
  # 验证输入目录
  if [[ ! -d "$INPUT_DIR" ]]; then
    log "错误: 输入目录不存在: $INPUT_DIR"
    exit 1
  fi
  
  # 创建输出目录
  mkdir -p "$OUTPUT_DIR"
  
  # 初始化本地缓存（如果启用）
  if [[ "$USE_LOCAL_CACHE" == "true" ]]; then
    log "启用本地缓存模式，缓存目录: $LOCAL_CACHE_DIR"
    # 安全清理并创建缓存目录
    if [[ -d "$LOCAL_CACHE_DIR" ]]; then
      find "$LOCAL_CACHE_DIR" -mindepth 1 -delete 2>/dev/null || true
    fi
    mkdir -p "$LOCAL_CACHE_DIR"/{input,output}
  fi
  
  log "正在查找 TIFF 文件..."
  
  # 查找所有 TIFF 文件，使用 NULL 分隔符处理特殊文件名
  local all_files=()
  mapfile -d '' all_files < <(find "$INPUT_DIR" -type f \( -iname "*.tif" -o -iname "*.tiff" \) -print0)
  log "找到 ${#all_files[@]} 个 TIFF 文件"
  local total_files=${#all_files[@]}
  
  # 检查是否找到文件
  if [[ "$total_files" -eq 0 ]]; then
    log "在 $INPUT_DIR 中未找到 TIFF 文件，任务完成。"
    exit 0
  fi
  
  # 统计已完成的文件数量
  log "正在统计已完成的文件..."
  
  # 安全初始化变量
  local completed_count=0
  local pending_files=()
  local processed_count=0
  
  # 添加错误捕获
  set +e  # 暂时关闭严格错误模式
  
  log "开始检查 $total_files 个文件..."
  
  for input_file in "${all_files[@]}"; do
    # 安全递增计数器
    processed_count=$((processed_count + 1))
    
    # 每处理100个文件显示一次进度
    if [[ $((processed_count % 100)) -eq 0 ]] || [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
      log "已检查 $processed_count/$total_files 个文件..."
    fi
    
    # 调试：显示正在处理的文件
    if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
      log "检查文件: $input_file"
    fi
    
    # 获取输出路径
    local output_file=""
    output_file=$(get_output_path "$input_file" 2>&1)
    local get_path_result=$?
    
    if [[ $get_path_result -ne 0 ]]; then
      log "警告: 无法获取输出路径: $input_file，错误: $output_file"
      continue
    fi
    
    if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
      log "对应输出: $output_file"
    fi
    
    # 检查文件是否存在
    if [[ -f "$output_file" ]]; then
      completed_count=$((completed_count + 1))
      if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
        log "已完成: $output_file"
      fi
    else
      pending_files+=("$input_file")
      if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
        log "待处理: $input_file"
      fi
    fi
  done
  
  # 重新启用严格错误模式
  set -e
  
  log "文件检查完成，共检查了 $processed_count 个文件"
  
  local pending_count=${#pending_files[@]}
  
  # 输出统计信息
  log "文件统计：总计 $total_files 个文件"
  log "  ✅ 已完成：$completed_count 个文件"
  log "  ⏳ 待处理：$pending_count 个文件"
  
  # 如果没有待处理文件，直接完成
  if [[ "$pending_count" -eq 0 ]]; then
    log "✅ 所有文件已完成转换，无需处理。"
    exit 0
  fi
  
  # 更新处理文件列表为待处理文件
  all_files=("${pending_files[@]}")
  log "开始使用 $THREADS 个线程进行并行处理..."
  log "可以使用 'tail -f /tmp/logs/tiff_conversion.log' 查看详细任务日志"
  
  # 使用 GNU Parallel 进行并行处理
  # --null: 输入使用 NULL 分隔符
  # --bar: 显示进度条
  # --eta: 显示预计剩余时间  
  # -j: 并行作业数
  # --joblog: 详细作业日志
  if printf "%s\0" "${all_files[@]}" | \
    parallel \
      --null \
      --bar \
      --eta \
      -j "$THREADS" \
      --joblog /tmp/logs/tiff_conversion.log \
      process_file_wrapper {}; then
    log "✅ 所有文件处理完成"
  else
    log "⚠️ 部分文件处理失败，请检查日志: /tmp/logs/tiff_conversion.log"
    exit 1
  fi
}

# 脚本入口：执行主函数
main "$@"