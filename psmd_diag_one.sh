#!/usr/bin/env bash
# psmd_diag_one.sh — Robust PSMD Diagnostics (v5.3)
# 
# Author: Julio Cesar Nather Junior
# Date: September 2025
# 
# This script is an automation wrapper for PSMD analysis.
# Original PSMD implementation: https://github.com/miac-research/psmd
# 
# Features:
# - SINGLE or BATCH (PSMD folder/)
# - Checks integrity; sanitizes CRLF and transposes .bvec if necessary
# - Primary PSMD (-p/-d) skipped if 'bc' missing (in ghcr image); on any failure, falls back
# - FALLBACK without bet: b0-threshold + dtifit → PSMD -f/-m
# - PSMD always executed with -w /tmp (avoids "Operation not permitted" in /data/psmdtemp)
# - CSV aggregated in BATCH mode

set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo ">> $*"; }
needs(){ command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

download_mask(){
  local dst="$1"
  local url="https://raw.githubusercontent.com/miac-research/psmd/main/skeleton_mask_2019.nii.gz"
  if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$dst" "$url" || return 1
  elif command -v wget >/dev/null 2>&1; then wget -qO "$dst" "$url" || return 1
  else return 1; fi
}

is_subject_dir(){
  local d="$1"; [ -d "$d" ] || return 1
  local bval bvec nii
  bval="$(ls -1 "$d"/*DTI*.bval 2>/dev/null | head -n1 || true)"
  [ -n "$bval" ] || bval="$(ls -1 "$d"/*.bval 2>/dev/null | head -n1 || true)"
  [ -f "$bval" ] || return 1
  bvec="${bval%.bval}.bvec"; [ -f "$bvec" ] || return 1
  if   [ -f "${bval%.bval}.nii.gz" ]; then nii="${bval%.bval}.nii.gz"
  elif [ -f "${bval%.bval}.nii"    ]; then nii="${bval%.bval}.nii"
  else
    nii="$(ls -1 "$d"/*DTI*.nii* 2>/dev/null | head -n1 || true)"
    [ -n "$nii" ] || nii="$(ls -1 "$d"/*.nii* 2>/dev/null | head -n1 || true)"
  fi
  [ -f "$nii" ] || return 1
  return 0
}

extract_psmd(){ local log="$1"; [ -f "$log" ] || return 1
  local v; v="$(sed -n -E 's/.*PSMD is[[:space:]]*([0-9]+([.][0-9]+)?).*/\1/p' "$log" | tail -n1)"
  [ -n "$v" ] || return 1; printf "%s" "$v"; }

# -------------------- Parameters --------------------
if [ $# -lt 1 ]; then
  echo "Usage: PSMD_MODE=d|p $0 /path/to/PSMD_or_Subject_X [skeleton_mask_2019.nii.gz]" >&2
  exit 1
fi

TARGET_DIR="$(readlink -f "$1")"; [ -d "$TARGET_DIR" ] || die "invalid directory: $TARGET_DIR"
MASK_OVERRIDE="${2:-""}"

PSMD_MODE="${PSMD_MODE:-p}" # d|p
PSMD_IMAGE="${PSMD_IMAGE:-ghcr.io/miac-research/psmd:latest}"
BET_F="${BET_F:-0.30}"      # kept for compatibility (not used in fallback without bet)
OMP_THREADS="${OMP_THREADS:-1}"
JOBS="${JOBS:-1}"

export LC_ALL="${LC_ALL:-C.UTF-8}"; export LANG="${LANG:-C.UTF-8}"
umask 002

needs docker
if ! docker image inspect "$PSMD_IMAGE" >/dev/null 2>&1; then
  info "Downloading PSMD image: $PSMD_IMAGE"; docker pull "$PSMD_IMAGE"
fi

process_one_subject(){
  local SUBJ_DIR="$1"; local MASK_PARAM="${2:-""}"
  (
    set -euo pipefail
    local TS LOG; TS="$(date +%Y%m%d_%H%M%S)"; LOG="$SUBJ_DIR/psmd_diag_${TS}.log"
    exec > >(tee -a "$LOG") 2>&1

    echo "==== PSMD Diagnostics ===="
    echo "Directory: $SUBJ_DIR"
    echo "PSMD_MODE: $PSMD_MODE"
    echo "PSMD_IMAGE: $PSMD_IMAGE"
    echo "BET_F: $BET_F"
    echo "Log: $LOG"
    echo

    # Locate files
    local BVAL BVEC NII
    BVAL="$(ls -1 "$SUBJ_DIR"/*DTI*.bval 2>/dev/null | head -n1 || true)"
    [ -n "$BVAL" ] || BVAL="$(ls -1 "$SUBJ_DIR"/*.bval 2>/dev/null | head -n1 || true)"
    [ -f "$BVAL" ] || die ".bval not found"
    BVEC="${BVAL%.bval}.bvec"; [ -f "$BVEC" ] || die "corresponding .bvec not found: $BVEC"

    # --- find correct NIfTI, avoiding *.nii.bval / *.nii.bvec ---
    NII=""
    # 1) If .bval is of type *.nii.bval, try corresponding "stem"
    STEM="${BVAL%.bval}"      # remove only .bval suffix
    STEM="${STEM%.}"          # remove leftover dot, if any (case *.nii.bval -> *.nii.)
    if   [ -f "$STEM" ]; then NII="$STEM"
    elif [ -f "${STEM}.gz" ]; then NII="${STEM}.gz"
    fi

    # 2) Prefer names with "DTI" (only .nii.gz / .nii)
    if [ -z "$NII" ]; then
      for pat in "$SUBJ_DIR"/*[Dd][Tt][Ii]*.nii.gz "$SUBJ_DIR"/*[Dd][Tt][Ii]*.nii; do
        [ -f "$pat" ] && { NII="$pat"; break; }
      done
    fi

    # 3) Generic in folder (only .nii.gz / .nii)
    if [ -z "$NII" ]; then
      for pat in "$SUBJ_DIR"/*.nii.gz "$SUBJ_DIR"/*.nii; do
        [ -f "$pat" ] && { NII="$pat"; break; }
      done
    fi

    # 4) Extra safety: reject false-positives
    case "$NII" in
      *.nii.bval|*.nii.bvec) NII="";;
    esac

    [ -n "$NII" ] && [ -f "$NII" ] || die "NIfTI not found (avoided *.nii.bval/*.nii.bvec)"

    # Mask
    local MASK_PATH; if [ -n "$MASK_PARAM" ]; then MASK_PATH="$MASK_PARAM"; else MASK_PATH="$SUBJ_DIR/skeleton_mask_2019.nii.gz"; fi
    if [ ! -f "$MASK_PATH" ]; then
      local PARENT_MASK; PARENT_MASK="$(ls -1 "$(dirname "$SUBJ_DIR")"/skeleton_mask_2019.nii.gz 2>/dev/null || true)"
      if [ -f "$PARENT_MASK" ]; then cp -f "$PARENT_MASK" "$MASK_PATH"
      else info "Downloading mask to: $MASK_PATH"; download_mask "$MASK_PATH" || die "could not obtain mask"; fi
    fi

    # Clean/bvec transposition
    local BVAL_CLEAN BVEC_CLEAN; BVAL_CLEAN="$SUBJ_DIR/$(basename "$BVAL").clean"; BVEC_CLEAN="$SUBJ_DIR/$(basename "$BVEC").clean"
    cp -f "$BVAL" "$BVAL_CLEAN"; cp -f "$BVEC" "$BVEC_CLEAN"; sed -i 's/\r$//' "$BVAL_CLEAN" "$BVEC_CLEAN" 2>/dev/null || true
    local BVEC_LINES BVEC_COLS; BVEC_LINES="$(awk 'END{print NR+0}' "$BVEC_CLEAN" 2>/dev/null || echo 0)"
    BVEC_COLS="$(awk '{print NF; exit}' "$BVEC_CLEAN" 2>/dev/null || echo 0)"
    if [ "${BVEC_LINES:-0}" -ne 3 ] && [ "${BVEC_COLS:-0}" -eq 3 ]; then
      info ".bvec $BVEC_LINES x $BVEC_COLS; transposing to 3xN..."
      awk '{for(i=1;i<=NF;i++) a[i,NR]=$i} END{for(i=1;i<=NF;i++){for(j=1;j<=NR;j++){printf "%s%s", a[i,j], (j<NR?" ":"\n")}}}' \
        "$BVEC_CLEAN" > "${BVEC_CLEAN}.tmp" && mv "${BVEC_CLEAN}.tmp" "$BVEC_CLEAN"
    fi

    local NII_BN BVAL_CLEAN_BN BVEC_CLEAN_BN MASK_BN
    NII_BN="$(basename "$NII")"; BVAL_CLEAN_BN="$(basename "$BVAL_CLEAN")"; BVEC_CLEAN_BN="$(basename "$BVEC_CLEAN")"; MASK_BN="$(basename "$MASK_PATH")"

    # Integrity
    echo "---- INTEGRITY ----"
    docker run --rm --entrypoint bash -e LC_ALL=C.UTF-8 \
      -v "$SUBJ_DIR":/data -w /data "$PSMD_IMAGE" -lc "
set -e
echo -n 'NIfTI dim4................: '; fslval '$NII_BN' dim4
echo -n '#bvals....................: '; wc -w < '$BVAL_CLEAN_BN'
echo -n 'bvec lines (expect=3)....: '; awk 'END{print NR+0}' '$BVEC_CLEAN_BN'
echo -n 'bvec columns (== dim4)...: '; awk '{print NF; exit}' '$BVEC_CLEAN_BN'
echo -n '#b0 (b<50)................: '; awk '{c=0; for(i=1;i<=NF;i++){ if(\$i+0<50) c++ }} END{print c}' '$BVAL_CLEAN_BN'
" || die "failed to query integrity with FSL"
    echo

    # Pre-check for -p mode
    echo "---- IMAGE PRE-CHECK ----"
    local SKIP_PRIMARY=0
    docker run --rm --entrypoint bash "$PSMD_IMAGE" -lc 'command -v bc >/dev/null || echo NO_BC' \
      | tee "$SUBJ_DIR/psmd_precheck.txt" >/dev/null
    grep -q NO_BC "$SUBJ_DIR/psmd_precheck.txt" && { info "bc missing: skipping -p mode"; SKIP_PRIMARY=1; }

    local MODE_LOG RC_P=1
    if [ "$SKIP_PRIMARY" -eq 0 ]; then
      echo "---- PSMD (mode -$PSMD_MODE) ----"
      MODE_LOG="$SUBJ_DIR/psmd_mode_${PSMD_MODE}.log"
      set +e
      if [ "$PSMD_MODE" = "p" ]; then
        local NII_PP_BN="${NII_BN%.nii.gz}_pp.nii.gz"; [ -f "$SUBJ_DIR/$NII_PP_BN" ] || NII_PP_BN="$NII_BN"
        info "psmd -p /data/$NII_PP_BN ..."
        docker run --rm -e OMP_NUM_THREADS="$OMP_THREADS" -e LC_ALL=C.UTF-8 \
          -v "$SUBJ_DIR":/data -w /tmp "$PSMD_IMAGE" \
          -p "/data/$NII_PP_BN" -b "/data/$BVAL_CLEAN_BN" -r "/data/$BVEC_CLEAN_BN" -s "/data/$MASK_BN" -v -t \
          | tee "$MODE_LOG"
        RC_P=${PIPESTATUS[0]}
      else
        info "psmd -d /data/$NII_BN ..."
        docker run --rm -e OMP_NUM_THREADS="$OMP_THREADS" -e LC_ALL=C.UTF-8 \
          -v "$SUBJ_DIR":/data -w /tmp "$PSMD_IMAGE" \
          -d "/data/$NII_BN" -b "/data/$BVAL_CLEAN_BN" -r "/data/$BVEC_CLEAN_BN" -s "/data/$MASK_BN" -v -t \
          | tee "$MODE_LOG"
        RC_P=${PIPESTATUS[0]}
      fi
      set -e
      if grep -Eq 'Aborted|No image files match|Failed to read volume|cannot access .?origdata/' "$MODE_LOG"; then info "Failure detection in log."; RC_P=2; fi
      if ! grep -Eq 'PSMD is[[:space:]]*[0-9]+([.][0-9]+)?' "$MODE_LOG"; then info "No numeric value after \"PSMD is\"."; RC_P=3; fi
      echo ">> PSMD (-$PSMD_MODE) exit code (adjusted): ${RC_P:-NA}"; echo
    else
      info "Primary mode not executed (missing dependencies)."
    fi

    # FALLBACK — b0-threshold + dtifit → PSMD -f/-m
    if [ "${RC_P:-1}" -ne 0 ]; then
      echo "---- FALLBACK (b0-threshold → dtifit → PSMD -f/-m) ----"
      local first_b0; first_b0="$(awk '{for(i=1;i<=NF;i++){ if($i+0<50){ print (i-1); exit } }}' "$BVAL_CLEAN" || true)"
      [ -z "$first_b0" ] && first_b0=0; info "first_b0 = $first_b0"

      docker run --rm --entrypoint bash \
        -e OMP_NUM_THREADS="$OMP_THREADS" -e LC_ALL=C.UTF-8 \
        -v "$SUBJ_DIR":/data -w /data "$PSMD_IMAGE" -lc "
set -euo pipefail
export FSLOUTPUTTYPE=NIFTI_GZ
for c in fslroi fslmaths fslstats dtifit; do
  command -v \"\$c\" >/dev/null || { echo \"ERROR: \$c unavailable in container\"; exit 98; }
done
echo rwtest > .rw && rm -f .rw
fslroi '$NII_BN' b0 $first_b0 1
p02=\$(fslstats b0 -P 2); p98=\$(fslstats b0 -P 98)
thr=\$(awk -v a=\"\$p02\" -v b=\"\$p98\" 'BEGIN{printf(\"%.6f\", a+0.20*(b-a))}')
echo \"P02=\$p02   P98=\$p98   thr=\$thr\"
fslmaths b0 -thr \$thr -bin b0_mask0
fslmaths b0_mask0 -dilM -ero -dilM b0_brain_mask
vox=\$(fslstats b0_brain_mask -V | awk '{print \$1+0}')
if [ \"\$vox\" -lt 1000 ]; then
  echo \"Small mask (\$vox voxels) → using -thrP 10\"
  fslmaths b0 -thrP 10 -bin -dilM -ero b0_brain_mask
fi
dtifit -k '$NII_BN' -o dti -m b0_brain_mask -r '$BVEC_CLEAN_BN' -b '$BVAL_CLEAN_BN' -V
ls -lh dti_FA.* dti_MD.* b0_brain_mask.* || true
" || die "fallback (threshold) failed"

      # Select files on host and map to /data
      local FA_HOST_GZ="$SUBJ_DIR/dti_FA.nii.gz" FA_HOST_NI="$SUBJ_DIR/dti_FA.nii"
      local MD_HOST_GZ="$SUBJ_DIR/dti_MD.nii.gz" MD_HOST_NI="$SUBJ_DIR/dti_MD.nii"
      local FA_OPT MD_OPT
      if   [ -f "$FA_HOST_GZ" ]; then FA_OPT="/data/dti_FA.nii.gz"
      elif [ -f "$FA_HOST_NI" ]; then FA_OPT="/data/dti_FA.nii"
      else die "dti_FA not found after fallback"; fi
      if   [ -f "$MD_HOST_GZ" ]; then MD_OPT="/data/dti_MD.nii.gz"
      elif [ -f "$MD_HOST_NI" ]; then MD_OPT="/data/dti_MD.nii"
      else die "dti_MD not found after fallback"; fi

      info "PSMD (-f/-m): $FA_OPT | $MD_OPT"
      docker run --rm -e OMP_NUM_THREADS="$OMP_THREADS" -e LC_ALL=C.UTF-8 \
        -v "$SUBJ_DIR":/data -w /tmp "$PSMD_IMAGE" \
        -f "$FA_OPT" -m "$MD_OPT" -s "/data/$MASK_BN" -v -t \
        | tee "$SUBJ_DIR/psmd_mode_fm.log"

      grep -Eq 'PSMD is[[:space:]]*[0-9]+([.][0-9]+)?' "$SUBJ_DIR/psmd_mode_fm.log" \
        || die "PSMD not obtained in fallback"
    else
      info "Fallback not executed."
    fi

    echo "==== End of diagnostics ===="
    echo "Send this log if you need support: $LOG"
  )
}

# -------------------- SINGLE or BATCH --------------------
if is_subject_dir "$TARGET_DIR"; then
  process_one_subject "$TARGET_DIR" "$MASK_OVERRIDE"; exit 0
fi

ROOT_DIR="$TARGET_DIR"; info "BATCH mode detected. Root folder: $ROOT_DIR"
mapfile -t SUBJECT_DIRS < <(find "$ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
SUBJECT_DIRS_VALID=(); for d in "${SUBJECT_DIRS[@]}"; do is_subject_dir "$d" && SUBJECT_DIRS_VALID+=("$d"); done
TOTAL="${#SUBJECT_DIRS_VALID[@]}"; [ "$TOTAL" -gt 0 ] || die "no valid subjects in: $ROOT_DIR"
info "Subjects detected: $TOTAL"; echo

JOBS=$((JOBS<1?1:JOBS)); info "JOBS = $JOBS"; running=0; processed=0
for subj in "${SUBJECT_DIRS_VALID[@]}"; do
  processed=$((processed+1)); echo "Starting [$processed/$TOTAL]: $(basename "$subj")"
  ( process_one_subject "$subj" "$MASK_OVERRIDE" ) &
  running=$((running+1))
  if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running-1)); fi
done
wait

echo; info "All subjects finished. Consolidating results..."
RESULTS_CSV="$ROOT_DIR/psmd_results.csv"; TMP_CSV="$ROOT_DIR/.psmd_results.tmp"
echo "subject,mode,method,psmd,primary_log,fallback_log,diag_log" > "$TMP_CSV"
success=0; fallback_ok=0; fail=0
for subj in "${SUBJECT_DIRS_VALID[@]}"; do
  sid="$(basename "$subj")"
  primary_log="$subj/psmd_mode_${PSMD_MODE}.log"
  fallback_log="$subj/psmd_mode_fm.log"
  diag_log="$(ls -1 "$subj"/psmd_diag_*.log 2>/dev/null | tail -n1 || true)"
  val=""; method="fail"
  if [ -f "$primary_log" ]; then
    val="$(extract_psmd "$primary_log" || true)"; [ -n "$val" ] && method="primary"
  fi
  if [ "$method" = "fail" ] && [ -f "$fallback_log" ]; then
    val="$(extract_psmd "$fallback_log" || true)"; [ -n "$val" ] && method="fallback"
  fi
  if [ "$method" != "fail" ]; then success=$((success+1)); [ "$method" = "fallback" ] && fallback_ok=$((fallback_ok+1))
  else fail=$((fail+1)); fi
  printf "%s,%s,%s,%s,%s,%s,%s\n" "$sid" "$PSMD_MODE" "$method" "${val:-}" "$primary_log" "$fallback_log" "${diag_log:-}" >> "$TMP_CSV"
done
mv -f "$TMP_CSV" "$RESULTS_CSV"
echo; info "Summary:"; echo "  Total success........: $success / $TOTAL"
echo "   └─ via fallback.....: $fallback_ok"; echo "  Failures............: $fail"
echo "CSV generated: $RESULTS_CSV"
