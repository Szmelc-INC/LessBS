#!/usr/bin/env bash
#
# lessbs-webhook.sh
# Sends each articles/*.md to a Discord webhook (first line as text, file as
# attachment), skipping anything already recorded in .sent.log.
#
set -euo pipefail

DISCORD_WEBHOOK="discord-webhook-url"

ARTICLES_DIR="articles"
SENT_LOG=".sent.log"

# Ensure the log exists so the grep check never errors on a fresh run.
touch "$SENT_LOG"

# Empty glob -> no iterations, instead of a literal "articles/*.md".
shopt -s nullglob

for file in "$ARTICLES_DIR"/*.md; do
    fname="$(basename "$file")"

    # Exact whole-line match against the log -> already sent, skip.
    if grep -Fxq "$fname" "$SENT_LOG"; then
        echo "skip : $fname (already sent)"
        continue
    fi

    first_line="$(head -n 1 "$file")"

    # Build payload_json with jq so quotes/backslashes/unicode are escaped safely.
    payload="$(jq -nc --arg c "$first_line" '{content: $c}')"

    echo "send : $fname"
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
        -X POST \
        -F "payload_json=$payload" \
        -F "file=@${file}" \
        "$DISCORD_WEBHOOK")"

    # Discord returns 200 or 204 on a successful webhook post.
    if [[ "$http_code" == "200" || "$http_code" == "204" ]]; then
        echo "$fname" >> "$SENT_LOG"
        echo "ok   : $fname -> logged"
    else
        echo "FAIL : $fname (HTTP $http_code) -- not logged, will retry next run" >&2
    fi

    # Gentle on Discord's rate limiter.
    sleep 1
done
