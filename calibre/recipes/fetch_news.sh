#!/usr/bin/env bash
set -euo pipefail

# --- Dates ---
DATE=$(date +%Y-%m-%d)                                   # ISO for comparisons/logs
TITLEDATE=$(LC_TIME=fr_FR.UTF-8 date +"%A %d %B %Y" || date +"%A %d %B %Y")
DOW=$(date +%u)       # 1=Mon .. 7=Sun
DOM=$(date +%d)       # 01..31
MON=$(date +%m)       # 01..12
DOM10=$((10#$DOM))
MON10=$((10#$MON))

# --- Output / defaults ---
OUTDIR="/output"
LOGDIR="${OUTDIR}/logs"
DEFAULT_PROFILE="kobo"                                   # tuned for Kobo (Libra Color)
mkdir -p "$OUTDIR" "$LOGDIR"

# Optional readability tweaks for news (kept very light)
EXTRA_CSS=$'html, body { margin: 0; }\nbody { line-height: 1.35; }\np { margin: 0 0 0.6em 0; }\nfigure { margin: 0; }\nimg, figure img, .article img { width: 100% !important; max-width: 100% !important; height: auto !important; }'

# --- Helpers for scheduling ---
is_even_month() { (( MON10 % 2 == 0 )); }

contains_slug() {
  local needle="$1" hay="${2:-}"
  [[ -n "$hay" ]] && [[ ",${hay}," == *",${needle},"* ]]
}

SKIP_REASON=""
should_run() {
  local slug="$1"

  # Force flags
  if [[ "${FORCE_ALL:-0}" == "1" ]] || contains_slug "$slug" "${FORCE_SLUGS:-}"; then
    SKIP_REASON=""
    return 0
  fi

  case "$slug" in
    # Quotidiens
    korben|lemonde|liberation|vox)
      SKIP_REASON=""
      return 0
      ;;

    # Hebdos
    goodereader)
      if (( DOW == 1 )); then
        SKIP_REASON=""
        return 0
      else
        SKIP_REASON="hebdomadaire: prévu le lundi (aujourd'hui DOW=${DOW})"
        return 1
      fi
      ;;
    time)
      if (( DOW == 5 )); then
        SKIP_REASON=""
        return 0
      else
        SKIP_REASON="hebdomadaire: TIME sort le vendredi"
        return 1
      fi
      ;;

    # Mensuels (1re semaine du mois)
    natgeo|natgeomag|wiredmonthly)
      if (( DOM10 >= 1 && DOM10 <= 7 )); then
        SKIP_REASON=""
        return 0
      else
        SKIP_REASON="mensuel: déclenché pendant la 1re semaine du mois"
        return 1
      fi
      ;;

    # Bimestriels (mois pairs, jours 1 et 15)
    zerodeux|psychologytoday|natgeotraveller)
      if is_even_month && { (( DOM10 == 1 )) || (( DOM10 == 15 )); }; then
        SKIP_REASON=""
        return 0
      else
        SKIP_REASON="bimestriel: mois pairs (02,04,06,08,10,12), jours 1 ou 15"
        return 1
      fi
      ;;

    # The Skeptic
    theskeptic)
     if (( DOM10 == 1 || DOM10 == 15 )); then
        SKIP_REASON=""
        return 0
     else
        SKIP_REASON=" hors jours 1/15"
        return 1
     fi
      ;;

    *)
      # Par défaut: ne pas bloquer
      SKIP_REASON="règle inconnue: exécuté par défaut"
      return 0
      ;;
  esac
}

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

  # Retry loop with backoff on 429
  local tries=0 max=3 sleep_s=60
  while :; do
    if convert_once "$profile"; then
      echo "[OK] $(date -Is) Done: $outfile" | tee -a "$log"
      break
    fi
    if grep -q "HTTP Error 429" "$log"; then
      ((++tries))
      if (( tries >= max )); then
        echo "[ERROR] $(date -Is) $slug: giving up after $tries tries" | tee -a "$log"
        return 1
      fi
      echo "[WARN] $(date -Is) $slug: 429 detected, sleeping ${sleep_s}s then retrying…" | tee -a "$log"
      sleep "$sleep_s"
      sleep_s=$(( sleep_s * 2 ))   # 60 -> 120 -> 240
      continue
    fi
    # Non-429 failure: stop here (garde ton fallback éventuel séparé si besoin)
    break
  done
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
  "Liberation.recipe|liberation|Libération|kobo"
  "The Skeptic.recipe|theskeptic|The Skeptic|kobo"
  "Wired Magazine, Monthly Edition.recipe|wiredmonthly|Wired Magazine, Monthly Edition|kobo"
  "VOX.recipe|vox|Vox|kobo"
)

# --- Run according to schedule ---
fail=0 ran=0 skipped=0
for entry in "${SOURCES[@]}"; do
  # Décomposition sans read/here-string (à l'épreuve de set -e/pipefail)
  recipe=${entry%%|*}
  rest=${entry#*|}
  slug=${rest%%|*}
  rest=${rest#*|}
  title=${rest%%|*}
  profile=${rest#*|}

  if should_run "$slug"; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      echo "[PLAN] $(date -Is) Would run: $slug ($title)"
    else
      run_recipe "$recipe" "$slug" "$title" "$profile" || fail=$((fail+1))
    fi
    ((++ran))
  else
    echo "[SKIP] $(date -Is) $slug: $SKIP_REASON"
    ((++skipped))
  fi
done


# --- Move today's EPUBs into a per-day folder (replace-or-skip), robust ---
DAYDIR="${OUTDIR}/${DATE}"
mkdir -p "$DAYDIR" "/output/logs"

echo "[INFO] $(date -Is) Scanning for today's EPUBs in ${OUTDIR} (pattern *_${DATE}.epub)"
moved=0 skipped_mv=0 errors=0

set +e  # prevent set -e from killing the whole script on one failure
while IFS= read -r -d '' f; do
  base="${f##*/}"
  dest="${DAYDIR}/${base}"

  if [[ -e "$dest" ]]; then
    # 1) Identique ? (check rapide par taille puis cmp)
    if [[ $(stat -c %s -- "$f") -eq $(stat -c %s -- "$dest") ]] && cmp -s -- "$f" "$dest"; then
      echo "[SAME] $(date -Is) ${base} déjà à jour dans ${DAYDIR} (suppression de la copie source)"
      rm -f -- "$f" 2>>"/output/logs/move_${DATE}.err" || echo "[WARN] $(date -Is) impossible de supprimer la source: $f"
      ((++skipped_mv))
      continue
    fi

    # 2) Différent -> on remplace
    echo "[REPL] $(date -Is) ${f} -> ${dest} (remplacement)"
    if mv -f -- "$f" "$dest" 2>>"/output/logs/move_${DATE}.err"; then
      ((++moved))
    else
      echo "[ERR ] $(date -Is) Échec remplacement: ${f} (voir logs/move_${DATE}.err)"
      ((++errors))
    fi

  else
    # Destination absente -> simple move
    echo "[MOVE] $(date -Is) ${f} -> ${dest}"
    if mv -- "$f" "$dest" 2>>"/output/logs/move_${DATE}.err"; then
      ((++moved))
    else
      echo "[ERR ] $(date -Is) Échec move: ${f} (voir logs/move_${DATE}.err)"
      ((++errors))
    fi
  fi
done < <(find "$OUTDIR" -maxdepth 1 -type f -name "*_${DATE}.epub" -print0)
set -e

echo "[OK]  $(date -Is) Daily folder: ${DAYDIR} (moved=${moved}, skipped=${skipped_mv}, errors=${errors})"
echo "[INFO] $(date -Is) Contents of ${DAYDIR}:"
ls -1 "${DAYDIR}" || true

# --- Summary ---
if (( fail > 0 )); then
  echo "[DONE] Completed with $fail failure(s). Ran=${ran}, Skipped=${skipped}. Check logs under $LOGDIR."
else
  echo "[DONE] All scheduled sources processed. Ran=${ran}, Skipped=${skipped}."
fi
