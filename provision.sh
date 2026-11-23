#!/bin/bash
# =============================================================
# Vast.ai ComfyUI 自動セットアップスクリプト（WAN 2.2 + 画像生成 + NAS自動送信）
#
# Vast.ai テンプレートの環境変数（Environment Variables）に入れるもの：
#   PROVISIONING_SCRIPT = このファイルの Raw URL
#   CIVITAI_TOKEN       = Civitai の APIキー
#   ST_CERT             = Syncthing の身分証（cert）     ※NAS自動送信を使う場合
#   ST_KEY              = Syncthing の身分証（key）      ※NAS自動送信を使う場合
#   ST_DEVICE_ID        = このマシン用のSyncthing ID     ※NAS自動送信を使う場合
#   NAS_DEVICE_ID       = NAS のSyncthing ID             ※NAS自動送信を使う場合
#
# 鍵や身分証はこのファイルに書かないこと（GitHubは公開されています）。
# 先頭に # が付いた行は無視されます。使いたい行は # を消してください。
# =============================================================

set -u
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="${WORKSPACE}/ComfyUI"
MODELS="${COMFY}/models"
WAN="https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files"

# ---------- ここを自分用に書き換える ----------

# WAN 動画モデル本体（high と low で1セット）
DIFFUSION_MODELS=(
  "wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors|${WAN}/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"
  "wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors|${WAN}/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"
  # 画像から動画（I2V）も使うなら下の2行の # を消す
  # "wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors|${WAN}/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
  # "wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors|${WAN}/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
)

TEXT_ENCODERS=(
  "umt5_xxl_fp8_e4m3fn_scaled.safetensors|${WAN}/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
)

VAES=(
  "wan_2.1_vae.safetensors|${WAN}/vae/wan_2.1_vae.safetensors"
)

# 画像生成用の本体モデル（Civitai のダウンロードリンクを入れる）
CHECKPOINTS=(
  # "my_illustrious_model.safetensors|https://civitai.red/api/download/models/番号"
)

# LoRA
LORAS=(
  # WAN 高速化（4ステップ）
  "wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors|${WAN}/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"
  "wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors|${WAN}/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"
  # WAN 用 Foot Focus
  "wan_foot_focus_missionary.safetensors|https://civitai.red/api/download/models/1610463?fileId=1510560"
  # 画像用（Illustrious）LoRA の例
  # "pressed_missionary_illustrious.safetensors|https://civitai.red/api/download/models/番号"
)

CUSTOM_NODES=(
  # "https://github.com/ltdrdata/ComfyUI-Manager"
)

# NAS に送るフォルダ（ここに移したファイルだけが NAS に届く）
NAS_FOLDER="${COMFY}/output/nas"
NAS_FOLDER_ID="comfy-nas"

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
    auth=(-H "Authorization: Bearer ${HF_TOKEN}")
  elif [[ "$url" == *civitai.* && -n "${CIVITAI_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer ${CIVITAI_TOKEN}")
  fi

  # curl は転送先（別のサーバー）に鍵を渡さないので、Civitai の保存先で 400 エラーにならない
  echo "[download] ${name}"
  if curl -L --fail -sS "${auth[@]}" -o "${dest}.part" "$url"; then
    # 1MB 未満はエラーページの可能性が高い
    if [ "$(stat -c %s "${dest}.part")" -lt 1000000 ]; then
      echo "[error] ${name} が小さすぎます（失敗の可能性）: ${url}"
      rm -f "${dest}.part"
    else
      mv "${dest}.part" "$dest"
    fi
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

setup_nas_sync() {
  if [ -z "${ST_CERT:-}" ] || [ -z "${ST_KEY:-}" ] || [ -z "${ST_DEVICE_ID:-}" ] || [ -z "${NAS_DEVICE_ID:-}" ]; then
    echo "[nas] 設定が足りないので NAS 自動送信はスキップします"
    return
  fi

  local st
  st="$(command -v syncthing || find / -xdev -type f -name syncthing -perm -u+x 2>/dev/null | head -1)"
  if [ -z "$st" ]; then
    echo "[error] Syncthing が見つかりません"
    return
  fi

  local home="${WORKSPACE}/.st-nas"
  mkdir -p "$home" "$NAS_FOLDER"
  echo "$ST_CERT" | base64 -d > "${home}/cert.pem"
  echo "$ST_KEY"  | base64 -d > "${home}/key.pem"
  chmod 600 "${home}/key.pem"

  cat > "${home}/config.xml" << XML
<configuration version="37">
  <folder id="${NAS_FOLDER_ID}" label="${NAS_FOLDER_ID}" path="${NAS_FOLDER}" type="sendonly" rescanIntervalS="60" fsWatcherEnabled="true">
    <device id="${ST_DEVICE_ID}"></device>
    <device id="${NAS_DEVICE_ID}"></device>
  </folder>
  <device id="${ST_DEVICE_ID}" name="vast-comfy"><address>dynamic</address></device>
  <device id="${NAS_DEVICE_ID}" name="nas"><address>dynamic</address></device>
  <gui enabled="false"></gui>
  <options>
    <listenAddress>tcp://0.0.0.0:22001</listenAddress>
    <listenAddress>quic://0.0.0.0:22001</listenAddress>
    <listenAddress>dynamic+https://relays.syncthing.net/endpoint</listenAddress>
    <globalAnnounceEnabled>true</globalAnnounceEnabled>
    <localAnnounceEnabled>false</localAnnounceEnabled>
    <relaysEnabled>true</relaysEnabled>
    <startBrowser>false</startBrowser>
    <urAccepted>-1</urAccepted>
  </options>
</configuration>
XML

  echo "[nas] NAS 送信用の Syncthing を起動します（送信フォルダ: ${NAS_FOLDER}）"
  setsid nohup "$st" serve --home="$home" --no-browser > "${WORKSPACE}/st-nas.log" 2>&1 < /dev/null &
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

# NAS 送信は先に起動しておく（ダウンロード中でも使えるように）
setup_nas_sync

fetch_list "${MODELS}/text_encoders"    "${TEXT_ENCODERS[@]}"
fetch_list "${MODELS}/vae"              "${VAES[@]}"
fetch_list "${MODELS}/loras"            "${LORAS[@]}"
fetch_list "${MODELS}/checkpoints"      "${CHECKPOINTS[@]}"
fetch_list "${MODELS}/diffusion_models" "${DIFFUSION_MODELS[@]}"

echo "=== セットアップ完了 ==="
