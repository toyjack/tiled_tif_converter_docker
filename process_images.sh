#!/bin/bash

# =================================================================
# TIFF 图像批量处理脚本
# 功能：将 TIFF 图像转换为压缩的金字塔 TIFF 格式
# 支持：本地缓存模式（NFS 优化）、并行处理、断点续传
# =================================================================

# ============================== 配置部分 ==============================

# 基础配置
readonly INPUT_DIR="/app/input"
readonly OUTPUT_DIR="/app/output" 
readonly THREADS=${THREADS:-4}
readonly LOG_LEVEL=${LOG_LEVEL:-INFO}

# 缓存配置
readonly USE_LOCAL_CACHE=${USE_LOCAL_CACHE:-true}
readonly LOCAL_CACHE_DIR="/tmp/cache"

# 日志配置
readonly LOG_DIR="/tmp/logs"
readonly JOB_LOG="$LOG_DIR/tiff_conversion.log"

# 磁盘空间配置
readonly MIN_FREE_SPACE_MB=${MIN_FREE_SPACE_MB:-1024}  # 最小剩余空间1GB
readonly PARALLEL_TMPDIR=${PARALLEL_TMPDIR:-/tmp}      # Parallel临时目录
readonly MAX_CACHE_FILES=${MAX_CACHE_FILES:-50}        # 最大同时缓存文件数

# 处理配置
readonly VIPS_ARGS="--compression=deflate --tile --tile-width=256 --tile-height=256 --pyramid"
readonly PROGRESS_INTERVAL=100

# ============================== 错误处理 ==============================

# 严格错误处理
# set -Eeuo pipefail

# 退出清理函数
cleanup() {
  if [[ "${USE_LOCAL_CACHE}" == "true" && -d "${LOCAL_CACHE_DIR}" ]]; then
    find "${LOCAL_CACHE_DIR}" -mindepth 1 -delete 2>/dev/null || true
  fi
}

# 设置退出时的清理函数
trap 'cleanup' EXIT

# ============================== 工具函数 ==============================

# 日志函数
log() {
  local level="${2:-INFO}"
  echo >&2 "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $1"
}

# 调试日志
debug() {
  [[ "${LOG_LEVEL}" == "DEBUG" ]] && log "$1" "DEBUG"
}

# 错误日志
error() {
  log "$1" "ERROR"
}

# 确保目录存在
ensure_directory() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || {
      error "无法创建目录: $dir"
      return 1
    }
  fi
}

# 安全清理文件
safe_cleanup() {
  local file
  for file in "$@"; do
    [[ -f "$file" ]] && rm -f "$file" 2>/dev/null || true
  done
}

# 检查磁盘空间
check_disk_space() {
  local dir="$1"
  local min_mb="${2:-$MIN_FREE_SPACE_MB}"
  
  # 获取可用空间（MB）
  local available_mb
  available_mb=$(df "$dir" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1024}')
  
  if [[ -z "$available_mb" || "$available_mb" -lt "$min_mb" ]]; then
    error "磁盘空间不足: $dir 仅剩 ${available_mb}MB，需要至少 ${min_mb}MB"
    return 1
  fi
  
  log "磁盘空间检查: $dir 可用 ${available_mb}MB"
  return 0
}

# 清理过期的临时文件
cleanup_temp_files() {
  local temp_dir="$1"
  local max_age_minutes="${2:-60}"
  
  if [[ -d "$temp_dir" ]]; then
    # 清理超过指定时间的临时文件
    find "$temp_dir" -type f -mmin +$max_age_minutes -delete 2>/dev/null || true
    # 清理空目录
    find "$temp_dir" -type d -empty -delete 2>/dev/null || true
  fi
}

# 管理缓存文件数量
manage_cache_size() {
  local cache_dir="$1"
  local max_files="$2"
  
  if [[ ! -d "$cache_dir" ]]; then
    return 0
  fi
  
  # 统计当前缓存文件数
  local current_files
  current_files=$(find "$cache_dir" -type f | wc -l)
  
  if [[ "$current_files" -gt "$max_files" ]]; then
    log "缓存文件过多($current_files)，清理最旧的文件..."
    # 删除最旧的文件，保留最新的max_files个
    find "$cache_dir" -type f -printf '%T@ %p\n' | \
      sort -n | \
      head -n -$max_files | \
      cut -d' ' -f2- | \
      xargs -r rm -f
  fi
}

# ============================== 路径处理函数 ==============================

# 获取相对路径的基础名称（用于匹配）
get_base_name() {
  local file_path="$1"
  local base_dir="$2"
  
  # 标准化基础目录路径
  local normalized_base="${base_dir%/}/"
  
  # 移除基础目录前缀
  local relative_path="${file_path#$normalized_base}"
  
  # 如果移除失败（路径不在基础目录下），使用文件名
  if [[ "$relative_path" == "$file_path" ]]; then
    relative_path=$(basename "$file_path")
  fi
  
  # 移除文件扩展名
  echo "${relative_path%.*}"
}

# 获取输出文件路径
get_output_path() {
  local input_file="$1"
  
  if [[ -z "$input_file" ]]; then
    error "get_output_path: 缺少输入文件参数"
    return 1
  fi
  
  # 计算相对路径
  local relative_path="${input_file#${INPUT_DIR%/}/}"
  local relative_dir
  relative_dir=$(dirname "$relative_path")
  local filename
  filename=$(basename "$input_file")
  
  # 构建输出路径
  if [[ "$relative_dir" == "." ]]; then
    echo "$OUTPUT_DIR/${filename%.*}.tif"
  else
    echo "$OUTPUT_DIR/$relative_dir/${filename%.*}.tif"
  fi
}

# ============================== 文件操作函数 ==============================

# 原子文件移动
atomic_move() {
  local source="$1"
  local target="$2"
  local temp_file="$target.tmp.$$"
  
  if cp "$source" "$temp_file" 2>/dev/null && mv "$temp_file" "$target" 2>/dev/null; then
    return 0
  else
    safe_cleanup "$temp_file"
    return 1
  fi
}

# 检查文件是否需要处理
should_process_file() {
  local output_file="$1"
  [[ ! -f "$output_file" ]]
}

# ============================== 图像处理函数 ==============================

# 执行VIPS转换
execute_vips_conversion() {
  local input_file="$1"
  local output_file="$2"
  
  vips tiffsave "$input_file" "$output_file" $VIPS_ARGS >/dev/null 2>&1
}

# 缓存模式处理文件（优化磁盘空间管理）
process_file_cached() {
  local input_file="$1"
  local output_file
  output_file=$(get_output_path "$input_file")
  
  # 跳过已存在的文件
  should_process_file "$output_file" || return 0
  
  # 检查磁盘空间
  if ! check_disk_space "/tmp" 500; then  # 至少需要500MB
    error "缓存空间不足，跳过文件: $input_file"
    return 1
  fi
  
  # 管理缓存大小
  manage_cache_size "$LOCAL_CACHE_DIR" "$MAX_CACHE_FILES"
  
  # 确保输出目录存在
  ensure_directory "$(dirname "$output_file")" || return 1
  
  # 构建缓存路径
  local filename
  filename=$(basename "$input_file")
  local cache_input="$LOCAL_CACHE_DIR/input/$filename"
  local cache_output="$LOCAL_CACHE_DIR/output/${filename%.*}.tif"
  
  # 步骤1: 复制到缓存
  if ! cp "$input_file" "$cache_input" 2>/dev/null; then
    error "复制到缓存失败: $input_file"
    return 1
  fi
  
  # 步骤2: 执行转换
  if ! execute_vips_conversion "$cache_input" "$cache_output"; then
    error "图像转换失败: $input_file"
    safe_cleanup "$cache_input" "$cache_output"
    return 1
  fi
  
  # 步骤3: 原子移动到最终位置
  if ! atomic_move "$cache_output" "$output_file"; then
    error "复制回目标失败: $input_file"
    safe_cleanup "$cache_input" "$cache_output"
    return 1
  fi
  
  # 步骤4: 立即清理缓存（减少磁盘占用）
  safe_cleanup "$cache_input"
  return 0
}

# 直接模式处理文件
process_file_direct() {
  local input_file="$1"
  local output_file
  output_file=$(get_output_path "$input_file")
  
  # 跳过已存在的文件
  should_process_file "$output_file" || return 0
  
  # 确保输出目录存在
  ensure_directory "$(dirname "$output_file")" || return 1
  
  # 使用临时文件确保原子操作
  local temp_file="$output_file.tmp.$$"
  
  # 执行转换
  if execute_vips_conversion "$input_file" "$temp_file"; then
    # 原子移动
    if mv "$temp_file" "$output_file" 2>/dev/null; then
      return 0
    else
      error "文件移动失败: $input_file"
      safe_cleanup "$temp_file"
      return 1
    fi
  else
    error "图像转换失败: $input_file"
    safe_cleanup "$temp_file"
    return 1
  fi
}

# 处理文件包装器
process_file_wrapper() {
  if [[ "$USE_LOCAL_CACHE" == "true" ]]; then
    process_file_cached "$@"
  else
    process_file_direct "$@"
  fi
}

# ============================== 文件发现和状态检查 ==============================

# 查找所有TIFF文件
find_tiff_files() {
  local -n files_ref=$1
  
  if ! mapfile -d '' files_ref < <(find "$INPUT_DIR" -type f \( -iname "*.tif" -o -iname "*.tiff" \) -print0 2>/dev/null); then
    error "查找TIFF文件失败"
    return 1
  fi
  
  log "找到 ${#files_ref[@]} 个TIFF文件"
  return 0
}

# 扫描已完成的文件
scan_completed_files() {
  local -n processed_ref=$1
  local scan_count=0
  
  log "正在扫描输出目录..."
  
  # 直接使用进程替换扫描输出目录
  # 使用 || true 确保即使没有找到文件也不会出错
  while IFS= read -r -d '' output_file; do
    # 跳过空行
    [[ -n "$output_file" ]] || continue
    
    local base_name
    base_name=$(get_base_name "$output_file" "$OUTPUT_DIR")
    processed_ref["$base_name"]=1
    ((scan_count++))
    
    debug "输出映射: $output_file -> $base_name"
    
    if [[ $((scan_count % PROGRESS_INTERVAL)) -eq 0 ]]; then
      log "已扫描输出文件: $scan_count 个..."
    fi
    
    debug "已完成文件: $base_name"
  done < <(find "$OUTPUT_DIR" -type f -name "*.tif" -print0 2>/dev/null || true)
  
  log "输出目录扫描完成，找到 $scan_count 个已完成文件"
  
  # 调试：显示已处理文件列表
  if [[ "${LOG_LEVEL}" == "DEBUG" && $scan_count -gt 0 ]]; then
    log "已处理文件键列表："
    for key in "${!processed_ref[@]}"; do
      log "  - '$key'"
    done
  fi
}

# 内联版本的get_base_name，避免函数调用开销
get_base_name_inline() {
  local file_path="$1"
  local base_dir="$2"
  
  # 标准化基础目录路径
  local normalized_base="${base_dir%/}/"
  
  # 移除基础目录前缀
  local relative_path="${file_path#$normalized_base}"
  
  # 如果移除失败，使用文件名
  if [[ "$relative_path" == "$file_path" ]]; then
    relative_path="${file_path##*/}"  # 更快的basename
  fi
  
  # 移除文件扩展名并直接返回
  echo "${relative_path%.*}"
}

# 高性能的文件状态分析函数
analyze_file_status() {
  local -n all_files_ref=$1
  local -n processed_files_ref=$2
  local -n pending_files_ref=$3
  local -n completed_count_ref=$4
  
  local total_files=${#all_files_ref[@]}
  local normalized_input_dir="${INPUT_DIR%/}/"
  local is_debug=false
  
  # 预先判断是否为DEBUG模式，避免重复检查
  [[ "${LOG_LEVEL}" == "DEBUG" ]] && is_debug=true
  
  log "开始检查 $total_files 个输入文件..."
  
  # 使用本地数组收集待处理文件，避免频繁扩展
  local pending_temp=()
  local processed_count=0
  local next_progress_report=$PROGRESS_INTERVAL
  
  for input_file in "${all_files_ref[@]}"; do
    ((processed_count++))
    
    # 优化进度报告：使用预计算阈值
    if [[ $processed_count -eq $next_progress_report ]]; then
      log "已检查 $processed_count/$total_files 个文件..."
      next_progress_report=$((processed_count + PROGRESS_INTERVAL))
    fi
    
    # 高效的内联路径处理
    local relative_path="${input_file#$normalized_input_dir}"
    [[ "$relative_path" == "$input_file" ]] && relative_path="${input_file##*/}"
    local input_base="${relative_path%.*}"
    
    # 条件调试输出
    $is_debug && debug "输入映射: $input_file -> $input_base"
    
    # 检查是否已完成
    if [[ ${processed_files_ref["$input_base"]:-} ]]; then
      ((completed_count_ref++))
      $is_debug && debug "✅ 匹配成功: $input_base"
    else
      pending_temp+=("$input_file")
      $is_debug && debug "❌ 未找到匹配: $input_base"
    fi
  done
  
  # 批量复制到目标数组
  pending_files_ref=("${pending_temp[@]}")
  
  log "文件检查完成，共检查了 $processed_count 个文件"
}

# 为大文件集合提供的并行版本（实验性）
analyze_file_status_parallel() {
  local -n all_files_ref=$1
  local -n processed_files_ref=$2
  local -n pending_files_ref=$3
  local -n completed_count_ref=$4
  
  local total_files=${#all_files_ref[@]}
  
  # 仅在文件数量大于阈值时使用并行处理
  if [[ $total_files -lt 1000 ]]; then
    analyze_file_status "$@"
    return
  fi
  
  log "文件数量较大($total_files)，使用并行分析..."
  
  # 创建临时文件存储结果
  local temp_dir="/tmp/analyze_$$"
  mkdir -p "$temp_dir"
  
  # 分块处理
  local chunk_size=100
  local chunk_count=0
  local normalized_input_dir="${INPUT_DIR%/}/"
  
  # 导出必要的变量和函数
  export INPUT_DIR OUTPUT_DIR normalized_input_dir
  export -A processed_files_ref
  
  # 使用xargs进行并行处理
  printf '%s\n' "${all_files_ref[@]}" | \
  xargs -n $chunk_size -P "$THREADS" -I {} bash -c '
    completed=0
    pending_file="'$temp_dir'/pending.$$.txt"
    for file in "$@"; do
      relative="${file#'$normalized_input_dir'}"
      [[ "$relative" == "$file" ]] && relative="${file##*/}"
      base="${relative%.*}"
      if [[ ${processed_files_ref["$base"]:-} ]]; then
        ((completed++))
      else
        echo "$file" >> "$pending_file"
      fi
    done
    echo "$completed" > "'$temp_dir'/completed.$$.txt"
  ' _ {}
  
  # 收集结果
  local pending_temp=()
  completed_count_ref=0
  
  for completed_file in "$temp_dir"/completed.*.txt; do
    [[ -f "$completed_file" ]] || continue
    local count
    count=$(cat "$completed_file")
    completed_count_ref=$((completed_count_ref + count))
  done
  
  for pending_file in "$temp_dir"/pending.*.txt; do
    [[ -f "$pending_file" ]] || continue
    while IFS= read -r file; do
      pending_temp+=("$file")
    done < "$pending_file"
  done
  
  pending_files_ref=("${pending_temp[@]}")
  
  # 清理临时文件
  rm -rf "$temp_dir"
  
  log "并行分析完成，共检查了 $total_files 个文件"
}

# ============================== 主要流程函数 ==============================

# 初始化环境
initialize_environment() {
  log "当前日志级别: $LOG_LEVEL"
  
  # 验证输入目录
  if [[ ! -d "$INPUT_DIR" ]]; then
    error "输入目录不存在: $INPUT_DIR"
    exit 1
  fi
  
  # 磁盘空间检查
  log "检查磁盘空间..."
  check_disk_space "/tmp" "$MIN_FREE_SPACE_MB" || exit 1
  # check_disk_space "$OUTPUT_DIR" "$MIN_FREE_SPACE_MB" || exit 1
  
  # 清理过期的临时文件
  cleanup_temp_files "/tmp" 60
  
  # 创建必要的目录
  ensure_directory "$OUTPUT_DIR" || exit 1
  ensure_directory "$LOG_DIR" || exit 1
  
  # 设置Parallel临时目录
  export TMPDIR="$PARALLEL_TMPDIR"
  export PARALLEL_TMPDIR
  
  # 初始化缓存（如果启用）
  if [[ "$USE_LOCAL_CACHE" == "true" ]]; then
    log "启用本地缓存模式，缓存目录: $LOCAL_CACHE_DIR"
    
    # 清理并创建缓存目录
    if [[ -d "$LOCAL_CACHE_DIR" ]]; then
      find "$LOCAL_CACHE_DIR" -mindepth 1 -delete 2>/dev/null || true
    fi
    ensure_directory "$LOCAL_CACHE_DIR/input" || exit 1
    ensure_directory "$LOCAL_CACHE_DIR/output" || exit 1
    
    log "缓存配置: 最大文件数=$MAX_CACHE_FILES，最小剩余空间=${MIN_FREE_SPACE_MB}MB"
  fi
}

# 执行并行处理（优化缓冲区使用）
execute_parallel_processing() {
  local -n files_ref=$1
  local file_count=${#files_ref[@]}
  
  log "开始使用 $THREADS 个线程进行并行处理..."
  log "可以使用 'tail -f $JOB_LOG' 查看详细任务日志"
  
  # 最终磁盘空间检查
  if ! check_disk_space "/tmp" 200; then
    error "磁盘空间不足，无法启动并行处理"
    return 1
  fi
  
  # 执行并行处理，优化参数减少缓冲区使用
  if printf "%s\0" "${files_ref[@]}" | \
    parallel \
      --null \
      --bar \
      --eta \
      -j "$THREADS" \
      --joblog "$JOB_LOG" \
      --ungroup \
      --memfree 100M \
      process_file_wrapper {}; then
    log "✅ 所有文件处理完成"
    
    # 清理Parallel临时文件
    cleanup_temp_files "$PARALLEL_TMPDIR" 0
    
    return 0
  else
    error "部分文件处理失败，请检查日志: $JOB_LOG"
    
    # 清理失败后的临时文件
    cleanup_temp_files "$PARALLEL_TMPDIR" 0
    
    return 1
  fi
}

# ============================== 主函数 ==============================

main() {
  # 初始化环境
  initialize_environment
  
  # 查找所有TIFF文件
  local all_files=()
  find_tiff_files all_files || exit 1
  
  local total_files=${#all_files[@]}
  if [[ "$total_files" -eq 0 ]]; then
    log "在 $INPUT_DIR 中未找到TIFF文件，任务完成。"
    exit 0
  fi
  
  # 扫描已完成的文件
  declare -A processed_files
  scan_completed_files processed_files
  
  # 分析文件状态
  local pending_files=()
  local completed_count=0
  analyze_file_status all_files processed_files pending_files completed_count
  
  local pending_count=${#pending_files[@]}
  
  # 输出统计信息
  log "文件统计：总计 $total_files 个文件"
  log "  ✅ 已完成：$completed_count 个文件"
  log "  ⏳ 待处理：$pending_count 个文件"
  
  # 检查是否有待处理文件
  if [[ "$pending_count" -eq 0 ]]; then
    log "✅ 所有文件已完成转换，无需处理。"
    exit 0
  fi
  
  # 执行并行处理
  execute_parallel_processing pending_files || exit 1
}

# ============================== 导出和入口 ==============================

# 导出函数和变量供GNU Parallel使用
export -f process_file_wrapper process_file_cached process_file_direct
export -f get_output_path atomic_move execute_vips_conversion
export -f ensure_directory safe_cleanup should_process_file
export -f log error debug get_base_name check_disk_space manage_cache_size
export INPUT_DIR OUTPUT_DIR LOCAL_CACHE_DIR USE_LOCAL_CACHE LOG_LEVEL VIPS_ARGS
export MIN_FREE_SPACE_MB MAX_CACHE_FILES PARALLEL_TMPDIR

# 脚本入口
main "$@"