#!/usr/bin/env bash
# blip.sh — minimal BleepingComputer scraper (busybox-friendly)
# Deps: bash/ash, curl OR wget, sed, awk, grep, tr, date, mkdir, rm, mv

set -euo pipefail

BASE="https://www.bleepingcomputer.com"
OUT_DIR="${OUT:-.}"
ART_DIR="$OUT_DIR/articles"
TODAY="$(date +%F)"
DAILY_JSON="$OUT_DIR/${TODAY}_daily-news.json"
HOMEPAGE_HTML="$OUT_DIR/${TODAY}_bleepingcomputer.html"

CLEAN_OLD=0
NO_PREARCHIVE=0

fetch() { if command -v curl >/dev/null 2>&1; then curl -fsL "$1"; else wget -qO- "$1"; fi; }
save()  { if command -v curl >/dev/null 2>&1; then curl -fsL "$1" -o "$2"; else wget -qO "$2" "$1"; fi; }
one_line(){ tr '\r\n' ' ' | sed -E 's/[[:space:]]+/ /g'; }
slugify_from_url(){ local u="${1%/}"; printf '%s' "${u##*/}"; }

html_to_text(){
  sed -E 's/<br[[:space:]]*\/?>/\n/g; s/<\/p>/\n\n/g; s/<[^>]+>//g' | sed -E '
    s/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g;
    s/&quot;/"/g; s/&#34;/"/g; s/&#39;/'"'"'/g;
    s/&ldquo;/"/g; s/&rdquo;/"/g; s/&#8220;/"/g; s/&#8221;/"/g;
    s/&lsquo;/'"'"'/g; s/&rsquo;/'"'"'/g; s/&#8216;/'"'"'/g; s/&#8217;/'"'"'/g;
    s/&mdash;/—/g; s/&#8212;/—/g; s/&ndash;/–/g; s/&#8211;/–/g;
    s/&hellip;/…/g; s/&#8230;/…/g;'
}
decode_entities(){
  sed -E '
    s/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g;
    s/&quot;/"/g; s/&#34;/"/g; s/&#39;/'"'"'/g;
    s/&ldquo;/"/g; s/&rdquo;/"/g; s/&#8220;/"/g; s/&#8221;/"/g;
    s/&lsquo;/'"'"'/g; s/&rsquo;/'"'"'/g; s/&#8216;/'"'"'/g; s/&#8217;/'"'"'/g;
    s/&mdash;/—/g; s/&#8212;/—/g; s/&ndash;/–/g; s/&#8211;/–/g;
    s/&hellip;/…/g; s/&#8230;/…/g;'
}

write_json_array_header(){ echo "["; }
write_json_array_footer(){ echo "]"; }
json_escape(){ sed -E 's/\\/\\\\/g; s/"/\\"/g'; }
append_json_item(){
  local title="$1" url="$2" path="$3" first="$4"
  [ "$first" = "0" ] && printf ",\n"
  printf '  { "title": "%s", "url": "%s", "path": "%s" }' \
    "$(printf '%s' "$title" | json_escape)" \
    "$(printf '%s' "$url"   | json_escape)" \
    "$(printf '%s' "$path"  | json_escape)"
}

# ---------- scraping ----------
scrape_homepage(){
  mkdir -p "$ART_DIR"
  echo "[+] Fetching homepage…"
  save "$BASE/" "$HOMEPAGE_HTML"

  echo "[+] Parsing featured/latest blocks…"
  local page; page="$(one_line < "$HOMEPAGE_HTML")"

  local first=1
  write_json_array_header > "$DAILY_JSON"
  printf '%s' "$page" | sed 's/<li/\n<li/g' | grep 'class="nmic"' | \
  while IFS= read -r li; do
    url="$(printf '%s\n' "$li" | sed -nE 's~.*href="([^"]+)".*~\1~p')"
    case "$url" in
      https://www.bleepingcomputer.com/news/*) : ;;
      *) continue ;;
    esac
    title="$(printf '%s\n' "$li" | sed -nE 's~.*<p>([^<]+)</p>.*~\1~p')"
    [ -z "$title" ] && title="$(printf '%s\n' "$li" | sed -nE 's~.*alt="([^"]+)".*~\1~p')"
    [ -z "$title" ] && title="(No title)"
    slug="$(slugify_from_url "$url")"
    path="$ART_DIR/$slug.md"
    append_json_item "$title" "$url" "$path" "$first" >> "$DAILY_JSON"
    first=0
  done
  write_json_array_footer >> "$DAILY_JSON"
  echo "[+] Wrote: $DAILY_JSON"
}

extract_title_date_time(){
  local file="$1"
  local T D TM
  T="$(one_line < "$file" | sed -nE 's~.*<h1>([^<]+)</h1>.*~\1~p')"
  D="$(grep -oE '<li class="cz-news-date">[^<]+' "$file" | sed 's~.*>~~' | head -n1 || true)"
  TM="$(grep -oE '<li class="cz-news-time">[^<]+' "$file" | sed 's~.*>~~' | head -n1 || true)"
  echo "$T"$'\t'"$D"$'\t'"$TM"
}

extract_body_text(){
  awk '
    /<div class="articleBody">/ {inb=1; next}
    /<div class="cz-related-article-wrapp">/ {inb=0}
    inb==1 {print}
  ' "$1" \
  | awk '
    /<style[ >]/, /<\/style>/   { next }
    /<script[ >]/, /<\/script>/ { next }
    /class="ia_ad"/, /<\/div>/  { next }
    /class="ia_lef"/, /<\/div>/ { next }
    /class="ia_rig"/, /<\/div>/ { next }
    { print }
  ' \
  | html_to_text \
  | awk '
      BEGIN{skip=0}
      /Picus Blue Report 2025 is Here/ {skip=1; next}
      skip==1 && /^Get (the )?Blue Report 2025/ {skip=0; next}
      skip==1 {next}
      {print}
    ' \
  | sed -E 's/^[[:space:]]+$//g' \
  | awk 'NF{ if (p) print ""; print; p=0; next } { p=1 }'
}

extract_related_list(){
  grep -oE '<a href="[^"]+" class="ras">[^<]+</a>' "$1" 2>/dev/null || true
}

quote_block(){ awk 'length($0)==0 { print ">"; next } { print "> " $0 }'; }

scrape_article(){
  local url="$1" out_md="$2"
  echo "[+] Article: $url"
  mkdir -p "$(dirname -- "$out_md")"

  local tmp="$OUT_DIR/.tmp_$$.html"
  save "$url" "$tmp"

  IFS=$'\t' read -r title adate atime < <(extract_title_date_time "$tmp")
  [ -z "$title" ] && title="(No title)"

  local body_txt; body_txt="$(extract_body_text "$tmp")"
  local related;  related="$(extract_related_list "$tmp")"

  {
    printf '# %s\n' "$title"
    printf '> ### %s %s\n' "${adate:-}" "${atime:-}"
    echo
    printf '%s\n' "$body_txt" | quote_block
    echo
    echo '---'
    echo '### Related Links'
    if [ -z "$related" ]; then
      echo '- (none)'
    else
      printf '%s\n' "$related" | while IFS= read -r a; do
        rurl="$(printf '%s\n' "$a" | sed -nE 's~.*href="([^"]+)".*~\1~p')"
        rttl="$(printf '%s\n' "$a" | sed -nE 's~.*>([^<]+)</a>.*~\1~p' | decode_entities)"
        printf -- '- [%s](%s)\n' "$rttl" "$rurl"
      done
    fi
  } > "$out_md"

  rm -f "$tmp"
  echo "[+] Wrote: $out_md"
}

scrape_articles_from_json(){
  local json="$1"
  echo "[+] Reading $json"
  awk '
    BEGIN{u="";p=""}
    /"url":[[:space:]]*"/  {match($0, /"url":[[:space:]]*"([^"]*)"/, m); if(m[1]!="") u=m[1]}
    /"path":[[:space:]]*"/ {match($0, /"path":[[:space:]]*"([^"]*)"/, m); if(m[1]!="") p=m[1]}
    /}/ { if(u!="" && p!=""){ print u "\t" p; u=""; p="" } }
  ' "$json" | while IFS=$'\t' read -r url path; do
      case "$url" in
        *"/news/"*) : ;;
        *) echo "[-] Skipping non-news URL: $url"; continue ;;
      esac
      scrape_article "$url" "$path"
  done
}

# ---------- archiving logic (at startup) ----------
safe_dest_path(){ # $1=base dir, $2=name (e.g., YYYY-MM-DD)
  local base="$1" name="$2" d="$1/$2" n=0
  while [ -e "$d" ]; do n=$((n+1)); d="$base/${name}_$n"; done
  printf '%s' "$d"
}

latest_json_date(){
  # Try to detect the date from a JSON file name pattern
  # Prefer a JSON inside articles/ from previous run; fallback to OUT_DIR
  local f
  for f in "$ART_DIR"/*.json "$OUT_DIR"/*_daily-news.json; do
    [ -f "$f" ] || continue
    case "$f" in
      */[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_daily-news.json)
        basename "$f" | cut -d_ -f1 && return 0 ;;
    esac
  done
  # fallback: today
  echo "$TODAY"
}

prearchive_previous_run(){
  [ "$NO_PREARCHIVE" -eq 1 ] && { echo "[*] Pre-archive skipped (--no-prearchive)."; return; }

  # Clean .old if requested
  if [ "$CLEAN_OLD" -eq 1 ]; then
    if [ -d "$OUT_DIR/.old" ]; then
      echo "[!] --clean-old: removing $OUT_DIR/.old/*"
      rm -rf "$OUT_DIR/.old"/* 2>/dev/null || true
    fi
  fi

  # Nothing to do if no articles dir and no json
  if [ ! -d "$ART_DIR" ] && [ ! -f "$DAILY_JSON" ] && ! ls "$OUT_DIR"/*_daily-news.json >/dev/null 2>&1; then
    return
  fi

  local stamp; stamp="$(latest_json_date)"
  local OLD_ROOT="$OUT_DIR/.old"
  mkdir -p "$OLD_ROOT"
  local dest; dest="$(safe_dest_path "$OLD_ROOT" "$stamp")"
  mkdir -p "$dest"

  # Move prior articles folder if present
  if [ -d "$ART_DIR" ]; then
    mv "$ART_DIR" "$dest/" && echo "[+] Archived dir: $ART_DIR -> $dest/articles"
  fi

  # Move any matching JSONs (today or previous) into dest
  for f in "$OUT_DIR"/*_daily-news.json; do
    [ -f "$f" ] || continue
    mv -f "$f" "$dest/" && echo "[+] Archived json: $(basename "$f")"
  done

  # Kill old homepage htmls
  rm -f "$OUT_DIR"/*bleepingcomputer.html 2>/dev/null || true

  # Fresh workspace
  mkdir -p "$ART_DIR"
  echo "[+] Prepared fresh $ART_DIR"
}

# ---------- CLI ----------
usage(){
  cat <<EOF
Usage: $0 [--stage homepage|articles|all] [--out DIR] [--clean-old] [--no-prearchive]
  --stage homepage   Fetch homepage and write ${TODAY}_daily-news.json
  --stage articles   Fetch each article from today's JSON and write .md files
  --stage all        Do both, in order (default)
  --out DIR          Output directory (default: current)
  --clean-old        Purge contents of .old/* before pre-archiving
  --no-prearchive    Skip the automatic startup pre-archive
EOF
}

STAGE="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) STAGE="${2:-all}"; shift 2 ;;
    --out)   OUT_DIR="${2:?}"; ART_DIR="$OUT_DIR/articles"; DAILY_JSON="$OUT_DIR/${TODAY}_daily-news.json"; HOMEPAGE_HTML="$OUT_DIR/${TODAY}_bleepingcomputer.html"; shift 2 ;;
    --clean-old) CLEAN_OLD=1; shift ;;
    --no-prearchive) NO_PREARCHIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"

# Do the pre-archive FIRST (default)
prearchive_previous_run

# Make sure fresh articles dir exists
mkdir -p "$ART_DIR"

# ---------- run stages ----------
case "$STAGE" in
  homepage) scrape_homepage ;;
  articles)
    [ -f "$DAILY_JSON" ] || { echo "[-] $DAILY_JSON not found. Run --stage homepage first." >&2; exit 1; }
    scrape_articles_from_json "$DAILY_JSON"
    ;;
  all)
    scrape_homepage
    scrape_articles_from_json "$DAILY_JSON"
    ;;
  *) echo "[-] invalid --stage" >&2; usage; exit 1 ;;
esac

rm *.html
mv *.json articles
