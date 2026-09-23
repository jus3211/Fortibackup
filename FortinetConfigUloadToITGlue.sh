#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<EOF
Usage: $0 -t <API_KEY> -c <COMPANY_ID> -d <DOCUMENT_ID> -f <FOLDER_PATH>

Uploads the latest file (non-recursive) in the specified folder to an IT Glue document (EU).

Required:
  -t  IT Glue API key
  -c  Company ID (kept for compatibility; not used by this endpoint)
  -d  Document ID
  -f  Path to folder containing file(s) to upload

Example:
  ./upload_itglue.sh -t ITG.XXXX -c 12345 -d 67890 -f /path/to/folder
EOF
}

API_KEY=""
COMPANY_ID=""
DOCUMENT_ID=""
FOLDER_PATH=""

while getopts "t:c:d:f:h" opt; do
  case $opt in
    t) API_KEY="$OPTARG" ;;
    c) COMPANY_ID="$OPTARG" ;;
    d) DOCUMENT_ID="$OPTARG" ;;
    f) FOLDER_PATH="$OPTARG" ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

if [ -z "$API_KEY" ] || [ -z "$COMPANY_ID" ] || [ -z "$DOCUMENT_ID" ] || [ -z "$FOLDER_PATH" ]; then
  echo "❌ Missing required arguments."
  show_help
  exit 1
fi

if [ ! -d "$FOLDER_PATH" ]; then
  echo "❌ Folder does not exist: $FOLDER_PATH" >&2
  exit 1
fi

# Find latest file in the given folder (non-recursive), robust to spaces/newlines
LATEST_FILE=""
LATEST_MTIME=0
while IFS= read -r -d '' file; do
  mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
  if (( mtime > LATEST_MTIME )); then
    LATEST_MTIME=$mtime
    LATEST_FILE="$file"
  fi
done < <(find "$FOLDER_PATH" -maxdepth 1 -type f -print0)

if [ -z "$LATEST_FILE" ]; then
  echo "❌ No files in $FOLDER_PATH" >&2
  exit 1
fi

LATEST_NAME=$(basename "$LATEST_FILE")
echo "📄 Uploading file: $LATEST_NAME"

# Check payload size: base64 increases size (payload limit = 10MB)
filesize=$(stat -c %s "$LATEST_FILE")
# base64 length = 4 * ceil(filesize/3)
b64_size=$(( (filesize + 2) / 3 * 4 ))
MAX_PAYLOAD=$((10 * 1024 * 1024))
if (( b64_size > MAX_PAYLOAD )); then
  echo "❌ Encoded payload would be ${b64_size} bytes (> ${MAX_PAYLOAD} bytes)."
  echo "   IT Glue's API payload limit is 10 MB. Use a smaller file or multipart workflow."
  exit 1
fi

# Create payload JSON safely using Python (avoids JSON escaping issues)
payloadfile=$(mktemp /tmp/itglue_payload.XXXXXX.json)
respfile=$(mktemp /tmp/itglue_response.XXXXXX.json)
trap 'rm -f "$payloadfile" "$respfile"' EXIT

python3 - "$LATEST_FILE" "$payloadfile" <<'PY'
import sys, json, base64, os
infile = sys.argv[1]
outfile = sys.argv[2]
fname = os.path.basename(infile)
with open(infile, "rb") as f:
    b64 = base64.b64encode(f.read()).decode('ascii')
payload = {
  "data": {
    "type": "attachments",
    "attributes": {
      "attachment": {
        "content": b64,
        "file_name": fname
      }
    }
  }
}
with open(outfile, "w", encoding="utf-8") as o:
    json.dump(payload, o, separators=(',',':'), ensure_ascii=False)
PY

URI="https://api.eu.itglue.com/documents/${DOCUMENT_ID}/relationships/attachments"

# Send the request
HTTP_CODE=$(curl -sS -w "%{http_code}" -o "$respfile" \
  -X POST "$URI" \
  -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/vnd.api+json" \
  --data-binary @"$payloadfile") || {
    echo "❌ curl failed"; cat "$respfile" >&2; exit 1
}

echo "📡 HTTP Code: $HTTP_CODE"
echo "📜 API Response Body:"
cat "$respfile"
echo

# Fail if non-2xx
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
  echo "❌ IT Glue reports failure (HTTP $HTTP_CODE)" >&2
  exit 1
fi

# Treat any returned 'errors' as a failure (even if HTTP 200)
python3 - "$respfile" <<'PY'
import sys, json
fn = sys.argv[1]
try:
    j = json.load(open(fn, 'r', encoding='utf-8'))
except Exception as e:
    print("❌ Response is not valid JSON:", e, file=sys.stderr)
    sys.exit(2)
if 'errors' in j and j['errors']:
    print("❌ API returned errors:", file=sys.stderr)
    print(json.dumps(j['errors'], indent=2), file=sys.stderr)
    sys.exit(1)
# success — print returned data (helps debugging)
print("✅ API returned successful response.")
if 'data' in j:
    print("Returned data (truncated):")
    s = json.dumps(j['data'], indent=2)
    print(s[:4000])  # avoid flooding the terminal
PY
rc=$?
if (( rc == 0 )); then
  echo "✅ Attached ${LATEST_NAME} to document ID ${DOCUMENT_ID}"
  exit 0
elif (( rc == 1 )); then
  exit 1
else
  exit 1
fi
