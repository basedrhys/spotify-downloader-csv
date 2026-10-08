#!/usr/bin/env zsh
#
# Download DJ playlists from Chosic CSV exports into their iCloud folders.
#
# Usage:  ./scripts/download-playlists.zsh [playlist-key ...]
#
# With no arguments, every playlist below is processed. Pass one or more folder
# keys to do a subset, e.g.:
#
#     ./scripts/download-playlists.zsh jersey_club misc_dj
#
# Re-running is safe: spotdl skips songs whose output file already exists, so
# only missing tracks are fetched.
#
# See docs/youtube-download-findings.md for why player_client=web_embedded is
# needed and what to do if downloads start failing again.

set -u
setopt no_nomatch

REPO="${0:A:h:h}"
cd "$REPO" || { print -u2 "cannot cd to repo: $REPO"; exit 1 }

DOWNLOADS="${SPOTDL_CSV_DIR:-$HOME/Downloads}"
OUTPUT_ROOT="${SPOTDL_OUTPUT_ROOT:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/DJ Music/spotdl}"
LOG_DIR="${SPOTDL_LOG_DIR:-$REPO/.spotdl-logs}"

# Passed explicitly rather than relying on ~/.spotdl/config.json, so this script
# still works on a machine where that config has not been set up. YouTube's PO
# Token experiment breaks the default web_music client.
YTDLP_ARGS='--extractor-args "youtube:player_client=web_embedded"'

# folder_key <TAB> csv filename
typeset -a PLAYLISTS
PLAYLISTS=(
  "ecstasy_house	Ecstacy House.csv"
  "misc_dj	Misc. DJ .csv"
  "trenning_music	trenning music.csv"
  "jersey_club	Jersey Club.csv"
  "heavy_edm	Library_ Heavy EDM.csv"
  "early_evening_house	Early Evening House.csv"
)

count_files() {
  [[ -d "$1" ]] && print -r -- "$(ls -1 "$1" 2>/dev/null | wc -l | tr -d ' ')" || print -r -- 0
}

# Resolve which playlists to run.
typeset -a SELECTED
if (( $# )); then
  for want in "$@"; do
    local matched=0
    for entry in "${PLAYLISTS[@]}"; do
      [[ "${entry%%$'\t'*}" == "$want" ]] && { SELECTED+=("$entry"); matched=1 }
    done
    (( matched )) || { print -u2 "unknown playlist key: $want"; exit 2 }
  done
else
  SELECTED=("${PLAYLISTS[@]}")
fi

command -v uv >/dev/null || { print -u2 "uv not found on PATH"; exit 1 }
command -v ffmpeg >/dev/null || print -u2 "warning: ffmpeg not on PATH; spotdl may fail to convert"
command -v deno >/dev/null || print -u2 "warning: deno not on PATH; yt-dlp cannot solve JS challenges"

mkdir -p "$LOG_DIR"

typeset -a SUMMARY
overall=0

for entry in "${SELECTED[@]}"; do
  key="${entry%%$'\t'*}"
  csv="${entry#*$'\t'}"
  csv_path="$DOWNLOADS/$csv"
  out_dir="$OUTPUT_ROOT/$key"
  log="$LOG_DIR/$key.log"

  print -r -- ""
  print -r -- "=============================================================="
  print -r -- "  $key"
  print -r -- "  csv: $csv_path"
  print -r -- "  out: $out_dir"
  print -r -- "=============================================================="

  if [[ ! -f "$csv_path" ]]; then
    print -u2 -r -- "  SKIP: CSV not found"
    SUMMARY+=("$key	SKIPPED (no CSV)	-")
    overall=1
    continue
  fi

  before=$(count_files "$out_dir")

  if [[ -n "${SPOTDL_DRY_RUN:-}" ]]; then
    print -r -- "  DRY RUN, would execute:"
    print -r -- "    uv run spotdl download ${(q)csv_path} --output ${(q)out_dir} --yt-dlp-args ${(q)YTDLP_ARGS}"
    SUMMARY+=("$key	dry-run	$before files already present")
    continue
  fi

  mkdir -p "$out_dir"

  uv run spotdl download "$csv_path" \
    --output "$out_dir" \
    --yt-dlp-args "$YTDLP_ARGS" 2>&1 | tee "$log"
  rc=${pipestatus[1]}

  after=$(count_files "$out_dir")
  added=$(( after - before ))
  errors=$(grep -c 'Error\|error -' "$log" 2>/dev/null | tr -d ' ')

  if (( rc == 0 )); then
    SUMMARY+=("$key	ok	+$added new, $after total, $errors error lines")
  else
    SUMMARY+=("$key	EXIT $rc	+$added new, $after total, $errors error lines")
    overall=1
  fi
done

print -r -- ""
print -r -- "=============================================================="
print -r -- "  Summary"
print -r -- "=============================================================="
printf '%s\n' "${SUMMARY[@]}" | column -t -s $'\t'
print -r -- ""
print -r -- "Logs: $LOG_DIR"
(( overall )) && print -r -- "One or more playlists reported problems; check the logs above."

exit $overall
