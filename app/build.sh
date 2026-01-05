#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${ROOT_DIR}/src"
DIST_DIR="${ROOT_DIR}/dist"

BUILD_NUMBER="${BUILD_NUMBER:-local}"
BUILD_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "${DIST_DIR}"

# Replace placeholders in HTML
sed   -e "s/__BUILD_NUMBER__/${BUILD_NUMBER}/g"   -e "s/__BUILD_TIME__/${BUILD_TIME}/g"   "${SRC_DIR}/index.html" > "${DIST_DIR}/index.html"

tar -C "${DIST_DIR}" -czf "${DIST_DIR}/app.tar.gz" index.html
echo "Created ${DIST_DIR}/app.tar.gz"