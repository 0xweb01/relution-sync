#!/usr/bin/env bash
#
# relution-sync.sh — Upload a macOS .pkg or iOS .ipa to a Relution app store.
#
# Runs the full Relution upload sequence: register a chunked upload, stream the
# file, parse it into an app definition, and persist the app. A display name is
# supplied for packages whose metadata carries none (typical for macOS .pkg),
# which otherwise causes persistence to fail server-side.
#
# Relution does not publish documentation for this REST API; the request flow
# was derived by observing the Relution web console.
#
# Configuration (environment):
#   RELUTION_HOST           Base URL, e.g. https://relution.example.com
#   RELUTION_ACCESS_TOKEN   API access token (Profile > Access Tokens in Relution)
#
# Usage:
#   RELUTION_HOST=https://relution.example.com \
#   RELUTION_ACCESS_TOKEN=xxxxx \
#   ./relution-sync.sh <file.pkg|file.ipa> [display-name]
#
# Requirements: bash, curl (>= 7.76 for --fail-with-body), jq
#
#

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: relution-sync.sh <file.pkg|file.ipa> [display-name]

Environment:
  RELUTION_HOST           Relution base URL, e.g. https://relution.example.com
  RELUTION_ACCESS_TOKEN   Relution API access token

Example:
  RELUTION_HOST=https://relution.example.com \
  RELUTION_ACCESS_TOKEN=xxxxx \
  ./relution-sync.sh ./Firefox.pkg Firefox
USAGE
  exit "${1:-0}"
}

case "${1:-}" in -h|--help) usage 0 ;; esac

HOST="${RELUTION_HOST:?RELUTION_HOST is not set (see --help)}"
TOKEN="${RELUTION_ACCESS_TOKEN:?RELUTION_ACCESS_TOKEN is not set (see --help)}"
FILE="${1:?missing file argument (see --help)}"
APP_NAME="${2:-$(basename "$FILE" | sed 's/\.[^.]*$//')}"

[ -f "$FILE" ] || { echo "File not found: $FILE" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

API="${HOST%/}/api/management/v1"
UPLOAD_URL="${API}/content/apps/versions/file/upload"
AUTH=(-H "X-User-Access-Token: ${TOKEN}" -H "Accept: application/json")

# Run curl, split the response body from the trailing HTTP status code, and
# abort with the server's message on any non-2xx response.
request() {
  local response status body
  response="$(curl -sS -w $'\n%{http_code}' "$@")"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "Relution request failed (HTTP ${status}):" >&2
    echo "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

file_name="$(basename "$FILE")"
file_size="$(wc -c < "$FILE" | tr -d ' ')"
echo "Uploading ${file_name} (${file_size} bytes) to ${HOST}"

# 1. Register the upload; obtain the resource UUID and the first chunk window.
init="$(request "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${file_name}\",\"size\":${file_size},\"contentType\":\"application/octet-stream\"}" \
  "$UPLOAD_URL")"
resource_uuid="$(jq -r .resourceUuid <<<"$init")"
chunk_size="$(jq -r .chunkSize <<<"$init")"
chunk_offset="$(jq -r .chunkOffset <<<"$init")"

# 2. Stream the file. The server returns the next offset after each chunk and
#    signals completion with a negative offset. Content already present (matched
#    by hash) returns -1 immediately, so re-runs transfer nothing.
while [ "$chunk_offset" -ge 0 ]; do
  chunk="$(mktemp)"
  tail -c +$((chunk_offset + 1)) "$FILE" | head -c "$chunk_size" > "$chunk" || true
  response="$(request "${AUTH[@]}" \
    -F "chunkOffset=${chunk_offset}" \
    -F "chunkSize=${chunk_size}" \
    -F "file=@${chunk};filename=${file_name}" \
    "${UPLOAD_URL}/${resource_uuid}")"
  rm -f "$chunk"
  chunk_offset="$(jq -r .chunkOffset <<<"$response")"
  chunk_size="$(jq -r .chunkSize <<<"$response")"
done
echo "Upload complete."

# 3. Parse the uploaded binary into an app definition.
parsed="$(request -X POST "${AUTH[@]}" \
  "${API}/content/apps/fromFile/${resource_uuid}")"
if [ "$(jq -r '.results | length' <<<"$parsed")" -lt 1 ]; then
  echo "Relution could not parse an app from ${file_name}:" >&2
  jq . <<<"$parsed" >&2
  exit 1
fi

# Ensure a display name is present. Only inject one when the parsed name is
# empty, so metadata extracted from .ipa files is preserved untouched.
app="$(jq -c --arg name "$APP_NAME" '
  .results[0]
  | .name = (if (.name? | type) == "object" and (.name | length) > 0 then .name else {en: $name, de: $name} end)
  | .versions = ((.versions // []) | map(
      .name = (if (.name? | type) == "object" and (.name | length) > 0 then .name else {en: $name, de: $name} end)
    ))
' <<<"$parsed")"

# 4. Persist the app. New uploads enter the Development state and are not
#    distributed to devices until promoted to Productive within Relution.
request -X POST "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "$app" \
  "${API}/content/apps" > /dev/null

echo "Persisted '${APP_NAME}' (${file_name}) to Relution."
