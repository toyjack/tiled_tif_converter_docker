#!/bin/bash

# =================================================================
# TIFF 图像批量处理脚本 - 修复版本
# 功能：将 TIFF 图像转换为压缩的金字塔 TIFF 格式
# 支持：本地缓存模式（NFS 优化）、并行处理、断点续传
# =================================================================

# 脚本配置
readonly INPUT_DIR="/app/input"
readonly OUTPUT_DIR="/app/output" 
readonly THREADS=${THREADS:-4}
readonly LOCAL_CACHE_DIR="/tmp/cache"
readonly USE_LOCAL_CACHE=${USE_LOCAL_CACHE:-true}
readonly LOG_LEVEL=${LOG_LEVEL:-INFO}

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

# 生成安全的临时文件名
# 参数: $1 - 基础文件路径
# 输出: 临时文件路径
generate_temp_file() {
  local base_file="$1"
  local random_suffix
  random_suffix=$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')
  echo "${base_file}.tmp.${random_suffix}"
}

# 确保目录存在
# 参数: $1 - 目录路径
ensure_directory() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || {
      log "错误: 无法创建目录 $dir"
      return 1
    }
  fi
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
  
  # 使用 realpath 处理路径，避免符号链接问题
  local real_input
  real_input=$(realpath "$input_file" 2>/dev/null) || real_input="$input_file"
  
  local filename
  filename=$(basename "$real_input")
  
  # 计算相对路径，处理根目录情况
  local normalized_input_dir
  normalized_input_dir=$(realpath "$INPUT_DIR" 2>/dev/null) || normalized_input_dir="$INPUT_DIR"
  
  local relative_path="${real_input#$normalized_input_dir}"
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
  local temp_file
  temp_file=$(generate_temp_file "$target")
  
  # 确保目标目录存在
  ensure_directory "$(dirname "$target")" || return 1
  
  # 设置临时文件清理trap
  local cleanup_temp() {
    [[ -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null || true
  }
  trap cleanup_temp RETURN
  
  if cp "$source" "$temp_file" 2>/dev/null && mv "$temp_file" "$target" 2>/dev/null; then
    return 0
  else
    cleanup_temp
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

# 成功处理后的清理
# 参数: 要清理的文件列表
cleanup_on_success() {
  local file
  for file in "$@"; do
    [[ -f "$file" ]] && rm -f "$file" 2>/dev/null || true
  done
}

# 检查输出文件是否已存在
# 参数: $1 - 输入文件路径
# 返回: 0 需要处理, 1 已存在跳过
should_process_file() {
  local input_file="$1"
  local output_file
  output_file=$(get_output_path "$input_file") || return 1
  
  if [[ -f "$output_file" ]]; then
    [[ "$LOG_LEVEL" == "DEBUG" ]] && log "跳过已存在文件: $output_file"
    return 1
  fi
  return 0
}

# 本地缓存模式处理单个文件
# 适用于 NFS 环境，先缓存到本地处理后再传输回去
# 参数: $1 - 输入文件路径
process_single_file_cached() {
  local input_file="$1"
  local output_file
  output_file=$(get_output_path "$input_file") || return 1
  
  # 检查是否需要处理
  should_process_file "$input_file" && return 0
  
  # 确保输出目录存在
  ensure_directory "$(dirname "$output_file")" || return 1
  
  # 构建本地缓存路径
  local filename
  filename=$(basename "$input_file")
  local cache_input="$LOCAL_CACHE_DIR/input/$filename"
  local cache_output="$LOCAL_CACHE_DIR/output/$(basename "${output_file}")"
  
  # 确保缓存目录存在
  ensure_directory "$(dirname "$cache_input")" || return 1
  ensure_directory "$(dirname "$cache_output")" || return 1
  
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
  cleanup_on_success "$cache_input" "$cache_output"
  return 0
}

# 直接模式处理单个文件
# 适用于本地存储，直接在目标位置处理
# 参数: $1 - 输入文件路径
process_single_file_direct() {
  local input_file="$1"
  local output_file
  output_file=$(get_output_path "$input_file") || return 1
  
  # 检查是否需要处理
  should_process_file "$input_file" && return 0
  
  # 确保输出目录存在
  ensure_directory "$(dirname "$output_file")" || return 1
  
  # 使用临时文件确保原子操作
  local temp_file
  temp_file=$(generate_temp_file "$output_file")
  
  # 设置临时文件清理
  local cleanup_temp() {
    [[ -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null || true
  }
  trap cleanup_temp RETURN
  
  # 执行图像转换到临时文件
  if vips tiffsave "$input_file" "$temp_file" --compression=deflate --tile --tile-width=256 --tile-height=256 --pyramid >/dev/null 2>&1; then
    # 原子移动到最终位置
    if mv "$temp_file" "$output_file" 2>/dev/null; then
      return 0
    else
      log "✗ 文件移动失败: $input_file"
      return 1
    fi
  else
    log "✗ 图像转换失败: $input_file"
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

# 验证函数导出
verify_exports() {
  local functions=(
    "process_file_wrapper"
    "process_single_file_cached" 
    "process_single_file_direct"
    "get_output_path"
    "atomic_move"
    "cleanup_on_error"
    "cleanup_on_success"
    "log"
    "generate_temp_file"
    "ensure_directory"
    "should_process_file"
  )
  
  local variables=(
    "INPUT_DIR"
    "OUTPUT_DIR" 
    "LOCAL_CACHE_DIR"
    "USE_LOCAL_CACHE"
    "LOG_LEVEL"
  )
  
  # 导出函数
  for func in "${functions[@]}"; do
    if ! declare -F "$func" >/dev/null; then
      log "错误: 函数 $func 未定义"
      return 1
    fi
    export -f "$func"
  done
  
  # 导出变量
  for var in "${variables[@]}"; do
    export "$var"
  done
  
  return 0
}

# 优化的文件状态检查
# 使用更高效的方法匹配输入输出文件
check_file_status() {
  local -a all_files=("$@")
  local total_files=${#all_files[@]}
  local -a pending_files=()
  local completed_count=0
  
  log "开始高效文件状态检查，共 $total_files 个文件"
  
  # 创建输出文件映射
  local -A output_files_map
  local output_count=0
  
  # 批量扫描输出目录
  while IFS= read -r -d '' output_file; do
    local relative_path="${output_file#$OUTPUT_DIR/}"
    # 移除 .tif 扩展名得到基础名
    local base_name="${relative_path%.tif}"
    output_files_map["$base_name"]=1
    ((output_count++))
    
    if [[ $((output_count % 1000)) -eq 0 ]]; then
      log "已扫描输出文件: $output_count 个"
    fi
  done < <(find "$OUTPUT_DIR" -type f -name "*.tif" -print0 2>/dev/null)
  
  log "输出目录扫描完成，找到 $output_count 个已完成文件"
  
  # 检查输入文件状态
  local processed_count=0
  for input_file in "${all_files[@]}"; do
    ((processed_count++))
    
    if [[ $((processed_count % 1000)) -eq 0 ]]; then
      log "已检查 $processed_count/$total_files 个文件"
    fi
    
    # 计算输入文件对应的输出文件基础名
    local relative_input="${input_file#$INPUT_DIR/}"
    local input_base="${relative_input%.*}"
    
    if [[ ${output_files_map["$input_base"]:-} ]]; then
      ((completed_count++))
    else
      pending_files+=("$input_file")
    fi
  done
  
  # 返回结果
  echo "$completed_count"
  printf "%s\0" "${pending_files[@]}"
}

# 主函数：脚本的入口点
main() {
  # 显示配置信息
  log "当前配置："
  log "  日志级别: $LOG_LEVEL"
  log "  线程数: $THREADS"
  log "  缓存模式: $USE_LOCAL_CACHE"
  log "  输入目录: $INPUT_DIR"
  log "  输出目录: $OUTPUT_DIR"
  
  # 验证输入目录
  if [[ ! -d "$INPUT_DIR" ]]; then
    log "错误: 输入目录不存在: $INPUT_DIR"
    exit 1
  fi
  
  # 创建输出目录
  ensure_directory "$OUTPUT_DIR" || exit 1
  
  # 初始化本地缓存（如果启用）
  if [[ "$USE_LOCAL_CACHE" == "true" ]]; then
    log "启用本地缓存模式，缓存目录: $LOCAL_CACHE_DIR"
    # 安全清理并创建缓存目录
    if [[ -d "$LOCAL_CACHE_DIR" ]]; then
      find "$LOCAL_CACHE_DIR" -mindepth 1 -delete 2>/dev/null || true
    fi
    ensure_directory "$LOCAL_CACHE_DIR/input" || exit 1
    ensure_directory "$LOCAL_CACHE_DIR/output" || exit 1
  fi
  
  # 创建日志目录
  ensure_directory "/tmp/logs" || exit 1
  
  log "正在查找 TIFF 文件..."
  
  # 查找所有 TIFF 文件，使用 NULL 分隔符处理特殊文件名
  local -a all_files=()
  if ! mapfile -d '' all_files < <(find "$INPUT_DIR" -type f \( -iname "*.tif" -o -iname "*.tiff" \) -print0); then
    log "错误: 查找 TIFF 文件失败"
    exit 1
  fi
  
  local total_files=${#all_files[@]}
  log "找到 $total_files 个 TIFF 文件"
  
  # 检查是否找到文件
  if [[ "$total_files" -eq 0 ]]; then
    log "在 $INPUT_DIR 中未找到 TIFF 文件，任务完成。"
    exit 0
  fi
  
  # 高效的文件状态检查
  local status_result
  status_result=$(check_file_status "${all_files[@]}")
  
  local completed_count
  completed_count=$(echo "$status_result" | head -n1)
  
  local -a pending_files=()
  while IFS= read -r -d '' file; do
    [[ -n "$file" ]] && pending_files+=("$file")
  done < <(echo "$status_result" | tail -n+2)
  
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
  
  # 验证函数和变量导出
  if ! verify_exports; then
    log "错误: 函数或变量导出失败"
    exit 1
  fi
  
  log "开始使用 $THREADS 个线程进行并行处理..."
  log "可以使用 'tail -f /tmp/logs/tiff_conversion.log' 查看详细任务日志"
  
  # 使用 GNU Parallel 进行并行处理
  if printf "%s\0" "${pending_files[@]}" | \
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