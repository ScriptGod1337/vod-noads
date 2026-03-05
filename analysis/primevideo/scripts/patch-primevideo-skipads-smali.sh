#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
}

usage() {
  cat <<'EOF'
Usage:
  patch-primevideo-skipads-smali.sh <input.apk> [output.apk] [options]

Patches Prime Video by injecting smali directly (no ReVanced CLI required).
This is Prime-specific, but can be used as a template for other smali patches.

Options:
  --keystore <path>     Use a custom keystore for signing.
  --ks-alias <alias>    Key alias in the custom keystore.
  --ks-pass <password>  Keystore password.
  --key-pass <password> Key password.
  -h, --help            Show this help.

Notes:
  - If no keystore options are provided, default uber-apk-signer debug signing is used.
  - This script modifies the decompiled smali and rebuilds a new APK; it never edits the input APK in place.
  - WARNING: apktool rebuilds/reassembles a lot of content. For some apps this can cause instability.
    Prefer patch-primevideo-skipads-dex.sh which only rewrites the single classesN.dex that contains the
    patched class.
EOF
}

if [[ "${1:-}" == "" ]]; then
  usage
  exit 1
fi

POSITIONAL=()
KS_PATH=""
KS_ALIAS=""
KS_PASS=""
KEY_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keystore)
      [[ "${2:-}" != "" ]] || fail "--keystore requires a path"
      KS_PATH="$2"
      shift 2
      ;;
    --ks-alias)
      [[ "${2:-}" != "" ]] || fail "--ks-alias requires a value"
      KS_ALIAS="$2"
      shift 2
      ;;
    --ks-pass)
      [[ "${2:-}" != "" ]] || fail "--ks-pass requires a value"
      KS_PASS="$2"
      shift 2
      ;;
    --key-pass)
      [[ "${2:-}" != "" ]] || fail "--key-pass requires a value"
      KEY_PASS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "Unknown option: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

(( ${#POSITIONAL[@]} >= 1 && ${#POSITIONAL[@]} <= 2 )) || fail "Expected <input.apk> [output.apk]."

INPUT_APK="${POSITIONAL[0]}"
[[ -f "$INPUT_APK" ]] || fail "Input APK not found: $INPUT_APK"

if [[ "${POSITIONAL[1]:-}" != "" ]]; then
  OUTPUT_APK="${POSITIONAL[1]}"
else
  base_name="$(basename "$INPUT_APK" .apk)"
  output_dir="$(dirname "$INPUT_APK")"
  OUTPUT_APK="${output_dir}/${base_name}-skipads-patched-smali.apk"
fi

if [[ "$KS_PATH" != "" ]]; then
  [[ -f "$KS_PATH" ]] || fail "Keystore file not found: $KS_PATH"
  [[ "$KS_ALIAS" != "" ]] || fail "--ks-alias is required when --keystore is used"
fi

require_cmd java
require_cmd rg
require_cmd awk
require_cmd curl
require_cmd find

TOOLS_DIR="/tmp/primevideo-skipads-smali-tools"
APKTOOL_JAR="${TOOLS_DIR}/apktool.jar"
UBER_SIGNER_JAR="${TOOLS_DIR}/uber-apk-signer.jar"
APKTOOL_FRAMEWORK_DIR="/tmp/apktool-framework"

mkdir -p "$TOOLS_DIR" "$APKTOOL_FRAMEWORK_DIR"

if [[ ! -f "$APKTOOL_JAR" ]]; then
  curl -L -o "$APKTOOL_JAR" \
    "https://github.com/iBotPeaches/Apktool/releases/download/v2.11.1/apktool_2.11.1.jar"
fi

if [[ ! -f "$UBER_SIGNER_JAR" ]]; then
  curl -L -o "$UBER_SIGNER_JAR" \
    "https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/uber-apk-signer-1.3.0.jar"
fi

WORK_DIR="$(mktemp -d /tmp/primevideo-skipads-smali-XXXXXX)"
APP_DIR="${WORK_DIR}/app"
UNSIGNED_APK="${WORK_DIR}/unsigned.apk"
SIGNED_DIR="${WORK_DIR}/signed"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[1/5] Decompiling APK"
if ! java -jar "$APKTOOL_JAR" d -f -r -q -p "$APKTOOL_FRAMEWORK_DIR" "$INPUT_APK" -o "$APP_DIR" >/dev/null 2>"${WORK_DIR}/apktool-decode.err"; then
  echo "apktool decode failed; last 80 lines:" >&2
  tail -n 80 "${WORK_DIR}/apktool-decode.err" >&2 || true
  fail "apktool decode failed"
fi

SERVER_SMALI="$(find "$APP_DIR" -type f -name 'ServerInsertedAdBreakState.smali' -print -quit)"
[[ "$SERVER_SMALI" != "" ]] || fail "Could not find ServerInsertedAdBreakState.smali in decompiled APK."

check_path() {
  local rel="$1"
  local path
  path="$(find "$APP_DIR" -type f -path "*/$rel" -print -quit)"
  [[ "$path" != "" ]] || fail "Required class not found for path suffix: $rel"
  echo "$path"
}

check_contains() {
  local file="$1"
  local pattern="$2"
  rg -q "$pattern" "$file" || fail "Required symbol missing in $file: $pattern"
}

ADBREAK_TRIGGER_SMALI="$(check_path 'com/amazon/avod/media/ads/internal/state/AdBreakTrigger.smali')"
ADBREAK_SMALI="$(check_path 'com/amazon/avod/media/ads/AdBreak.smali')"
VIDEO_PLAYER_SMALI="$(check_path 'com/amazon/avod/media/playback/VideoPlayer.smali')"
TIMESPAN_SMALI="$(check_path 'com/amazon/avod/media/TimeSpan.smali')"
STATEBASE_SMALI="$(check_path 'com/amazon/avod/fsm/StateBase.smali')"
SIMPLETRIGGER_SMALI="$(check_path 'com/amazon/avod/fsm/SimpleTrigger.smali')"
AD_TRIGGER_TYPE_SMALI="$(check_path 'com/amazon/avod/media/ads/internal/state/AdEnabledPlayerTriggerType.smali')"

check_contains "$ADBREAK_TRIGGER_SMALI" '\.method .*getSeekStartPosition\(\)Lcom/amazon/avod/media/TimeSpan;'
check_contains "$ADBREAK_TRIGGER_SMALI" '\.method .*getSeekTarget\(\)Lcom/amazon/avod/media/TimeSpan;'
check_contains "$ADBREAK_SMALI" '\.method .*getDurationExcludingAux\(\)Lcom/amazon/avod/media/TimeSpan;'
check_contains "$VIDEO_PLAYER_SMALI" '\.method .*getCurrentPosition\(\)J'
check_contains "$VIDEO_PLAYER_SMALI" '\.method .*seekTo\(J\)V'
check_contains "$TIMESPAN_SMALI" '\.method .*getTotalMilliseconds\(\)J'
check_contains "$STATEBASE_SMALI" '\.method .*doTrigger\(Lcom/amazon/avod/fsm/Trigger;\)V'
check_contains "$SIMPLETRIGGER_SMALI" '\.method .* constructor <init>\(Ljava/lang/Object;\)V'
check_contains "$AD_TRIGGER_TYPE_SMALI" 'NO_MORE_ADS_SKIP_TRANSITION'

ENTER_METHOD_COUNT="$(
  awk '
    $0 == ".method public enter(Lcom/amazon/avod/fsm/Trigger;)V" { c++ }
    END { print c + 0 }
  ' "$SERVER_SMALI"
)"
[[ "$ENTER_METHOD_COUNT" == "1" ]] || fail "Expected exactly one enter(Trigger) method in $SERVER_SMALI, found: $ENTER_METHOD_COUNT"

LOCALS_COUNT="$(
  awk '
    BEGIN { in_method=0 }
    $0 == ".method public enter(Lcom/amazon/avod/fsm/Trigger;)V" { in_method=1; next }
    in_method && /^[[:space:]]*\.locals[[:space:]]+[0-9]+/ {
      match($0, /[0-9]+/)
      print substr($0, RSTART, RLENGTH)
      exit
    }
    in_method && $0 == ".end method" { exit }
  ' "$SERVER_SMALI"
)"
[[ "$LOCALS_COUNT" != "" ]] || fail "Could not detect .locals for enter(Trigger) in $SERVER_SMALI"
(( LOCALS_COUNT >= 7 )) || fail "enter(Trigger) has only .locals $LOCALS_COUNT; need at least 7 for safe injection"

VIDEO_PLAYER_INVOKE="invoke-virtual"
if rg -q '^\\.class .*\\binterface\\b' "$VIDEO_PLAYER_SMALI"; then
  VIDEO_PLAYER_INVOKE="invoke-interface"
fi

ANCHOR_STATE="$(
  awk '
    BEGIN { in_method=0; saw_get_primary=0; saw_move_result=0 }
    $0 == ".method public enter(Lcom/amazon/avod/fsm/Trigger;)V" { in_method=1; next }
    in_method && index($0, "getPrimaryPlayer()Lcom/amazon/avod/media/playback/VideoPlayer;") > 0 && saw_get_primary == 0 {
      saw_get_primary=1
      next
    }
    in_method && saw_get_primary && saw_move_result == 0 && /move-result-object v[0-9]+/ {
      saw_move_result=1
      next
    }
    in_method && saw_move_result && $0 ~ /^[[:space:]]*$/ { next }
    in_method && saw_move_result {
      if (index($0, ":rvd_skip_ads_original") > 0 || index($0, "getSeekStartPosition()Lcom/amazon/avod/media/TimeSpan;") > 0) print "patched"
      else if (index($0, "Lapp/revanced/extension/primevideo/ads/SkipAdsPatch;->enterServerInsertedAdBreakState") > 0) print "patched"
      else if ($0 ~ /const\/4 /) print "clean"
      else print "incompatible"
      exit
    }
    in_method && $0 == ".end method" { exit }
  ' "$SERVER_SMALI"
)"

[[ "$ANCHOR_STATE" != "" ]] || fail "Could not classify anchor state in enter(Trigger) for $SERVER_SMALI"
if [[ "$ANCHOR_STATE" == "patched" ]]; then
  fail "APK appears already patched at injection anchor. Refusing to patch again."
fi
if [[ "$ANCHOR_STATE" != "clean" ]]; then
  fail "APK is incompatible at injection anchor (state: $ANCHOR_STATE)."
fi

PLAYER_REGISTER="$(
  awk '
    BEGIN { in_method=0; saw_get_primary=0 }
    $0 == ".method public enter(Lcom/amazon/avod/fsm/Trigger;)V" { in_method=1; next }
    in_method && index($0, "getPrimaryPlayer()Lcom/amazon/avod/media/playback/VideoPlayer;") > 0 { saw_get_primary=1; next }
    in_method && saw_get_primary && /move-result-object v[0-9]+/ {
      match($0, /v[0-9]+/)
      print substr($0, RSTART, RLENGTH)
      exit
    }
    in_method && $0 == ".end method" { in_method=0; saw_get_primary=0 }
  ' "$SERVER_SMALI"
)"
[[ "$PLAYER_REGISTER" != "" ]] || fail "Could not detect primary player register in: $SERVER_SMALI"

echo "[2/5] Injecting skip-ads smali into ServerInsertedAdBreakState.enter()"
TMP_SMALI="${SERVER_SMALI}.tmp"
awk -v reg="$PLAYER_REGISTER" -v player_invoke="$VIDEO_PLAYER_INVOKE" '
  BEGIN { in_method=0; saw_get_primary=0; inserted=0 }
  {
    print
    if ($0 == ".method public enter(Lcom/amazon/avod/fsm/Trigger;)V") {
      in_method=1
      next
    }
    if (in_method && index($0, "getPrimaryPlayer()Lcom/amazon/avod/media/playback/VideoPlayer;") > 0 && inserted == 0) {
      saw_get_primary=1
      next
    }
    if (in_method && saw_get_primary && $0 ~ /^[[:space:]]*move-result-object v[0-9]+/ && inserted == 0) {
      print ""
      # Important: match the working ReVanced patch behavior:
      # always exit enter() after our attempt (even if it fails), never fall back to the original method body.
      print "    if-eqz p1, :rvd_skip_ads_return"
      print "    if-eqz " reg ", :rvd_skip_ads_return"
      print ""
      print "    :rvd_try_start"
      print "    invoke-virtual {p1}, Lcom/amazon/avod/media/ads/internal/state/AdBreakTrigger;->getBreak()Lcom/amazon/avod/media/ads/AdBreak;"
      print "    move-result-object v1"
      print ""
      print "    invoke-virtual {p1}, Lcom/amazon/avod/media/ads/internal/state/AdBreakTrigger;->getSeekStartPosition()Lcom/amazon/avod/media/TimeSpan;"
      print "    move-result-object v2"
      print ""
      print "    if-eqz v2, :rvd_skip_ads_normal"
      print ""
      print "    invoke-virtual {p1}, Lcom/amazon/avod/media/ads/internal/state/AdBreakTrigger;->getSeekTarget()Lcom/amazon/avod/media/TimeSpan;"
      print "    move-result-object v2"
      print "    invoke-virtual {v2}, Lcom/amazon/avod/media/TimeSpan;->getTotalMilliseconds()J"
      print "    move-result-wide v3"
      print "    " player_invoke " {" reg ", v3, v4}, Lcom/amazon/avod/media/playback/VideoPlayer;->seekTo(J)V"
      print ""
      print "    goto :rvd_skip_ads_done"
      print ""
      print "    :rvd_skip_ads_normal"
      print "    " player_invoke " {" reg "}, Lcom/amazon/avod/media/playback/VideoPlayer;->getCurrentPosition()J"
      print "    move-result-wide v3"
      print "    invoke-interface {v1}, Lcom/amazon/avod/media/ads/AdBreak;->getDurationExcludingAux()Lcom/amazon/avod/media/TimeSpan;"
      print "    move-result-object v2"
      print "    invoke-virtual {v2}, Lcom/amazon/avod/media/TimeSpan;->getTotalMilliseconds()J"
      print "    move-result-wide v5"
      print "    add-long/2addr v3, v5"
      print "    " player_invoke " {" reg ", v3, v4}, Lcom/amazon/avod/media/playback/VideoPlayer;->seekTo(J)V"
      print ""
      print "    :rvd_skip_ads_done"
      print "    new-instance v1, Lcom/amazon/avod/fsm/SimpleTrigger;"
      print "    sget-object v2, Lcom/amazon/avod/media/ads/internal/state/AdEnabledPlayerTriggerType;->NO_MORE_ADS_SKIP_TRANSITION:Lcom/amazon/avod/media/ads/internal/state/AdEnabledPlayerTriggerType;"
      print "    invoke-direct {v1, v2}, Lcom/amazon/avod/fsm/SimpleTrigger;-><init>(Ljava/lang/Object;)V"
      print "    invoke-virtual {p0, v1}, Lcom/amazon/avod/fsm/StateBase;->doTrigger(Lcom/amazon/avod/fsm/Trigger;)V"
      print "    :rvd_try_end"
      print "    goto :rvd_skip_ads_return"
      print ""
      print "    .catch Ljava/lang/Exception; {:rvd_try_start .. :rvd_try_end} :rvd_skip_ads_return"
      print ""
      print "    :rvd_skip_ads_return"
      print "    return-void"
      print ""
      print "    :rvd_skip_ads_original"
      inserted=1
      saw_get_primary=0
    }
    if (in_method && $0 == ".end method") {
      in_method=0
      saw_get_primary=0
    }
  }
  END {
    if (inserted == 0) exit 42
  }
' "$SERVER_SMALI" > "$TMP_SMALI" || fail "Failed to inject skip-ads code into $SERVER_SMALI"
mv "$TMP_SMALI" "$SERVER_SMALI"

POST_OK="0"
if rg -q ':rvd_skip_ads_return' "$SERVER_SMALI" && rg -q 'NO_MORE_ADS_SKIP_TRANSITION' "$SERVER_SMALI"; then
  POST_OK="1"
fi
[[ "$POST_OK" == "1" ]] || fail "Post-injection verification failed."

echo "[3/5] Rebuilding APK"
if ! java -jar "$APKTOOL_JAR" b -q -p "$APKTOOL_FRAMEWORK_DIR" "$APP_DIR" -o "$UNSIGNED_APK" >/dev/null 2>"${WORK_DIR}/apktool-build.err"; then
  echo "apktool build failed; last 120 lines:" >&2
  tail -n 120 "${WORK_DIR}/apktool-build.err" >&2 || true
  fail "apktool build failed"
fi

echo "[4/5] Signing APK"
mkdir -p "$SIGNED_DIR"
SIGN_CMD=(java -jar "$UBER_SIGNER_JAR" -a "$UNSIGNED_APK" --allowResign -o "$SIGNED_DIR")
if [[ "$KS_PATH" != "" ]]; then
  SIGN_CMD+=(--ks "$KS_PATH" --ksAlias "$KS_ALIAS")
  if [[ "$KS_PASS" != "" ]]; then
    SIGN_CMD+=(--ksPass "$KS_PASS")
  fi
  if [[ "$KEY_PASS" != "" ]]; then
    SIGN_CMD+=(--ksKeyPass "$KEY_PASS")
  fi
fi
if ! "${SIGN_CMD[@]}" >/dev/null 2>"${WORK_DIR}/sign.err"; then
  echo "signing failed; last 120 lines:" >&2
  tail -n 120 "${WORK_DIR}/sign.err" >&2 || true
  fail "signing failed"
fi

SIGNED_APK="$(find "$SIGNED_DIR" -maxdepth 1 -type f -name "*.apk" ! -name "*.idsig" | head -n 1)"
[[ "$SIGNED_APK" != "" ]] || fail "Signing finished but no output APK was found."

echo "[5/5] Writing output"
mkdir -p "$(dirname "$OUTPUT_APK")"
cp -f "$SIGNED_APK" "$OUTPUT_APK"

echo "Patched APK created: $OUTPUT_APK"
