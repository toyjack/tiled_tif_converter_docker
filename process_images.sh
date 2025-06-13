#!/bin/bash

# 配置变量
readonly INPUT_DIR="/app/input"
readonly OUTPUT_DIR="/app/output"

# 错误处理 - 移除 set -e，手动处理错误
set -uo pipefail

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
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
        return 2  # 返回特殊代码表示跳过
    fi
    
    # 创建输出目录
    mkdir -p "$output_dir"
    
    # 执行转换
    if vips im_vips2tiff "$input_file" "$output_file:deflate,tile:256x256,pyramid" 2>/dev/null; then
        return 0  # 成功
    else
        rm -f "$output_file" 2>/dev/null || true  # 清理失败的文件
        return 1  # 失败
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
    
    # 开始单线程处理
    log "开始处理文件..."
    
    local processed=0
    local failed=0
    local skipped=0
    
    while IFS= read -r -d '' input_file; do
        local relative_path="${input_file#$INPUT_DIR/}"
        ((processed++))
        local percentage=$((processed * 100 / total_files))
        
        # 处理文件 - 直接调用函数并检查返回值
        process_single_file "$input_file"
        local exit_code=$?
        
        case $exit_code in
            0)  # 成功
                log "✓ 已完成: $relative_path (进度: $processed/$total_files - $percentage%)"
                ;;
            1)  # 失败
                ((failed++))
                log "✗ 失败: $relative_path (进度: $processed/$total_files - $percentage%)"
                ;;
            2)  # 跳过
                ((skipped++))
                log "跳过已存在文件: $relative_path (进度: $processed/$total_files - $percentage%)"
                ;;
        esac
        
    done < <(get_tiff_files | tr '\n' '\0')
    
    # 显示最终统计
    log "处理完成统计:"
    log "  总处理文件: $processed"
    log "  跳过文件: $skipped"
    log "  处理失败: $failed"
    log "  处理成功: $((processed - skipped - failed))"
    
    if [[ "$failed" -gt 0 ]]; then
        log "处理过程中有 $failed 个文件失败"
        exit 1
    else
        log "所有文件处理完成"
    fi
}

# 清理函数
cleanup() {
    log "清理完成"
}

# 设置退出时清理
trap cleanup EXIT

# 执行主函数
main "$@"