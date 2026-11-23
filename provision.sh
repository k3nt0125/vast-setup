#!/bin/bash
# =============================================================
# Vast.ai ComfyUI 自動セットアップスクリプト（WAN 2.2 動画生成用）
# 使い方：
#   1. このファイルを GitHub に置き、Raw の URL を取得
#   2. Vast.ai のテンプレート環境変数 PROVISIONING_SCRIPT にその URL を設定
#   3. トークンはスクリプトに書かず、テンプレートの環境変数で渡す
#        CIVITAI_TOKEN=xxx      （Civitai の LoRA を使う場合のみ）
#
# 先頭に # が付いた行は無視されます。使いたい行は # を消してください。
# =============================================================

set -u
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="${WORKSPACE}/ComfyUI"
MODELS="${COMFY}/models"
WAN="https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files"

# ---------- ここを自分用に書き換える ----------

# 動画モデル本体（WAN 2.2 14B は「high」と「low」の2つで1セット）
DIFFUSION_MODELS=(
  # 文章から動画（T2V）
  "wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors|${WAN}/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"
  "wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors|${WAN}/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"

  # 画像から動画（I2V）も使うなら下の2行の # を消す
  # "wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors|${WAN}/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
  # "wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors|${WAN}/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
)

# 文章を読み取る部品（必須）
TEXT_ENCODERS=(
  "umt5_xxl_fp8_e4m3fn_scaled.safetensors|${WAN}/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
)

# 映像に変換する部品（必須）
VAES=(
  "wan_2.1_vae.safetensors|${WAN}/vae/wan_2.1_vae.safetensors"
)

# LoRA（追加の味付け。高速化用や Civitai のものなど）
LORAS=(
  # 高速化（4ステップ生成、T2V用。2つで1セット）
  # "wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors|${WAN}/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"
  # "wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors|${WAN}/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"

  # Civitai の例（数字はモデルページの modelVersionId）
  # "my_lora.safetensors|https://civitai.com/api/download/models/234567"
)

# 追加したいカスタムノード（GitHub の URL）
CUSTOM_NODES=(
  # "https://github.com/ltdrdata/ComfyUI-Manager"
)

# ---------- ここから下は基本的に触らなくてOK ----------

download() {
  local dir="$1" name="$2" url="$3"
  local dest="${dir}/${name}"
  mkdir -p "$dir"

  if [ -s "$dest" ]; then
    echo "[skip] ${name} は既にあります"
    return
  fi

  local auth=()
  if [[ "$url" == *huggingface.co* && -n "${HF_TOKEN:-}" ]]; then
    auth=(--header="Authorization: Bearer ${HF_TOKEN}")
  elif [[ "$url" == *civitai.com* && -n "${CIVITAI_TOKEN:-}" ]]; then
    auth=(--header="Authorization: Bearer ${CIVITAI_TOKEN}")
  fi

  echo "[download] ${name}"
  if wget -q --show-progress "${auth[@]}" -O "${dest}.part" "$url"; then
    mv "${dest}.part" "$dest"
  else
    echo "[error] ${name} の取得に失敗しました: ${url}"
    rm -f "${dest}.part"
  fi
}

fetch_list() {
  local dir="$1"; shift
  for entry in "$@"; do
    download "$dir" "${entry%%|*}" "${entry#*|}"
  done
}

[ -f /venv/main/bin/activate ] && source /venv/main/bin/activate

for repo in "${CUSTOM_NODES[@]}"; do
  name="$(basename "$repo" .git)"
  path="${COMFY}/custom_nodes/${name}"
  if [ -d "$path" ]; then
    echo "[skip] ${name} は既にあります"
  else
    echo "[clone] ${name}"
    git clone --depth 1 "$repo" "$path"
    [ -f "${path}/requirements.txt" ] && pip install -q -r "${path}/requirements.txt"
  fi
done

fetch_list "${MODELS}/text_encoders"    "${TEXT_ENCODERS[@]}"
fetch_list "${MODELS}/vae"              "${VAES[@]}"
fetch_list "${MODELS}/loras"            "${LORAS[@]}"
fetch_list "${MODELS}/diffusion_models" "${DIFFUSION_MODELS[@]}"

echo "=== セットアップ完了 ==="
