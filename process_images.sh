#!/bin/bash

# 配置变量
readonly INPUT_DIR="/app/input"
readonly OUTPUT_DIR="/app/output"

# 错误处理
set -euo pipefail

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 安全更新进度计数器
update_progress() {
    (
        flock -x 200
        echo "1" >> /tmp/progress_counter
        local current_count=$(wc -l < /tmp/progress_counter)
        echo "$current_count"
    ) 200>/tmp/progress_counter.lock
}

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 单个文件处理函数
process_single_file() {
    local input_file="$1"
    local relative_path="${input_file#$INPUT_DIR/}"
    local output_file="$OUTPUT_DIR/${relative_path%.*}.tif"
    local output_dir
    output_dir=$(dirname "$output_file")
    
    # 跳过已存在的文件
    if [[ -f "$output_file" ]]; then
        local current_count=$(update_progress)
        log "跳过已存在文件: $relative_path (进度: $current_count/$TOTAL_FILES)"
        return 0
    fi
    
    # 创建输出目录
    mkdir -p "$output_dir"
    
    # 执行转换
    if vips im_vips2tiff "$input_file" "$output_file:deflate,tile:256x256,pyramid" 2>/dev/null; then
        local current_count=$(update_progress)
        local percentage=$((current_count * 100 / TOTAL_FILES))
        log "✓ 已完成: $relative_path (进度: $current_count/$TOTAL_FILES - $percentage%)"
    else
        local current_count=$(update_progress)
        local percentage=$((current_count * 100 / TOTAL_FILES))
        log "✗ 失败: $relative_path (进度: $current_count/$TOTAL_FILES - $percentage%)"
        rm -f "$output_file"  # 清理失败的文件
        return 1
    fi
}

# 获取文件列表
get_tiff_files() {
    find "$INPUT_DIR" -type f \( -iname "*.tif" -o -iname "*.tiff" \) 2>/dev/null || true
}

# 统计文件数量
count_files() {
    get_tiff_files | wc -l
}

# 统计已完成文件数量
count_completed_files() {
    local count=0
    while IFS= read -r -d '' input_file; do
        local relative_path="${input_file#$INPUT_DIR/}"
        local output_file="$OUTPUT_DIR/${relative_path%.*}.tif"
        [[ -f "$output_file" ]] && ((count++))
    done < <(get_tiff_files | tr '\n' '\0')
    echo "$count"
}

# 主函数
main() {
    log "开始TIFF文件处理任务"
    
    # 检查输入目录
    if [[ ! -d "$INPUT_DIR" ]]; then
        log "错误: 输入目录不存在: $INPUT_DIR"
        exit 1
    fi
    
    # 统计文件
    log "正在统计文件数量..."
    local total_files
    total_files=$(count_files)
    
    if [[ "$total_files" -eq 0 ]]; then
        log "未找到TIFF文件，退出"
        exit 0
    fi
    
    local completed_files
    completed_files=$(count_completed_files)
    local remaining_files=$((total_files - completed_files))
    
    # 显示统计信息
    log "文件统计:"
    log "  总文件数: $total_files"
    log "  已完成: $completed_files"
    log "  待处理: $remaining_files"
    
    # 检查是否需要处理
    if [[ "$remaining_files" -eq 0 ]]; then
        log "所有文件已处理完成"
        exit 0
    fi
    
    # 初始化进度计数器
    rm -f /tmp/progress_counter /tmp/progress_counter.lock
    touch /tmp/progress_counter
    # 预填已完成的文件数
    for ((i=1; i<=completed_files; i++)); do
        echo "1" >> /tmp/progress_counter
    done
    
    # 导出变量和函数供parallel使用
    export -f process_single_file log update_progress
    export INPUT_DIR OUTPUT_DIR TOTAL_FILES=$total_files
    
    # 开始并行处理
    log "开始并行处理文件..."
    
    if get_tiff_files | parallel -j+0 --will-cite process_single_file {}; then
        log "所有文件处理完成"
    else
        log "处理过程中出现错误，请检查日志"
        exit 1
    fi
}

# 清理函数
cleanup() {
    log "清理临时文件..."
    rm -f /tmp/progress_counter /tmp/progress_counter.lock
}

# 设置退出时清理
trap cleanup EXIT

# 执行主函数
main "$@"