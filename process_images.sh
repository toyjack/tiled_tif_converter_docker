#!/bin/bash

# 脚本配置
readonly INPUT_DIR="/app/input"
readonly OUTPUT_DIR="/app/output"
readonly DEFAULT_THREADS=${DEFAULT_THREADS:-4}
readonly MAX_THREADS=${MAX_THREADS:-16}

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

# 依赖检查函数
check_dependencies() {
  local missing_deps=()
  for cmd in vips parallel nproc; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_deps+=("$cmd")
    fi
  done
  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    log "错误: 缺少必要的依赖项: ${missing_deps[*]}. 请先安装它们。"
    exit 1
  fi
}

# 使用帮助
show_usage() {
  cat <<EOF
使用方法: $0 [选项]

选项:
  -j, --jobs N    设置并行处理的线程数。
                  'auto' 将使用所有CPU核心数。
                  (默认: $DEFAULT_THREADS, 最大: $MAX_THREADS)
  -h, --help      显示此帮助信息

示例:
  $0              # 使用默认线程数 ($DEFAULT_THREADS)
  $0 -j 8         # 使用8个线程
  $0 --jobs auto  # 自动检测并使用所有CPU核心数
EOF
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

  if [[ "$requested_threads" -gt $MAX_THREADS ]]; then
    log "警告: 请求的线程数 ($requested_threads) 超过最大限制 ($MAX_THREADS)，将使用最大限制。"
    requested_threads=$MAX_THREADS
  fi

  if [[ "$requested_threads" -lt 1 ]]; then
    requested_threads=1
  fi

  echo "$requested_threads"
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
# 导出函数和只读变量给 parallel 使用
export -f process_single_file log
export INPUT_DIR OUTPUT_DIR

# 主函数
main() {
  # 检查依赖
  check_dependencies

  local thread_count_req="$DEFAULT_THREADS"

  # 使用 getopts 进行更标准的参数解析
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -j|--jobs)
        thread_count_req="${2:?错误: --jobs 需要一个参数}"
        shift 2
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      *)
        log "错误: 未知参数 '$1'"
        show_usage
        exit 1
        ;;
    esac
  done

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
      process_single_file {}; then
    log "✅ 所有文件处理成功。"
  else
    log "⚠️ 部分文件处理失败。请检查日志 /tmp/tiff_conversion.log 获取详情。"
    exit 1
  fi
}

# 执行主函数，并传递所有命令行参数
main "$@"