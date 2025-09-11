#!/usr/bin/env sh
# readnews_fzf.sh — fzf TUI (bash & zsh)
# Left: colored, wrapped titles. Right: full .md preview.
# Enter: open article in pager (bat/less), q to return.

set -e
[ -n "${ZSH_VERSION:-}" ] && { setopt NULL_GLOB 2>/dev/null || true; setopt SH_WORD_SPLIT 2>/dev/null || true; }

BASE_DIR="."
JSON_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)  BASE_DIR="${2:?}"; shift 2 ;;
    --json) JSON_FILE="${2:?}"; shift 2 ;;
    --no-osc8) shift ;; # ignored
    -h|--help)
      cat <<EOF
Usage: $0 [--dir DIR] [--json FILE]
Controls:
  Up/Down       – move selection (left)
  Enter         – open selected article in pager; q to return
  PgUp/PgDn     – scroll preview (right)
  Shift+Up/Down – scroll preview (right)
  j / k         – scroll preview (right)
  Ctrl+U / D    – half-page up/down (right)
  ESC           – quit
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v fzf >/dev/null 2>&1 || { echo "fzf is required." >&2; exit 1; }

find_json() {
  [ -n "${JSON_FILE:-}" ] && { echo "$JSON_FILE"; return; }
  for f in "$BASE_DIR"/articles/*_daily-news.json; do [ -f "$f" ] && { echo "$f"; return; }; done
  for f in "$BASE_DIR"/*_daily-news.json; do [ -f "$f" ] && { echo "$f"; return; }; done
  newest=""; newest_ts=0
  for f in "$BASE_DIR"/.old/*/*_daily-news.json; do
    [ -f "$f" ] || continue
    ts=$( { date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null; } || echo 0 )
    [ "${ts:-0}" -gt "${newest_ts:-0}" ] && { newest="$f"; newest_ts="$ts"; }
  done
  [ -n "$newest" ] && echo "$newest" || :
}

JSON_FILE="$(find_json || true)"
[ -n "${JSON_FILE:-}" ] && [ -f "$JSON_FILE" ] || { echo "No *_daily-news.json found." >&2; exit 1; }

articles_dir="$BASE_DIR/articles"

# Build entries: colored_title<TAB>abs_path<TAB>url
ENTRIES="$(
  awk '
    BEGIN{t="";u="";p=""}
    /"title"[[:space:]]*:/ { if (match($0,/"title"[[:space:]]*:[[:space:]]*"([^"]*)"/,m)) t=m[1] }
    /"url"[[:space:]]*:/   { if (match($0,/"url"[[:space:]]*:[[:space:]]*"([^"]*)"/,m))   u=m[1] }
    /"path"[[:space:]]*:/  { if (match($0,/"path"[[:space:]]*:[[:space:]]*"([^"]*)"/,m))  p=m[1] }
    /\}[[:space:]]*,?[[:space:]]*$/ {
      if (t=="" && u=="" && p=="") next;
      print t "\t" u "\t" p;
      t="";u="";p="";
    }
  ' "$JSON_FILE" |
  while IFS="$(printf '\t')" read -r title url relpath; do
    [ -z "$title" ] && title="(No title)"
    [ -z "$url" ] && url="(No URL)"
    # Resolve path strictly under articles/
    if [ -n "${relpath:-}" ]; then
      case "$relpath" in
        /*) apath="$relpath" ;;
        *)  rel="${relpath#./}"; rel="${rel#articles/}"
            apath="$articles_dir/$rel" ;;
      esac
    else
      slug="${url%/}"; slug="${slug##*/}"
      apath="$articles_dir/$slug.md"
    fi
    # Bold magenta title
    printf '\033[1;35m%s\033[0m\t%s\t%s\n' "$title" "$apath" "$url"
  done
)"
[ -n "$ENTRIES" ] || { echo "JSON parsed empty: $JSON_FILE" >&2; exit 1; }

# Preview helper: show the .md verbatim
PREVIEW_HELPER="$(mktemp -t readnews_preview.XXXXXX)"
cat >"$PREVIEW_HELPER" <<'HP_EOF'
#!/usr/bin/env sh
set -e
apath="${2-}"
if [ -n "${apath:-}" ] && [ -f "$apath" ]; then
  if command -v bat >/dev/null 2>&1; then
    bat --style=plain --paging=never --color=always "$apath"
  elif command -v glow >/dev/null 2>&1; then
    glow -s dark "$apath"
  else
    cat "$apath"
  fi
else
  printf '(missing file: %s)\n' "${apath:-N/A}"
fi
HP_EOF
chmod +x "$PREVIEW_HELPER"
trap 'rm -f "$PREVIEW_HELPER"' EXIT HUP INT TERM

DELIM="$(printf '\t')"

printf '%s\n' "$ENTRIES" | \
  fzf --ansi \
      --with-nth=1 \
      --delimiter="$DELIM" \
      --no-hscroll \
      --preview-window=right:60%:wrap \
      --layout=reverse \
      --border=rounded \
      --height=100% \
      --multi \
      --preview "$PREVIEW_HELPER {1} {2} {3}" \
      --bind "esc:abort" \
      --bind "shift-up:preview-up,shift-down:preview-down" \
      --bind "pgup:preview-page-up,pgdn:preview-page-down" \
      --bind "ctrl-u:preview-half-page-up,ctrl-d:preview-half-page-down" \
      --bind "j:preview-down,k:preview-up" \
      --bind 'enter:execute(
        sh -c "
          f=\${1-}
          if [ -n \"\${f:-}\" ] && [ -f \"\$f\" ]; then
            if command -v bat >/dev/null 2>&1; then
              bat --paging=always --color=always \"\$f\"
            else
              less -R \"\$f\"
            fi
          else
            printf \"(missing file: %s)\n\" \"\${f:-N/A}\" | less -R
          fi
        " _ {2}
      )+refresh-preview'
