#!/usr/bin/env bash
set -euo pipefail

# Ansible writes /etc/app/env with:
#   ARTIFACT_BUCKET=your-bucket-name
# and /etc/app/artifact_key with:
#   releases/app-123.tar.gz

ENV_FILE="/etc/app/env"
ARTIFACT_KEY_FILE="${ARTIFACT_KEY_FILE:-/etc/app/artifact_key}"

DEST_DIR="/var/www/html"
TMP_DIR="$(mktemp -d)"

# Load environment variables
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

if [[ -z "${ARTIFACT_BUCKET:-}" ]]; then
  echo "ERROR: ARTIFACT_BUCKET is not set. Ansible must write /etc/app/env"
  exit 1
fi

if [[ ! -f "${ARTIFACT_KEY_FILE}" ]]; then
  echo "ERROR: ${ARTIFACT_KEY_FILE} not found."
  exit 1
fi

ARTIFACT_KEY="$(tr -d '[:space:]' < "${ARTIFACT_KEY_FILE}")"
if [[ -z "${ARTIFACT_KEY}" ]]; then
  echo "ERROR: Artifact key is empty."
  exit 1
fi

echo "Deploying s3://${ARTIFACT_BUCKET}/${ARTIFACT_KEY} -> ${DEST_DIR}"

aws s3 cp "s3://${ARTIFACT_BUCKET}/${ARTIFACT_KEY}" "${TMP_DIR}/app.tar.gz" --only-show-errors

# Replace content atomically-ish (simple approach)
sudo rm -rf "${DEST_DIR:?}"/*
sudo tar -xzf "${TMP_DIR}/app.tar.gz" -C "${DEST_DIR}"

# Ensure permissions prevent 403
sudo chown -R www-data:www-data "${DEST_DIR}"
sudo chmod -R 755 "${DEST_DIR}"

rm -rf "${TMP_DIR}"
echo "Deploy complete."
