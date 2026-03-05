#!/usr/bin/env bash
# Download baksmali/smali tools and uber-apk-signer to a stable cache location.
# Called once at container creation via postCreateCommand.

set -euo pipefail

TOOLS_DIR="${HOME}/.local/share/smali-tools"

mkdir -p "$TOOLS_DIR"

BASE="https://repo.maven.apache.org/maven2/org/smali"
SMALI_VER="2.5.2"

declare -A JARS=(
  ["baksmali.jar"]="${BASE}/baksmali/${SMALI_VER}/baksmali-${SMALI_VER}.jar"
  ["smali.jar"]="${BASE}/smali/${SMALI_VER}/smali-${SMALI_VER}.jar"
  ["dexlib2.jar"]="${BASE}/dexlib2/${SMALI_VER}/dexlib2-${SMALI_VER}.jar"
  ["smali-util.jar"]="${BASE}/util/${SMALI_VER}/util-${SMALI_VER}.jar"
  ["jcommander.jar"]="https://repo.maven.apache.org/maven2/com/beust/jcommander/1.72/jcommander-1.72.jar"
  ["guava.jar"]="https://repo.maven.apache.org/maven2/com/google/guava/guava/16.0/guava-16.0.jar"
  ["antlr-runtime.jar"]="https://repo.maven.apache.org/maven2/org/antlr/antlr-runtime/3.5.2/antlr-runtime-3.5.2.jar"
  ["uber-apk-signer.jar"]="https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/uber-apk-signer-1.3.0.jar"
)

for name in "${!JARS[@]}"; do
  dest="$TOOLS_DIR/$name"
  if [[ ! -f "$dest" ]]; then
    echo "Downloading $name..."
    curl -sL -o "$dest" "${JARS[$name]}"
  fi
done

# Write a helper env file so scripts can source it
cat > "$TOOLS_DIR/env.sh" << EOF
SMALI_TOOLS_DIR="${TOOLS_DIR}"
BAKSMALI_CP="\${SMALI_TOOLS_DIR}/baksmali.jar:\${SMALI_TOOLS_DIR}/dexlib2.jar:\${SMALI_TOOLS_DIR}/smali-util.jar:\${SMALI_TOOLS_DIR}/jcommander.jar:\${SMALI_TOOLS_DIR}/guava.jar"
SMALI_CP="\${SMALI_TOOLS_DIR}/smali.jar:\${SMALI_TOOLS_DIR}/dexlib2.jar:\${SMALI_TOOLS_DIR}/smali-util.jar:\${SMALI_TOOLS_DIR}/jcommander.jar:\${SMALI_TOOLS_DIR}/guava.jar:\${SMALI_TOOLS_DIR}/antlr-runtime.jar"
BAKSMALI_MAIN="org.jf.baksmali.Main"
SMALI_MAIN="org.jf.smali.Main"
UBER_SIGNER_JAR="\${SMALI_TOOLS_DIR}/uber-apk-signer.jar"
export BAKSMALI_CP SMALI_CP BAKSMALI_MAIN SMALI_MAIN UBER_SIGNER_JAR
EOF

echo "Smali tools ready in $TOOLS_DIR"
