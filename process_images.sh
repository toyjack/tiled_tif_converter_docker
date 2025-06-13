#!/bin/bash

INPUT_DIR="/app/input"
OUTPUT_DIR="/app/output"
QUALITY=${QUALITY:-80}
FORMAT=${FORMAT:-webp}

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 处理函数
process_image() {
    local input_file="$1"
    local relative_path="${input_file#$INPUT_DIR/}"
    local output_file="$OUTPUT_DIR/${relative_path%.*}.tif"
    local output_dir=$(dirname "$output_file")
    
    # 检查输出文件是否已存在
    if [ -f "$output_file" ]; then
        echo "跳过已存在文件: $relative_path"
        echo "1" >> /tmp/progress_counter
        return 0
    fi
    
    # 创建输出目录结构
    mkdir -p "$output_dir"
    
    # 执行 vips im_vips2tiff 命令
    echo "Processing: $relative_path"
    if vips im_vips2tiff "$input_file" "$output_file:deflate,tile:256x256,pyramid"; then
        echo "完成: $relative_path"
    else
        echo "失败: $relative_path"
        # 删除可能生成的不完整文件
        rm -f "$output_file"
    fi
    
    # 更新进度计数器
    echo "1" >> /tmp/progress_counter
}

# 导出函数以便 parallel 使用
export -f process_image
export INPUT_DIR OUTPUT_DIR

# 统计总文件数和已完成文件数
echo "正在统计文件数量..."
TOTAL_FILES=$(find "$INPUT_DIR" -type f \( -iname "*.tif" -o -iname "*.tiff" \) | wc -l)

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "未找到任何 TIFF 文件进行处理"
    exit 0
fi

# 统计已完成的文件数
COMPLETED_FILES=0
while IFS= read -r -d '' input_file; do
    relative_path="${input_file#$INPUT_DIR/}"
    output_file="$OUTPUT_DIR/${relative_path%.*}.tif"
    if [ -f "$output_file" ]; then
        ((COMPLETED_FILES++))
    fi
done < <(find "$INPUT_DIR" -type f \( -iname "*.tif" -o -iname "*.tiff" \) -print0)

REMAINING_FILES=$((TOTAL_FILES - COMPLETED_FILES))

echo "找到 $TOTAL_FILES 个文件需要处理"
echo "已完成 $COMPLETED_FILES 个文件"
echo "剩余 $REMAINING_FILES 个文件需要处理"

if [ "$REMAINING_FILES" -eq 0 ]; then
    echo "所有文件已处理完成！"
    exit 0
fi

# 初始化进度计数器（从已完成的文件数开始）
rm -f /tmp/progress_counter
for ((i=1; i<=COMPLETED_FILES; i++)); do
    echo "1" >> /tmp/progress_counter
done

# 启动进度监控后台进程
(
    while [ ! -f /tmp/processing_done ]; do
        PROCESSED=$(wc -l < /tmp/progress_counter 2>/dev/null || echo "0")
        if [ "$PROCESSED" -gt 0 ]; then
            PERCENTAGE=$((PROCESSED * 100 / TOTAL_FILES))
            printf "\r进度: [%-50s] %d%% (%d/%d)" \
                $(printf '#%.0s' $(seq 1 $((PERCENTAGE / 2)))) \
                "$PERCENTAGE" "$PROCESSED" "$TOTAL_FILES"
        fi
        sleep 1
    done
    echo ""
) &

PROGRESS_PID=$!

# 并行处理文件
find "$INPUT_DIR" -type f \( -iname "*.tif" -o -iname "*.tiff" \) | \
parallel -j+0 process_image {}

# 标记处理完成
touch /tmp/processing_done

# 终止进度监控进程
kill $PROGRESS_PID 2>/dev/null || true

# 清理临时文件
rm -f /tmp/progress_counter /tmp/processing_done

echo "所有文件处理完成！"