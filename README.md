# TIFF 金字塔转换工具 / TIFF ピラミッド変換ツール

[简体中文](#zh-cn) | [日本語](#ja)

<a id="zh-cn"></a>

## 简体中文

### 项目简介

基于 Docker、libvips 和 GNU Parallel，批量将 TIFF 转换为使用 Deflate 无损压缩、256×256 瓦片的金字塔 TIFF。容器执行一次批处理，完成后退出。

- 递归查找 `.tif` / `.tiff` 文件，扩展名不区分大小写。
- 保留子目录结构，输出扩展名统一为 `.tif`。
- 使用 GNU Parallel 并行处理，支持直接处理和本地缓存两种模式。
- 以文件为单位续跑，再次运行时跳过已有输出。

例如：`input/slides/sample.tiff` → `output/slides/sample.tif`。

### 环境要求

- Docker Engine 和支持 `docker compose` 命令的 Compose。
- Windows 使用 Docker Desktop 的 Linux 容器环境。
- 首次构建需要访问 Docker 镜像仓库及 Alpine 软件包仓库。
- 为输入、输出和临时处理预留空间；脚本默认按至少 500 MB 可用空间选择工作目录，大图像需要更多空间。

镜像使用 Alpine Linux 3.22、libvips 8.16.1，并以 `vipsuser`（UID/GID 1000）运行。Linux 宿主机必须允许该用户读取输入、写入输出及日志挂载目录；镜像内的目录权限不会覆盖宿主机挂载权限。

### 快速开始

在仓库根目录执行首次配置；已有 `.env` 时跳过复制步骤。

Linux / macOS / WSL：

```bash
cp .env.example .env
mkdir -p input output logs
```

Windows PowerShell：

```powershell
Copy-Item .env.example .env
New-Item -ItemType Directory -Force -Path input, output, logs | Out-Null
```

Place TIFF files in `input/` and edit `.env`. Use direct mode for local storage, or enable caching for remote input storage:

```dotenv
USE_LOCAL_CACHE=false
```

`INPUT_FOLDER`、`OUTPUT_FOLDER` 和 `LOG_FOLDER` 应使用互不嵌套的独立目录。随后构建并运行：

```bash
docker compose config
docker compose up --build --exit-code-from image-processor
```

结果默认位于 `output/`。`--exit-code-from` 将批处理服务的退出码传回终端。修改输入后可再次运行相同命令；已有对应输出的文件会被跳过。

查看容器状态和运行日志：

```bash
docker compose ps -a
docker compose logs -f image-processor
```

### 配置说明

以下为 Compose 在未设置变量时的默认值；`.env` 可以覆盖这些值。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `INPUT_FOLDER` | `./input` | 宿主机输入目录，挂载至 `/app/input`，只读。 |
| `OUTPUT_FOLDER` | `./output` | 宿主机输出目录，挂载至 `/app/output`。 |
| `LOG_FOLDER` | `./logs` | 当前挂载至 `/tmp/logs`；任务日志位置尚未统一，见下文。 |
| `THREADS` | `4` | GNU Parallel 并行任务数；目前没有自动检测或上限校验。 |
| `USE_LOCAL_CACHE` | `true` | 是否启用本地缓存。脚本未设置该变量时默认 `false`，与 Compose 不同。 |
| `MAX_CACHE_FILES` | `20` | Maximum concurrent cached input files. Cached jobs use `min(THREADS, MAX_CACHE_FILES)`; direct mode uses `THREADS`. Both settings must be positive integers when used. |
| `MEMORY_LIMIT` | `2G` | 容器内存上限。 |
| `CPU_LIMIT` | `6.0` | 容器 CPU 配额，与并行任务数分别配置。 |
| `LOG_LEVEL` | `INFO` | `DEBUG` 增加调试信息；目前没有完整的日志级别过滤。 |
| `TZ` | `UTC` | 传入容器的时区变量；`.env.example` 中为 `Asia/Tokyo`。 |

Cached jobs use separate temporary directories and remove both cached input and output when each job finishes. They check free space on the actual cache filesystem; successful per-file checks appear only at `LOG_LEVEL=DEBUG`. Direct mode writes a temporary file in the output directory and renames it after conversion succeeds.

### 日志与已知限制

- 普通状态和错误消息通过 `docker compose logs` 查看。GNU Parallel 的任务记录默认写入容器内 `/app/logs/tiff_conversion.log`，当前不会自动保存到宿主机 `LOG_FOLDER`。需要保留时，应在删除或重建容器前使用 `docker cp` 导出到未挂载进容器的独立宿主机目录；当前未提供历史记录保留策略。
- 脚本会清理 `/tmp` 下超过 30 分钟的文件及空目录，可能影响 `/tmp/logs` 挂载中的宿主机文件。请勿将 `LOG_FOLDER` 用于长期归档，或让它包含输入、输出目录。
- In both modes, `sample.tif` and `sample.tiff` in the same input directory map to the same output path. Avoid this naming collision.
- 跳过逻辑基于输出文件是否存在，不验证其完整性；需要重做时，先确认并移走对应旧输出。
- 错误处理和健康检查仍待完善。待办事项见 [开发计划](DEVELOPMENT_PLAN.md)。

### 仓库结构与开发验证

| 文件 | 用途 |
| --- | --- |
| `process_images.sh` | 文件发现、并行转换、缓存和续跑检查。 |
| `dockerfile` | 容器镜像及运行用户配置，文件名为小写。 |
| `docker-compose.yaml` | 构建入口、目录挂载、环境变量和资源限制。 |
| `.env.example` | 本地配置示例。 |
| `DEVELOPMENT_PLAN.md` | 尚未完成的开发任务。 |
| `AGENTS.md` | 贡献与协作约定。 |

```bash
bash -n process_images.sh
docker compose config
docker compose build
```

当前没有自动化测试套件。修改转换流程后，应使用小型样例检查两种模式、嵌套目录、带空格文件名、已有输出、空输入及损坏文件，并检查输出像素、压缩、瓦片与金字塔属性。`input/`、`output/`、`logs/` 和 `.env` 均不纳入 Git。

---

<a id="ja"></a>

## 日本語

### 概要

Docker、libvips、GNU Parallel を使用し、TIFF を Deflate による可逆圧縮、256×256 ピクセルのタイルを持つピラミッド TIFF に一括変換します。コンテナーはバッチ処理を実行し、完了すると終了します。

- `.tif` / `.tiff` を再帰的に検索します。拡張子の大文字・小文字は区別しません。
- サブディレクトリー構造を維持し、出力の拡張子を `.tif` に統一します。
- GNU Parallel による並列処理に対応し、直接処理とローカルキャッシュを選択できます。
- 再実行はファイル単位で行い、既存の出力をスキップします。

例：`input/slides/sample.tiff` → `output/slides/sample.tif`。

### 動作環境

- Docker Engine と、`docker compose` コマンドを利用できる Compose。
- Windows では Docker Desktop の Linux コンテナー環境を使用します。
- 初回ビルド時は Docker イメージレジストリーと Alpine パッケージリポジトリーへの接続が必要です。
- 入力、出力、一時処理用の空き容量を確保してください。スクリプトは既定で 500 MB 以上の空き容量を基準に作業ディレクトリーを選択します。大きな画像には追加の容量が必要です。

イメージは Alpine Linux 3.22、libvips 8.16.1 を使用し、`vipsuser`（UID/GID 1000）で実行されます。Linux ホストでは、このユーザーが入力を読み取り、出力とログのマウント先へ書き込める必要があります。イメージ内の権限設定でホスト側のマウント権限は変更されません。

### クイックスタート

リポジトリーのルートで初期設定を行います。既存の `.env` がある場合はコピーを省略してください。

Linux / macOS / WSL：

```bash
cp .env.example .env
mkdir -p input output logs
```

Windows PowerShell：

```powershell
Copy-Item .env.example .env
New-Item -ItemType Directory -Force -Path input, output, logs | Out-Null
```

Place TIFF files in `input/` and edit `.env`. Use direct mode for local storage, or enable caching for remote input storage:

```dotenv
USE_LOCAL_CACHE=false
```

`INPUT_FOLDER`、`OUTPUT_FOLDER`、`LOG_FOLDER` には、互いに入れ子にならない独立したディレクトリーを指定してください。その後、ビルドして実行します。

```bash
docker compose config
docker compose up --build --exit-code-from image-processor
```

結果は既定で `output/` に保存されます。`--exit-code-from` により、バッチ処理サービスの終了コードが端末に返されます。入力を変更した後も同じコマンドで再実行できます。対応する出力が既に存在するファイルはスキップされます。

コンテナーの状態と実行ログを確認するには、次のコマンドを使用します。

```bash
docker compose ps -a
docker compose logs -f image-processor
```

### 設定

以下は、変数が未設定の場合に Compose が使用する既定値です。`.env` で変更できます。

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `INPUT_FOLDER` | `./input` | ホストの入力ディレクトリー。`/app/input` に読み取り専用でマウントします。 |
| `OUTPUT_FOLDER` | `./output` | ホストの出力ディレクトリー。`/app/output` にマウントします。 |
| `LOG_FOLDER` | `./logs` | 現在は `/tmp/logs` にマウントします。ジョブログの保存先とは未統一です。 |
| `THREADS` | `4` | GNU Parallel の並列ジョブ数。自動検出や上限の検証は未実装です。 |
| `USE_LOCAL_CACHE` | `true` | ローカルキャッシュの有効・無効。スクリプトでは未設定時に `false` となり、Compose と異なります。 |
| `MAX_CACHE_FILES` | `20` | Maximum concurrent cached input files. Cached jobs use `min(THREADS, MAX_CACHE_FILES)`; direct mode uses `THREADS`. Both settings must be positive integers when used. |
| `MEMORY_LIMIT` | `2G` | コンテナーのメモリー上限。 |
| `CPU_LIMIT` | `6.0` | コンテナーの CPU 割り当て上限。並列ジョブ数とは別に設定します。 |
| `LOG_LEVEL` | `INFO` | `DEBUG` で詳細情報を追加します。ログレベルによる完全なフィルタリングは未実装です。 |
| `TZ` | `UTC` | コンテナーに渡すタイムゾーン変数。`.env.example` では `Asia/Tokyo` です。 |

Cached jobs use separate temporary directories and remove both cached input and output when each job finishes. They check free space on the actual cache filesystem; successful per-file checks appear only at `LOG_LEVEL=DEBUG`. Direct mode writes a temporary file in the output directory and renames it after conversion succeeds.

### ログと既知の制約

- 通常の状態メッセージとエラーは `docker compose logs` で確認できます。GNU Parallel のジョブログは、既定でコンテナー内の `/app/logs/tiff_conversion.log` に保存され、現在はホストの `LOG_FOLDER` に自動保存されません。保存が必要な場合は、コンテナーを削除・再作成する前に `docker cp` でコンテナーにマウントしていない独立したホストディレクトリーへコピーしてください。履歴の保持ポリシーは未実装です。
- スクリプトは `/tmp` 配下の更新から 30 分を超えたファイルと空ディレクトリーを削除します。`/tmp/logs` にマウントされたホスト側のファイルも影響を受ける可能性があります。`LOG_FOLDER` を長期保管に使用したり、その配下に入力・出力ディレクトリーを置いたりしないでください。
- In both modes, `sample.tif` and `sample.tiff` in the same input directory map to the same output path. Avoid this naming collision.
- スキップ判定では出力ファイルの存在のみを確認し、完全性は検証しません。再変換する場合は、該当する既存出力を確認してから別の場所へ移動してください。
- エラー処理とヘルスチェックの改善は継続中です。未完了の作業は [開発計画](DEVELOPMENT_PLAN.md) を参照してください。

### ファイル構成と開発時の検証

| ファイル | 用途 |
| --- | --- |
| `process_images.sh` | ファイル検索、並列変換、キャッシュ、再実行時の判定。 |
| `dockerfile` | イメージと実行ユーザーの設定。ファイル名は小文字です。 |
| `docker-compose.yaml` | ビルド設定、マウント、環境変数、リソース制限。 |
| `.env.example` | ローカル設定の例。 |
| `DEVELOPMENT_PLAN.md` | 未完了の開発タスク。 |
| `AGENTS.md` | コントリビューションと共同作業のガイド。 |

```bash
bash -n process_images.sh
docker compose config
docker compose build
```

自動テストスイートはまだありません。変換処理を変更した場合は、小さなサンプルで両モード、入れ子のディレクトリー、空白を含むファイル名、既存出力、入力なし、破損ファイルを確認し、出力の画素値、圧縮、タイル、ピラミッド構造を検証してください。`input/`、`output/`、`logs/`、`.env` は Git の管理対象外です。
