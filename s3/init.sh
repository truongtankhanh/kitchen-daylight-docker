#!/bin/sh
# One-shot job: creates the buckets given as arguments through the S3 API, idempotently.
# Plain sh (busybox ash in the S3 image). Needs curl 7.75 or newer (--aws-sigv4); the SeaweedFS image carries curl.
# Environment: S3_ACCESS_KEY, S3_SECRET_KEY (required); S3_ENDPOINT (default http://s3:8333); S3_REGION (default us-east-1).
set -eu

endpoint=${S3_ENDPOINT:-http://s3:8333}
region=${S3_REGION:-us-east-1}
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY is not set}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY is not set}"

if [ "$#" -eq 0 ]; then
  echo "[kd] usage: init.sh <bucket>..." >&2
  exit 2
fi

# The service is healthy before this runs; the retries only absorb the filer warming up.
max_attempts=30

for bucket in "$@"; do
  attempt=1
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' \
      --aws-sigv4 "aws:amz:$region:s3" --user "$S3_ACCESS_KEY:$S3_SECRET_KEY" \
      --request PUT "$endpoint/$bucket") || code=000
    case "$code" in
      200)
        echo "[kd] bucket $bucket ready (HTTP 200)"
        break
        ;;
      409)
        # BucketAlreadyOwnedByYou / BucketAlreadyExists: creating an existing bucket is not an error.
        echo "[kd] bucket $bucket already exists (HTTP 409)"
        break
        ;;
      401|403)
        echo "[kd] bucket $bucket: credentials rejected (HTTP $code)" >&2
        exit 1
        ;;
    esac
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "[kd] bucket $bucket: giving up after $attempt attempts (last HTTP status $code)" >&2
      exit 1
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
done
