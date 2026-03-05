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
  patch-primevideo-skipads.sh <input.apk> [output.apk] [options]

This script:
  1) Applies the local patch bundle (diff) to analysis/revanced-patches (without committing).
  2) Builds a custom ReVanced patches bundle (.rvp) from the local repo at analysis/revanced-patches
     (including any local modifications).
  3) Uses ReVanced CLI to patch the APK with the "Skip ads" patch.
  4) Verifies the patched APK contains the injected hook in ServerInsertedAdBreakState.enter(...).

Options:
  --keystore <path>       Custom keystore for signing.
  --ks-alias <alias>      Keystore entry alias. (ReVanced CLI: --keystore-entry-alias)
  --ks-pass <password>    Keystore password. (ReVanced CLI: --keystore-password)
  --key-pass <password>   Keystore entry password. (ReVanced CLI: --keystore-entry-password)

  --gh-user <username>    GitHub Packages username for building analysis/revanced-patches.
  --gh-token <token>      GitHub Packages token for building analysis/revanced-patches.
                          Prefer env vars instead of passing on the command line.

  --force                 Pass --force to ReVanced CLI patch (skip compatibility check).
  --no-verify             Skip post-patch smali verification.
  --keep-tmp              Keep temporary directories (Gradle/ReVanced/apktool temps remain).
  -h, --help              Show this help.

Required env vars (recommended for building analysis/revanced-patches):
  GITHUB_PACKAGES_USERNAME, GITHUB_PACKAGES_PASSWORD
or:
  githubPackagesUsername, githubPackagesPassword

Notes:
  - Building analysis/revanced-patches requires access to ReVanced's Gradle plugin via GitHub Packages.
  - This script uses a JDK 21 in /tmp (downloaded if missing) for Gradle, because newer JDKs can break
    Gradle Kotlin DSL evaluation.
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
GH_USER=""
GH_TOKEN=""
CLI_FORCE="0"
NO_VERIFY="0"
KEEP_TMP="0"

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
    --gh-user)
      [[ "${2:-}" != "" ]] || fail "--gh-user requires a value"
      GH_USER="$2"
      shift 2
      ;;
    --gh-token)
      [[ "${2:-}" != "" ]] || fail "--gh-token requires a value"
      GH_TOKEN="$2"
      shift 2
      ;;
    --force)
      CLI_FORCE="1"
      shift
      ;;
    --no-verify)
      NO_VERIFY="1"
      shift
      ;;
    --keep-tmp)
      KEEP_TMP="1"
      shift
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
  OUTPUT_APK="${output_dir}/${base_name}-skipads-patched.apk"
fi

if [[ "$KS_PATH" != "" ]]; then
  [[ -f "$KS_PATH" ]] || fail "Keystore file not found: $KS_PATH"
  [[ "$KS_ALIAS" != "" ]] || fail "--ks-alias is required when --keystore is used"
fi

require_cmd java
require_cmd curl
require_cmd rg
require_cmd find
require_cmd awk
require_cmd unzip
require_cmd git

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TOOLS_DIR="${ROOT_DIR}/analysis/tools/revanced"
REVANCED_CLI_JAR="${TOOLS_DIR}/revanced-cli.jar"
APKTOOL_JAR="${TOOLS_DIR}/apktool.jar"

PATCHES_REPO_DIR="${ROOT_DIR}/analysis/revanced-patches"
PATCHES_REPO_PATCH="${ROOT_DIR}/patches/revanced-primevideo-skipads.patch"

JDK21_DIR="/tmp/temurin21"
GRADLE_USER_HOME="/tmp/gradle-home-revanced-patches"
APKTOOL_FRAMEWORK_DIR="/tmp/apktool-framework"
ANDROID_SDK_ROOT="/tmp/android-sdk"

TMP_PARENT="/tmp/primevideo-skipads-cli"
TMP_DIR="$(mktemp -d "${TMP_PARENT}-XXXXXX")"

cleanup() {
  if [[ "$KEEP_TMP" == "1" ]]; then
    echo "Keeping temp dir: $TMP_DIR"
    return
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TOOLS_DIR"

echo "[1/7] Ensure Tools (ReVanced CLI + apktool)"
if [[ ! -f "$REVANCED_CLI_JAR" ]]; then
  # Pinned to a known working version. Override by placing your own jar at analysis/tools/revanced/revanced-cli.jar.
  REVANCED_CLI_VERSION="5.0.1"
  mkdir -p "$TOOLS_DIR"
  curl -L -o "${REVANCED_CLI_JAR}.tmp" \
    "https://github.com/ReVanced/revanced-cli/releases/download/v${REVANCED_CLI_VERSION}/revanced-cli-${REVANCED_CLI_VERSION}-all.jar"
  mv "${REVANCED_CLI_JAR}.tmp" "$REVANCED_CLI_JAR"
fi

if [[ ! -f "$APKTOOL_JAR" ]]; then
  APKTOOL_VERSION="2.11.1"
  curl -L -o "${APKTOOL_JAR}.tmp" \
    "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar"
  mv "${APKTOOL_JAR}.tmp" "$APKTOOL_JAR"
fi

echo "[2/7] Ensure JDK 21 (for Gradle build)"
if [[ ! -x "${JDK21_DIR}/bin/java" ]]; then
  rm -rf "$JDK21_DIR"
  mkdir -p "$JDK21_DIR"
  curl -L -o "${TMP_DIR}/temurin21.tar.gz" \
    "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse"
  tar -xzf "${TMP_DIR}/temurin21.tar.gz" -C "$JDK21_DIR" --strip-components=1
fi

[[ -d "$PATCHES_REPO_DIR" ]] || fail "Missing patches repo: $PATCHES_REPO_DIR"
[[ -x "${PATCHES_REPO_DIR}/gradlew" ]] || fail "Missing gradle wrapper: ${PATCHES_REPO_DIR}/gradlew"
[[ -f "$PATCHES_REPO_PATCH" ]] || fail "Missing patches diff: $PATCHES_REPO_PATCH"

echo "[3/7] Ensure Android SDK (for building extensions)"
if [[ ! -d "${ANDROID_SDK_ROOT}/platforms/android-34" || ! -d "${ANDROID_SDK_ROOT}/build-tools/34.0.0" ]]; then
  CMDLINE_ZIP="${TMP_DIR}/cmdline-tools.zip"
  CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

  mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools/latest"
  if [[ ! -x "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" ]]; then
    curl -L -o "$CMDLINE_ZIP" "$CMDLINE_URL"
    unzip -q "$CMDLINE_ZIP" -d "${ANDROID_SDK_ROOT}/cmdline-tools/latest"
    if [[ -d "${ANDROID_SDK_ROOT}/cmdline-tools/latest/cmdline-tools" ]]; then
      mv "${ANDROID_SDK_ROOT}/cmdline-tools/latest/cmdline-tools"/* "${ANDROID_SDK_ROOT}/cmdline-tools/latest/"
      rmdir "${ANDROID_SDK_ROOT}/cmdline-tools/latest/cmdline-tools"
    fi
  fi

  export ANDROID_SDK_ROOT
  export PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"

  # Avoid pipefail SIGPIPE issues with `yes |`.
  set +o pipefail
  yes | sdkmanager --licenses >/tmp/android-licenses.log || true
  set -o pipefail

  sdkmanager --install "platform-tools" "platforms;android-34" "build-tools;34.0.0" >/tmp/android-sdk-install.log
fi

echo "[4/7] Patch Local revanced-patches Working Tree (no commit)"
if git -C "$PATCHES_REPO_DIR" apply --check "$PATCHES_REPO_PATCH" >/dev/null 2>&1; then
  git -C "$PATCHES_REPO_DIR" apply "$PATCHES_REPO_PATCH"
  echo "Applied: $PATCHES_REPO_PATCH"
else
  if git -C "$PATCHES_REPO_DIR" apply --reverse --check "$PATCHES_REPO_PATCH" >/dev/null 2>&1; then
    echo "Already applied: $PATCHES_REPO_PATCH"
  else
    fail "Could not apply $PATCHES_REPO_PATCH (not clean, or patch drifted)."
  fi
fi

# Required for Android Gradle Plugin to locate the SDK.
if [[ ! -f "${PATCHES_REPO_DIR}/local.properties" ]]; then
  cat > "${PATCHES_REPO_DIR}/local.properties" <<EOF
# Auto-generated by analysis/scripts/patch-primevideo-skipads.sh
sdk.dir=${ANDROID_SDK_ROOT}
EOF
fi

echo "[5/7] Build Custom patches.rvp (analysis/revanced-patches)"
# Credentials can come from env or CLI flags.
if [[ "$GH_USER" == "" ]]; then
  GH_USER="${GITHUB_PACKAGES_USERNAME:-${githubPackagesUsername:-}}"
fi
if [[ "$GH_TOKEN" == "" ]]; then
  GH_TOKEN="${GITHUB_PACKAGES_PASSWORD:-${githubPackagesPassword:-}}"
fi

# If not provided via env/flags, allow Gradle to read credentials from:
#   $GRADLE_USER_HOME/gradle.properties
# where keys must be:
#   githubPackagesUsername=...
#   githubPackagesPassword=...
if [[ "$GH_USER" == "" || "$GH_TOKEN" == "" ]]; then
  if [[ -f "${GRADLE_USER_HOME}/gradle.properties" ]]; then
    if ! rg -q '^githubPackagesUsername=' "${GRADLE_USER_HOME}/gradle.properties" || \
       ! rg -q '^githubPackagesPassword=' "${GRADLE_USER_HOME}/gradle.properties"; then
      fail "Missing GitHub Packages credentials. Provide via env/flags or add githubPackagesUsername/githubPackagesPassword to ${GRADLE_USER_HOME}/gradle.properties."
    fi
    # Load values from gradle.properties so we can pass them via ORG_GRADLE_PROJECT_*
    # (avoids surprising cases where Gradle doesn't pick them up for credentials resolution).
    GH_USER="$(
      awk '/^githubPackagesUsername=/{sub(/^githubPackagesUsername=/,""); print; exit}' \
        "${GRADLE_USER_HOME}/gradle.properties"
    )"
    GH_TOKEN="$(
      awk '/^githubPackagesPassword=/{sub(/^githubPackagesPassword=/,""); print; exit}' \
        "${GRADLE_USER_HOME}/gradle.properties"
    )"
    [[ "$GH_USER" != "" ]] || fail "githubPackagesUsername is empty in ${GRADLE_USER_HOME}/gradle.properties"
    [[ "$GH_TOKEN" != "" ]] || fail "githubPackagesPassword is empty in ${GRADLE_USER_HOME}/gradle.properties"
  else
    fail "Missing GitHub Packages credentials. Set GITHUB_PACKAGES_USERNAME/GITHUB_PACKAGES_PASSWORD (or pass --gh-user/--gh-token), or create ${GRADLE_USER_HOME}/gradle.properties with githubPackagesUsername/githubPackagesPassword."
  fi
fi

mkdir -p "$APKTOOL_FRAMEWORK_DIR"

(
  cd "$PATCHES_REPO_DIR"
  JAVA_HOME="$JDK21_DIR" PATH="$JAVA_HOME/bin:$PATH" \
    GRADLE_USER_HOME="$GRADLE_USER_HOME" \
    ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT" \
    ORG_GRADLE_PROJECT_githubPackagesUsername="$GH_USER" \
    ORG_GRADLE_PROJECT_githubPackagesPassword="$GH_TOKEN" \
    ./gradlew :patches:build
)

CUSTOM_RVP="$(
  # Only consider the main artifact.
  find "$PATCHES_REPO_DIR/patches/build/libs" -maxdepth 1 -type f -name 'patches-*.rvp' \
    ! -name '*-sources.rvp' ! -name '*-javadoc.rvp' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk 'NR==1 {print $2}'
)"
[[ "$CUSTOM_RVP" != "" ]] || fail "Build finished, but no .rvp was found under: $PATCHES_REPO_DIR"

CUSTOM_RVP_OUT="${TOOLS_DIR}/patches-custom.rvp"
cp -f "$CUSTOM_RVP" "$CUSTOM_RVP_OUT"
echo "Using patches bundle: $CUSTOM_RVP_OUT"

echo "[6/7] Patch APK (ReVanced CLI: Skip ads)"
PATCH_CMD=(java -jar "$REVANCED_CLI_JAR" patch -p "$CUSTOM_RVP_OUT" --exclusive -e "Skip ads" -o "$OUTPUT_APK" -t "${TMP_DIR}/revanced-tmp" --purge)
if [[ "$CLI_FORCE" == "1" ]]; then
  PATCH_CMD+=(--force)
fi
if [[ "$KS_PATH" != "" ]]; then
  PATCH_CMD+=(--keystore "$KS_PATH" --keystore-entry-alias "$KS_ALIAS")
  if [[ "$KS_PASS" != "" ]]; then
    PATCH_CMD+=(--keystore-password "$KS_PASS")
  fi
  if [[ "$KEY_PASS" != "" ]]; then
    PATCH_CMD+=(--keystore-entry-password "$KEY_PASS")
  fi
fi
PATCH_CMD+=("$INPUT_APK")
# Redact secrets from logs.
PATCH_CMD_LOG=("${PATCH_CMD[@]}")
for i in "${!PATCH_CMD_LOG[@]}"; do
  if [[ "${PATCH_CMD_LOG[$i]}" == "--keystore-password" || "${PATCH_CMD_LOG[$i]}" == "--keystore-entry-password" ]]; then
    if (( i + 1 < ${#PATCH_CMD_LOG[@]} )); then
      PATCH_CMD_LOG[$((i + 1))]="***"
    fi
  fi
done
echo "Running: ${PATCH_CMD_LOG[*]}"
"${PATCH_CMD[@]}"

echo "[7/7] Verify Patch"
if [[ "$NO_VERIFY" == "1" ]]; then
  echo "Skipping verification (--no-verify)."
else
  VERIFY_DIR="${TMP_DIR}/verify"
  java -jar "$APKTOOL_JAR" d -f -r -q -p "$APKTOOL_FRAMEWORK_DIR" "$OUTPUT_APK" -o "$VERIFY_DIR" >/dev/null

  SERVER_SMALI="$(rg --files "$VERIFY_DIR" | rg 'ServerInsertedAdBreakState\\.smali$' | head -n 1)"
  [[ "$SERVER_SMALI" != "" ]] || fail "Verification failed: could not find ServerInsertedAdBreakState.smali in patched APK."

  rg -q 'Lapp/revanced/extension/primevideo/ads/SkipAdsPatch;->enterServerInsertedAdBreakState' \
    "$SERVER_SMALI" || fail "Verification failed: injected hook call not found in ServerInsertedAdBreakState.enter()."
fi

echo "Patched APK created: $OUTPUT_APK"
