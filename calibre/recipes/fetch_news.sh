#!/usr/bin/env bash
set -euo pipefail

# --- Dates ---
DATE=$(date +%Y-%m-%d)                                   # safe for filenames
TITLEDATE=$(LC_TIME=fr_FR.UTF-8 date +"%A %d %B %Y" || date +"%A %d %B %Y")

# --- Output / defaults ---
OUTDIR="/output"
LOGDIR="${OUTDIR}/logs"
DEFAULT_PROFILE="kobo"                                   # tuned for Kobo (Libra Color)
mkdir -p "$OUTDIR" "$LOGDIR"

# Optional readability tweaks for news (kept very light)
EXTRA_CSS=$'html, body { margin: 0; }\nbody { line-height: 1.35; }\np { margin: 0 0 0.6em 0; }\nfigure { margin: 0; }\nimg, figure img, .article img { width: 100% !important; max-width: 100% !important; height: auto !important; }'


run_recipe() {
  local recipe="$1" slug="$2" title="$3" profile="${4:-$DEFAULT_PROFILE}"
  local outfile="${OUTDIR}/${slug}_${DATE}.epub"
  local full_title="${title} (${TITLEDATE})"
  local log="${LOGDIR}/${slug}.log"

  echo "[INFO] $(date -Is) Fetching: $recipe -> $outfile" | tee -a "$log"

  convert_once() {
    local prof="$1"
    if [[ -f "/recipes/$recipe" ]]; then
      ebook-convert "/recipes/$recipe" "$outfile" \
        --title "$full_title" --output-profile "$prof" \
        --extra-css "$EXTRA_CSS" >> "$log" 2>&1
    else
      ebook-convert "$recipe" "$outfile" \
        --title "$full_title" --output-profile "$prof" \
        --extra-css "$EXTRA_CSS" >> "$log" 2>&1
    fi
  }

  if convert_once "$profile"; then
    echo "[OK] $(date -Is) Done: $outfile" | tee -a "$log"
    return 0
  fi

  if [[ "$profile" == "kobo" ]]; then
    echo "[WARN] $(date -Is) Kobo profile failed, retrying with 'tablet'…" | tee -a "$log"
    if convert_once "tablet"; then
      echo "[OK] $(date -Is) Done with fallback profile: $outfile" | tee -a "$log"
      return 0
    fi
  fi

  echo "[ERROR] $slug failed" | tee -a "$log"
  return 1
}

# --- Sources ---
SOURCES=(
  "Korben.recipe|korben|Korben|kobo"
  "Zérodeux.recipe|zerodeux|Zérodeux|kobo"
  "Good e-Reader.recipe|goodereader|Good e-Reader|kobo"
  "Psychology Today.recipe|psychologytoday|Psychology Today|kobo"
  "TIME Magazine.recipe|time|TIME Magazine|kobo"
  "National Geographic.recipe|natgeo|National Geographic|kobo"
  "National Geographic Traveller.recipe|natgeotraveller|National Geographic Traveller|kobo"
  "National Geographic Magazine.recipe|natgeomag|National Geographic Magazine|kobo"
  "Le Monde.recipe|lemonde|Le Monde|kobo"
  "Libération.recipe|liberation|Libération|kobo"
  "Science News.recipe|sciencenews|Science News|kobo"
  "The Skeptic.recipe|theskeptic|The Skeptic|kobo"
  "Wired Magazine, Monthly Edition.recipe|wiredmonthly|Wired Magazine, Monthly Edition|kobo"
  "VOX.recipe|vox|Vox|kobo"
)

# --- Run all sources ---
fail=0
for entry in "${SOURCES[@]}"; do
  IFS='|' read -r recipe slug title profile <<<"$entry"
  run_recipe "$recipe" "$slug" "$title" "$profile" || fail=$((fail+1))
done

if (( fail > 0 )); then
  echo "[DONE] Completed with $fail failure(s). Check logs under $LOGDIR."
else
  echo "[DONE] All sources fetched successfully."
fi
