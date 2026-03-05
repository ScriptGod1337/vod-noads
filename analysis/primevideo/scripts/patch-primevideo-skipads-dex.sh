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
  patch-primevideo-skipads-dex.sh <input.apk> [output.apk] [options]

Patches Prime Video by editing exactly one classesN.dex (no apktool rebuild of the whole APK).
This is usually much less fragile than apktool round-tripping all dex/resources.

Options:
  --keystore <path>     Use a custom keystore for signing.
  --ks-alias <alias>    Key alias in the custom keystore.
  --ks-pass <password>  Keystore password.
  --key-pass <password> Key password.
  -h, --help            Show this help.

Notes:
  - If no keystore options are provided, default uber-apk-signer debug signing is used.
  - The input APK is never modified in place.
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
  OUTPUT_APK="${output_dir}/${base_name}-skipads-patched-dex.apk"
fi

if [[ "$KS_PATH" != "" ]]; then
  [[ -f "$KS_PATH" ]] || fail "Keystore file not found: $KS_PATH"
  [[ "$KS_ALIAS" != "" ]] || fail "--ks-alias is required when --keystore is used"
fi

require_cmd java
require_cmd rg
require_cmd awk
require_cmd curl
require_cmd unzip
require_cmd zip
require_cmd find
require_cmd jar

TOOLS_DIR="/tmp/primevideo-skipads-dex-tools"
BAKSMALI_JAR="${TOOLS_DIR}/baksmali.jar"
SMALI_JAR="${TOOLS_DIR}/smali.jar"
UBER_SIGNER_JAR="${TOOLS_DIR}/uber-apk-signer.jar"

mkdir -p "$TOOLS_DIR"

# Prefer already-present jars in this workspace (no network dependency).
if [[ ! -f "$BAKSMALI_JAR" ]]; then
  if [[ -f "/tmp/android-sdk/cmdline-tools/latest/lib/external/com/android/tools/smali/smali-baksmali/3.0.3/smali-baksmali-3.0.3.jar" ]]; then
    ln -sf "/tmp/android-sdk/cmdline-tools/latest/lib/external/com/android/tools/smali/smali-baksmali/3.0.3/smali-baksmali-3.0.3.jar" "$BAKSMALI_JAR"
  fi
fi

if [[ ! -f "$SMALI_JAR" ]]; then
  smali_candidate="$(
    find /tmp/gradle-home-revanced-patches/caches/modules-2/files-2.1/com.android.tools.smali/smali -type f -name 'smali-*.jar' 2>/dev/null | sort -V | tail -n 1
  )"
  if [[ "$smali_candidate" != "" ]] && [[ -f "$smali_candidate" ]]; then
    ln -sf "$smali_candidate" "$SMALI_JAR"
  fi
fi

if [[ ! -f "$UBER_SIGNER_JAR" ]]; then
  if [[ -f "/tmp/primevideo-skipads-smali-tools/uber-apk-signer.jar" ]]; then
    ln -sf "/tmp/primevideo-skipads-smali-tools/uber-apk-signer.jar" "$UBER_SIGNER_JAR"
  fi
fi

if [[ ! -f "$BAKSMALI_JAR" ]]; then
  curl -L -o "$BAKSMALI_JAR" \
    "https://repo.maven.apache.org/maven2/org/smali/baksmali/2.5.2/baksmali-2.5.2.jar"
fi

if [[ ! -f "$SMALI_JAR" ]]; then
  curl -L -o "$SMALI_JAR" \
    "https://repo.maven.apache.org/maven2/org/smali/smali/2.5.2/smali-2.5.2.jar"
fi

if [[ ! -f "$UBER_SIGNER_JAR" ]]; then
  curl -L -o "$UBER_SIGNER_JAR" \
    "https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/uber-apk-signer-1.3.0.jar"
fi

detect_main() {
  local jar_path="$1"
  local android_tools_class="$2"
  local jf_class="$3"

  if jar tf "$jar_path" | rg -q "^${android_tools_class//./\\/}\\.class$"; then
    echo "$android_tools_class"
    return 0
  fi
  if jar tf "$jar_path" | rg -q "^${jf_class//./\\/}\\.class$"; then
    echo "$jf_class"
    return 0
  fi
  return 1
}

BAKSMALI_MAIN="$(detect_main "$BAKSMALI_JAR" "com.android.tools.smali.baksmali.Main" "org.jf.baksmali.Main" || true)"
SMALI_MAIN="$(detect_main "$SMALI_JAR" "com.android.tools.smali.smali.Main" "org.jf.smali.Main" || true)"
[[ "$BAKSMALI_MAIN" != "" ]] || fail "Could not detect baksmali main class in: $BAKSMALI_JAR"
[[ "$SMALI_MAIN" != "" ]] || fail "Could not detect smali main class in: $SMALI_JAR"

# Some distributions (notably com.android.tools.smali) are split across multiple jars.
SDK_SMALI_UTIL="/tmp/android-sdk/cmdline-tools/latest/lib/external/com/android/tools/smali/smali-util/3.0.3/smali-util-3.0.3.jar"
SDK_SMALI_DEXLIB2="/tmp/android-sdk/cmdline-tools/latest/lib/external/com/android/tools/smali/smali-dexlib2/3.0.3/smali-dexlib2-3.0.3.jar"
SDK_GUAVA="/tmp/android-sdk/cmdline-tools/latest/lib/external/com/google/guava/guava/31.1-jre/guava-31.1-jre.jar"
SDK_JCOMMANDER="/tmp/android-sdk/cmdline-tools/latest/lib/external/com/beust/jcommander/1.78/jcommander-1.78.jar"

BAKSMALI_CP="$BAKSMALI_JAR"
if [[ "$BAKSMALI_MAIN" == "com.android.tools.smali.baksmali.Main" ]]; then
  [[ -f "$SDK_SMALI_UTIL" ]] || fail "Missing dependency jar: $SDK_SMALI_UTIL"
  [[ -f "$SDK_SMALI_DEXLIB2" ]] || fail "Missing dependency jar: $SDK_SMALI_DEXLIB2"
  [[ -f "$SDK_GUAVA" ]] || fail "Missing dependency jar: $SDK_GUAVA"
  [[ -f "$SDK_JCOMMANDER" ]] || fail "Missing dependency jar: $SDK_JCOMMANDER"
  BAKSMALI_CP="${BAKSMALI_CP}:${SDK_SMALI_UTIL}:${SDK_SMALI_DEXLIB2}:${SDK_GUAVA}:${SDK_JCOMMANDER}"
fi

SMALI_CP="$SMALI_JAR"
if [[ "$SMALI_MAIN" == "com.android.tools.smali.smali.Main" ]]; then
  # Prefer matching dexlib2 if present; fall back to SDK's dexlib2/util (often good enough).
  dexlib_candidate="$(
    find /tmp/gradle-home-revanced-patches/caches/modules-2/files-2.1/com.android.tools.smali/smali-dexlib2 -type f -name 'smali-dexlib2-*.jar' 2>/dev/null | sort -V | tail -n 1
  )"
  if [[ "$dexlib_candidate" != "" ]] && [[ -f "$dexlib_candidate" ]]; then
    SMALI_CP="${SMALI_CP}:${dexlib_candidate}"
  elif [[ -f "$SDK_SMALI_DEXLIB2" ]]; then
    SMALI_CP="${SMALI_CP}:${SDK_SMALI_DEXLIB2}"
  else
    fail "Could not locate smali-dexlib2 jar dependency for smali"
  fi

  if [[ -f "$SDK_SMALI_UTIL" ]]; then
    SMALI_CP="${SMALI_CP}:${SDK_SMALI_UTIL}"
  fi
  if [[ -f "$SDK_GUAVA" ]]; then
    SMALI_CP="${SMALI_CP}:${SDK_GUAVA}"
  fi
  if [[ -f "$SDK_JCOMMANDER" ]]; then
    SMALI_CP="${SMALI_CP}:${SDK_JCOMMANDER}"
  fi

  antlr_candidate="$(
    find /tmp/gradle-home-revanced-patches/caches/modules-2/files-2.1/org.antlr/antlr-runtime -type f -name 'antlr-runtime-*.jar' 2>/dev/null | sort -V | tail -n 1
  )"
  if [[ "$antlr_candidate" != "" ]] && [[ -f "$antlr_candidate" ]]; then
    SMALI_CP="${SMALI_CP}:${antlr_candidate}"
  fi
fi

WORK_DIR="$(mktemp -d /tmp/primevideo-skipads-dex-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

DEX_DIR="${WORK_DIR}/dex"
SMALI_DIR="${WORK_DIR}/smali"
PATCHED_ZIP="${WORK_DIR}/unsigned.apk"
SIGNED_DIR="${WORK_DIR}/signed"

mkdir -p "$DEX_DIR" "$SMALI_DIR" "$SIGNED_DIR"

TARGET_DESC="Lcom/amazon/avod/media/ads/internal/state/ServerInsertedAdBreakState;"
TARGET_SMALI_REL="com/amazon/avod/media/ads/internal/state/ServerInsertedAdBreakState.smali"
VIDEO_PLAYER_DESC="Lcom/amazon/avod/media/playback/VideoPlayer;"

echo "[1/6] Copying input APK"
cp -f "$INPUT_APK" "$PATCHED_ZIP"

echo "[2/6] Extracting classes*.dex for scanning"
unzip -q -j "$INPUT_APK" "classes*.dex" -d "$DEX_DIR" || fail "Failed extracting dex files"

detect_dex_interface_flag() {
  local descriptor="$1"
  shift
  python3 - "$descriptor" "$@" <<'PY'
import struct
import sys

ACC_INTERFACE = 0x0200

def uleb128(data, off):
    result = 0
    shift = 0
    while True:
        b = data[off]
        off += 1
        result |= (b & 0x7f) << shift
        if (b & 0x80) == 0:
            return result, off
        shift += 7

def read_u32(data, off):
    return struct.unpack_from("<I", data, off)[0]

def dex_interface_flag(path, desc):
    data = memoryview(open(path, "rb").read())
    if len(data) < 0x70 or data[0:3].tobytes() != b"dex":
        return None

    string_ids_size = read_u32(data, 0x38)
    string_ids_off  = read_u32(data, 0x3c)
    type_ids_size   = read_u32(data, 0x40)
    type_ids_off    = read_u32(data, 0x44)
    class_defs_size = read_u32(data, 0x60)
    class_defs_off  = read_u32(data, 0x64)

    desc_bytes = desc.encode("utf-8")

    # Find string index for descriptor.
    string_idx = None
    for i in range(string_ids_size):
        s_off = read_u32(data, string_ids_off + i * 4)
        strlen, p = uleb128(data, s_off)
        if strlen != len(desc_bytes):
            continue
        if data[p : p + strlen].tobytes() == desc_bytes:
            string_idx = i
            break

    if string_idx is None:
        return None

    # Find type_id whose descriptor_idx == string_idx.
    type_idx = None
    for i in range(type_ids_size):
        d_idx = read_u32(data, type_ids_off + i * 4)
        if d_idx == string_idx:
            type_idx = i
            break

    if type_idx is None:
        return None

    # Find class_def for that type.
    for i in range(class_defs_size):
        off = class_defs_off + i * 32
        class_idx = read_u32(data, off + 0)
        access_flags = read_u32(data, off + 4)
        if class_idx == type_idx:
            return bool(access_flags & ACC_INTERFACE)

    return None

def main():
    desc = sys.argv[1]
    for p in sys.argv[2:]:
        flag = dex_interface_flag(p, desc)
        if flag is None:
            continue
        print("1" if flag else "0")
        return 0

    print("")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
PY
}

# Determine how to call VideoPlayer methods (interface vs class) to avoid ICCE at runtime.
VP_INTERFACE_FLAG="$(detect_dex_interface_flag "$VIDEO_PLAYER_DESC" "$DEX_DIR"/classes*.dex || true)"
PLAYER_INVOKE="invoke-virtual"
if [[ "$VP_INTERFACE_FLAG" == "1" ]]; then
  PLAYER_INVOKE="invoke-interface"
fi

DEX_FILE=""
for dex in "$DEX_DIR"/classes*.dex; do
  [[ -f "$dex" ]] || continue
  if rg -a -q "$TARGET_DESC" "$dex"; then
    DEX_FILE="$dex"
    break
  fi
done
[[ "$DEX_FILE" != "" ]] || fail "Could not locate target class descriptor in any classes*.dex"

DEX_BASENAME="$(basename "$DEX_FILE")"
echo "Target dex: $DEX_BASENAME"

echo "[3/6] Disassembling target dex (baksmali)"
DEX_SMALI_OUT="${SMALI_DIR}/${DEX_BASENAME%.dex}"
mkdir -p "$DEX_SMALI_OUT"
java -cp "$BAKSMALI_CP" "$BAKSMALI_MAIN" d -o "$DEX_SMALI_OUT" "$DEX_FILE" >/dev/null

SERVER_SMALI="${DEX_SMALI_OUT}/${TARGET_SMALI_REL}"
[[ -f "$SERVER_SMALI" ]] || fail "Expected target smali not found after disassembly: $SERVER_SMALI"

# Minimal sanity: ensure the anchor exists.
rg -q "getPrimaryPlayer\\(\\)Lcom/amazon/avod/media/playback/VideoPlayer;" "$SERVER_SMALI" \
  || fail "Anchor getPrimaryPlayer() call not found in $SERVER_SMALI"

ENTER_METHOD_COUNT="$(
  awk '
    $0 == ".method public enter(Lcom/amazon/avod/fsm/Trigger;)V" { c++ }
    END { print c + 0 }
  ' "$SERVER_SMALI"
)"
[[ "$ENTER_METHOD_COUNT" == "1" ]] || fail "Expected exactly one enter(Trigger) method in $SERVER_SMALI, found: $ENTER_METHOD_COUNT"

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
      if (index($0, ":rvd_skip_ads_original") > 0 || index($0, ":rvd_skip_ads_return") > 0) print "patched"
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

echo "[4/6] Injecting skip-ads code"
TMP_SMALI="${SERVER_SMALI}.tmp"
awk -v reg="$PLAYER_REGISTER" -v player_invoke="$PLAYER_INVOKE" '
  BEGIN { in_method=0; saw_get_primary=0; inserted=0 }
  {
    print
    if ($0 == ".method public enter(Lcom/amazon/avod/fsm/Trigger;)V") { in_method=1; next }
    if (in_method && index($0, "getPrimaryPlayer()Lcom/amazon/avod/media/playback/VideoPlayer;") > 0 && inserted == 0) { saw_get_primary=1; next }
    if (in_method && saw_get_primary && $0 ~ /^[[:space:]]*move-result-object v[0-9]+/ && inserted == 0) {
      print ""
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
    if (in_method && $0 == ".end method") { in_method=0; saw_get_primary=0 }
  }
  END { if (inserted == 0) exit 42 }
' "$SERVER_SMALI" > "$TMP_SMALI" || fail "Failed to inject skip-ads code"
mv "$TMP_SMALI" "$SERVER_SMALI"

rg -q ":rvd_skip_ads_return" "$SERVER_SMALI" || fail "Post-injection verification failed (missing label)"
rg -q "NO_MORE_ADS_SKIP_TRANSITION" "$SERVER_SMALI" || fail "Post-injection verification failed (missing trigger)"

echo "[5/6] Reassembling dex (smali)"
PATCHED_DEX="${WORK_DIR}/${DEX_BASENAME}"
java -cp "$SMALI_CP" "$SMALI_MAIN" a -o "$PATCHED_DEX" "$DEX_SMALI_OUT" >/dev/null

echo "[6/6] Updating APK + signing"
# Update exactly one zip entry; keep it stored (no compression) like many production APKs do for dex.
zip -q -0 -u -j "$PATCHED_ZIP" "$PATCHED_DEX"

SIGN_CMD=(java -jar "$UBER_SIGNER_JAR" -a "$PATCHED_ZIP" --allowResign -o "$SIGNED_DIR")
if [[ "$KS_PATH" != "" ]]; then
  SIGN_CMD+=(--ks "$KS_PATH" --ksAlias "$KS_ALIAS")
  if [[ "$KS_PASS" != "" ]]; then SIGN_CMD+=(--ksPass "$KS_PASS"); fi
  if [[ "$KEY_PASS" != "" ]]; then SIGN_CMD+=(--ksKeyPass "$KEY_PASS"); fi
fi

if ! "${SIGN_CMD[@]}" >/dev/null 2>"${WORK_DIR}/sign.err"; then
  echo "signing failed; last 120 lines:" >&2
  tail -n 120 "${WORK_DIR}/sign.err" >&2 || true
  fail "signing failed"
fi

SIGNED_APK="$(find "$SIGNED_DIR" -maxdepth 1 -type f -name "*.apk" ! -name "*.idsig" | head -n 1)"
[[ "$SIGNED_APK" != "" ]] || fail "Signing finished but no output APK was found."

mkdir -p "$(dirname "$OUTPUT_APK")"
cp -f "$SIGNED_APK" "$OUTPUT_APK"

echo "Patched APK created: $OUTPUT_APK"
