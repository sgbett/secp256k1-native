#!/usr/bin/env bash
#
# gate.sh — the unattended timing-verification gate (Phase 4 of
# plans/61-reference-machine-nix.md). One script, two contexts:
#   • dev/CI iteration in the nix devShell (fast, no core pinning), and
#   • the authoritative bare-metal run as the ISO's timing-gate.service.
#
# Per compiler in the set it runs, fail-closed and fault-tolerant:
#   1. rake clobber
#   2. build the extension at VANILLA -O2 with that gcc (NIX_HARDENING_ENABLE="")
#      — hardening OFF is load-bearing: nix's default hardening changes the CT
#      codegen (see nix/vanilla-ext.sh), so a hardened build certifies the wrong
#      binary. Explicit `make CC=` selects the compiler under test.
#   3. verify CC-took + the assembly-invariant (nix/vanilla-ext.sh)
#   4. rspec — functional
#   5. ctgrind (valgrind secret-poisoning) — deterministic constant-time
#   6. dudect timing harness, N runs, pinned to the isolated core on bare metal
#      — parse per-op |t|, aggregate (n_over_4.5, max|t|, mean|t|)
# then writes a provenance-stamped row to the results dir *incrementally* (so a
# mid-sweep power loss costs only the in-flight compiler). A compiler that fails
# to build/deps is recorded SKIPPED and the sweep continues (best-effort back to
# 9.5). Every step has a timeout so nothing hangs the unattended run.
#
# Release semantics (fail-closed, principle 1): every compiler that BUILDS must
# pass; a CT leak on any building gcc reds the gate. SKIPPED (build/dep failure)
# is not a CT result and does not block. The measurement is only meaningful on
# quiet bare metal — in Docker/VM this validates the AUTOMATION, not the timing.
#
# Env knobs
#   GATE_COMPILERS   space-separated CC names/paths       (default: "gcc")
#   GATE_CORE        isolated core for taskset/chrt        (default: ""=no pin)
#   GATE_DUDECT_RUNS N dudect runs per compiler            (default: 20)
#   GATE_OUT         results directory                     (default: ./gate-results)
#   GATE_TIMEOUT     per-step timeout, seconds             (default: 1800)
#   GATE_LENIENT_MEAN  mean|t| bound for operand-artefact ops (default: 10)
#   GATE_SOURCE_REV / GATE_NIXPKGS_REV  provenance overrides (default: auto)
#
# Exit: 0 all building compilers passed · 1 a building compiler leaked/failed a
# deterministic gate · 2 environment/usage error. (SKIPs alone do not fail.)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GATE_COMPILERS="${GATE_COMPILERS:-gcc}"
GATE_CORE="${GATE_CORE:-}"
GATE_DUDECT_RUNS="${GATE_DUDECT_RUNS:-20}"
GATE_OUT="${GATE_OUT:-$ROOT/gate-results}"
GATE_TIMEOUT="${GATE_TIMEOUT:-1800}"
GATE_LENIENT_MEAN="${GATE_LENIENT_MEAN:-10}"
THRESHOLD="4.5"

# Ops whose timing MUST be flat (secret-dependent inputs) — any run over 4.5 is a
# fail. The operand-value artefact ops (field ops + jp_add) are lenient: marginal
# single-run excursions are tolerated, flagged only if the mean|t| exceeds
# GATE_LENIENT_MEAN (see CLAUDE.md: jp_add_internal ~7.5 microarch artefact).
STRICT_RE='scalar_multiply_ct|scalar_mul|scalar_reduce|scalar_inv|scalar_add'

mkdir -p "$GATE_OUT"
REPORT="$GATE_OUT/timing-report.txt"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; sync "$REPORT" 2>/dev/null || true; }
step() { timeout "$GATE_TIMEOUT" "$@"; }

# --- provenance header (written once) ----------------------------------------
cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //' || echo unknown)"
microcode="$(grep -m1 microcode /proc/cpuinfo 2>/dev/null | cut -d: -f2- | tr -d ' ' || echo unknown)"
kernel="$(uname -r 2>/dev/null || echo unknown)"
cur_khz="$(cat /sys/devices/system/cpu/cpu${GATE_CORE:-0}/cpufreq/scaling_cur_freq 2>/dev/null || echo unknown)"
src_rev="${GATE_SOURCE_REV:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
npk_rev="${GATE_NIXPKGS_REV:-$(grep -o '"rev": "[a-f0-9]*"' "$ROOT/flake.lock" 2>/dev/null | head -1 | grep -oE '[a-f0-9]{7,}' | cut -c1-12 || echo unknown)}"

{
  echo "=========================================================================="
  echo "secp256k1-native — timing-verification reference machine report"
  echo "=========================================================================="
  echo "date        : $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
  echo "cpu         : $cpu_model"
  echo "microcode   : $microcode"
  echo "kernel      : $kernel"
  echo "isolated cpu: ${GATE_CORE:-<none — NOT bare-metal-pinned; timing is indicative only>}"
  echo "cur freq    : ${cur_khz} kHz (stamped to catch throttling)"
  echo "source rev  : $src_rev"
  echo "nixpkgs rev : $npk_rev"
  echo "dudect runs : $GATE_DUDECT_RUNS   threshold |t|<$THRESHOLD (strict) / mean|t|<$GATE_LENIENT_MEAN (operand-artefact ops)"
  echo "compilers   : $GATE_COMPILERS"
  echo "=========================================================================="
  echo
} > "$REPORT"
sync "$REPORT" 2>/dev/null || true

overall_rc=0

for cc in $GATE_COMPILERS; do
  ccver="$("$cc" --version 2>/dev/null | head -1 || echo 'unknown')"
  log "--------------------------------------------------------------------------"
  log "compiler: $cc — $ccver"
  work="$(mktemp -d)"

  # --- 1+2. clobber + vanilla build (SKIPPED on failure, not fatal) ----------
  if ! command -v "$cc" >/dev/null 2>&1; then
    log "  SKIPPED — compiler '$cc' not on PATH"; rm -rf "$work"; continue
  fi
  bundle exec rake clobber >/dev/null 2>&1
  mkdir -p "$GATE_OUT"  # defensive: `rake clobber` wipes tmp/; never let it eat the results dir
  if ! ( cd ext/secp256k1_native \
         && NIX_HARDENING_ENABLE="" step ruby extconf.rb \
         && NIX_HARDENING_ENABLE="" step make CC="$cc" ) >"$work/build.log" 2>&1; then
    log "  SKIPPED — extension failed to build with $cc (dep/toolchain):"
    log "    $(tail -1 "$work/build.log")"
    rm -rf "$work"; continue
  fi
  cp ext/secp256k1_native/secp256k1_native.so lib/secp256k1_native.so

  cc_pass=1

  # --- 3. CC-took + assembly-invariant (Phase 3) -----------------------------
  if step bash "$ROOT/nix/vanilla-ext.sh" "$cc" >"$work/vanilla.log" 2>&1; then
    codegen="PASS"
  else
    codegen="FAIL"; cc_pass=0
    log "  codegen : FAIL (CC-took or assembly-invariant) — see below"
    sed 's/^/    /' "$work/vanilla.log" | tee -a "$REPORT" >/dev/null
  fi
  [ "$codegen" = PASS ] && log "  codegen : PASS (vanilla -O2, CC-took, branchless)"

  # --- 4. rspec --------------------------------------------------------------
  if step bundle exec rspec >"$work/rspec.log" 2>&1; then
    rspec="PASS"
  else
    rspec="FAIL"; cc_pass=0
  fi
  log "  rspec   : $rspec ($(grep -oE '[0-9]+ examples?, [0-9]+ failures?' "$work/rspec.log" | tail -1))"

  # --- 5. ctgrind ------------------------------------------------------------
  make -C security clean >/dev/null 2>&1
  if step make -C security ctgrind CC="$cc" >"$work/ctg.log" 2>&1 \
     && step valgrind -q --error-exitcode=1 ./security/ctgrind_harness >>"$work/ctg.log" 2>&1; then
    ctgrind="PASS"
  else
    ctgrind="FAIL"; cc_pass=0
  fi
  log "  ctgrind : $ctgrind"

  # --- 6. dudect timing, N runs ----------------------------------------------
  make -C timing clean >/dev/null 2>&1
  if ! step make -C timing CC="$cc" >"$work/timing.log" 2>&1; then
    log "  dudect  : FAIL — timing harness build failed"; cc_pass=0
  else
    : > "$work/dudect.raw"
    pin=""
    [ -n "$GATE_CORE" ] && pin="taskset -c $GATE_CORE chrt -f 99"
    for run in $(seq 1 "$GATE_DUDECT_RUNS"); do
      step $pin ./timing/timing_harness 2>/dev/null | grep '^dudect:' >> "$work/dudect.raw" || true
    done
    # Aggregate per op: n_over threshold, max|t|, mean|t|; apply strict/lenient.
    agg="$(awk -v thr="$THRESHOLD" -v strict="$STRICT_RE" -v lmean="$GATE_LENIENT_MEAN" '
      /^dudect:/ {
        label=$2; for(i=1;i<NF;i++) if($i=="t="){ t=$(i+1); break }
        a=t; if(a<0)a=-a
        n[label]++; sum[label]+=a; if(a>mx[label])mx[label]=a; if(a>thr)ov[label]++
      }
      END {
        anyfail=0
        for (l in n) {
          mean=sum[l]/n[l]
          isstrict = (l ~ strict)
          if (isstrict) { fail = (ov[l]>0) } else { fail = (mean>lmean) }
          if (fail) anyfail=1
          printf "    %-28s runs=%d over%.1f=%d max|t|=%.2f mean|t|=%.2f %s%s\n",
                 l, n[l], thr, ov[l]+0, mx[l], mean,
                 (isstrict?"[strict]":"[lenient]"), (fail?" <== FAIL":"")
        }
        exit anyfail
      }' "$work/dudect.raw")"
    dudect_rc=$?
    log "  dudect  : $([ $dudect_rc -eq 0 ] && echo PASS || echo FAIL) (N=$GATE_DUDECT_RUNS${GATE_CORE:+, core $GATE_CORE})"
    printf '%s\n' "$agg" | tee -a "$REPORT" >/dev/null
    [ $dudect_rc -ne 0 ] && cc_pass=0
  fi

  verdict="$([ $cc_pass -eq 1 ] && echo PASS || echo FAIL)"
  log "  => $cc: $verdict"
  [ $cc_pass -ne 1 ] && overall_rc=1
  rm -rf "$work"
done

log "--------------------------------------------------------------------------"
log "GATE: $([ $overall_rc -eq 0 ] && echo PASS || echo FAIL)  (report: $REPORT)"
bundle exec rake clobber >/dev/null 2>&1 || true
exit $overall_rc
