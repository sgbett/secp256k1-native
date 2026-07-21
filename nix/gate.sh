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
#      — parse per-op |t|, aggregate (n_ge_4.5, max|t|, mean|t|)
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
#   GATE_ARTEFACT_MEAN mean|t| bound for the elevated ops (jp_add/fsub) (default: 35)
#   GATE_LENIENT_MEAN  mean|t| bound for the near-flat field ops        (default: 15)
#   GATE_LENIENT_MAX   loose max|t| gross-anomaly backstop (all lenient)(default: 100)
#   GATE_STRICT_OVER_PCT  strict ops: max %% of runs |t|>=4.5 tolerated  (default: 5)
#   GATE_MIN_CLASS_N  min samples per dudect class; reject under-sampled  (default: 100)
#   GATE_CTGRIND_VG_CFLAGS  -isystem path to <valgrind/memcheck.h> for ctgrind (default: "")
#   GATE_SOURCE_REV / GATE_NIXPKGS_REV  provenance overrides (default: auto)
#
# Exit: 0 all building compilers passed · 1 a building compiler leaked/failed a
# deterministic gate · 2 environment/usage error. (SKIPs alone do not fail.)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# How to invoke Ruby dev tools (rake/rspec). devShell: "bundle exec" against the
# root Gemfile (gemspec puts lib/ on the load path). ISO: "" — the offline
# bundlerEnv already exposes rake/rspec on PATH. Single-dash default so an
# explicit empty GATE_RUBY_EXEC is honoured.
RUBY_EXEC="${GATE_RUBY_EXEC-bundle exec}"
# Make require 'secp256k1' / 'secp256k1_native' resolve without relying on a
# gemspec on the load path (the minimal ISO gemset has none).
export RUBYLIB="$ROOT/lib${RUBYLIB:+:$RUBYLIB}"

GATE_COMPILERS="${GATE_COMPILERS:-gcc}"
GATE_CORE="${GATE_CORE:-}"
GATE_DUDECT_RUNS="${GATE_DUDECT_RUNS:-20}"
GATE_OUT="${GATE_OUT:-$ROOT/gate-results}"
GATE_TIMEOUT="${GATE_TIMEOUT:-1800}"
GATE_ARTEFACT_MEAN="${GATE_ARTEFACT_MEAN:-35}" # large-artefact ops (jp_add, fsub): wide mean|t| bound
GATE_LENIENT_MEAN="${GATE_LENIENT_MEAN:-15}"   # near-flat field ops (fadd, fred, fneg): tighter mean|t| bound
GATE_LENIENT_MAX="${GATE_LENIENT_MAX:-100}"    # all lenient ops: loose gross-anomaly backstop (per-run max is noisy)
GATE_STRICT_OVER_PCT="${GATE_STRICT_OVER_PCT:-5}"  # strict ops: fail if >this% of runs are |t|>=4.5 (tolerate a lone transient)
# Minimum samples per dudect class. A FULLY degenerate statistic (a class with <2
# samples, or both-variances-zero) now returns NAN from dudect_t_statistic, which
# the gate's nan/inf check reds. This floor catches the DISTINCT finite-but-weak
# case: a class with 2..minn samples yields a finite but untrustworthy t. A broken
# class generator (all measurements in one class) or a short run is rejected by
# requiring BOTH classes >= this. Default 100: far below the smallest healthy
# per-class count (scalar_inv ~500/class from 1000 measurements; field ops ~750k),
# far above the degenerate cases.
GATE_MIN_CLASS_N="${GATE_MIN_CLASS_N:-100}"
THRESHOLD="4.5"

# Three tiers, so a currently-flat op can't regress up to the widest bound
# unnoticed. The field/point ops carry a benign operand-value LATENCY artefact,
# of very different magnitude, so they get bounds scoped to the op that needs
# them, NOT one global relaxation. Two channels, two backstops: ctgrind covers
# the BRANCH/addressing channel (it poisons secrets and catches secret-dependent
# control flow, but is SILENT on data-dependent instruction latency — so it does
# NOT, on its own, certify this artefact benign); the operand-latency channel's
# benignness w.r.t. the SECRET SCALAR is established by the flat STRICT ladder
# (scalar_multiply_ct), measured end-to-end on the real full-width operand
# distribution (see tier 2). The tiers:
#   1. STRICT (scalar_*): secret-dependent inputs, MUST be flat — fail when MORE
#      than GATE_STRICT_OVER_PCT%% of runs are at/over 4.5 (a reconstructed branch
#      shows in ~every run, a lone transient in one; see the aggregation below).
#      These plus the ctgrind pass are the security gate.
#   2. ARTEFACT (jp_add, fsub): the elevated ops — jp_add's Zen-MULTIPLIER
#      operand-value latency (Z=1 vs non-trivial Z), fsub's borrow-path latency.
#      Both are operand-VALUE effects ctgrind cannot see; the standalone dudect
#      |t| comes from the test's deliberately magnitude-asymmetric operand classes
#      (fsub: tiny-vs-full-width) — a synthetic magnitude asymmetry. Tiny
#      operands DO occur on the secret path (the ladder processes the infinity
#      accumulator [0,1,0] for a scalar-dependent number of leading iterations),
#      but the strict k=1-vs-random ladder test maximally stresses exactly that
#      and measures flat, so the effect is not secret-correlated. Secret-scalar
#      correlation is caught by the flat STRICT ladder, not by this tier or
#      ctgrind. Wide
#      mean bound GATE_ARTEFACT_MEAN. (A realistic full-width-vs-full-width fsub
#      test could retire it from this tier — issue #78.)
#   3. LENIENT (fadd, fred, fneg): near-flat, kept on a TIGHTER mean bound
#      GATE_LENIENT_MEAN so a stable regression in one of them is still caught.
#
# The bounds are CALIBRATED PER PINNED TOOLCHAIN, re-derived from the authoritative
# bare-metal sweep (issue #74) whenever the compiler changes — an artefact floor,
# NOT loosen-to-green. The MEAN is the stable, gated signal; the per-run MAX is
# noisy for these ~20 ns ops (it swings run-to-run) so GATE_LENIENT_MAX is only a
# loose gross-anomaly backstop shared by both lenient tiers, not a spike detector.
# On the reference machine (gcc 15.1, quiet, random-class harness, VANILLA -O2)
# the worst op is jp_add_internal, observed across sweeps at mean ~16-24 / max
# ~37-71 (the max swings run-to-run); the ARTEFACT mean bound (35) sits above the
# mean with margin and the max backstop (100) above the noisy max envelope, the
# LENIENT bound (15) hugs the near-flat ops (mean ~0.6-5). The lenient bounds are
# NOT the primary leak detector for these ops — note a #25-magnitude leak
# (|t| ≈ 21) would slip under the 35
# artefact bound. That's fine: jp_add/fsub are point/field building blocks, not
# secret-scalar ops. A secret-correlated BRANCH in them surfaces in BOTH the
# deterministic ctgrind pass AND the STRICT scalar_multiply_ct (gated at 4.5,
# where the #25 leak read ~21 and was caught with wide margin); a secret-correlated
# operand-LATENCY effect, which ctgrind cannot see, surfaces in the STRICT ladder
# alone, measured flat end-to-end — that is the backstop for this tier;
# the lenient bounds just pin the benign artefact per toolchain and flag gross
# regressions in the near-flat ops.
# Full labels, not substrings: `scalar_add` is intentionally ABSENT — the harness
# emits no scalar_add dudect line, so listing it would falsely imply coverage.
# (If scalar_add ever gets a dudect test, add its label here.)
# Anchored (^(...)$) so a match is an EXACT full label, per the note above — a
# future dudect label that merely contained one of these as a substring must not
# be mis-tiered.
STRICT_RE='^(scalar_multiply_ct_internal|scalar_mul_internal|scalar_reduce|scalar_inv_internal)$'
# The elevated operand-value-artefact ops that get the WIDE lenient mean bound;
# every other non-strict op gets the tighter GATE_LENIENT_MEAN.
ARTEFACT_RE='^(jp_add_internal|fsub_internal)$'

# Fail-closed coverage guard (principle 1: fail closed, not open). The aggregation
# only iterates labels it actually SAW, so a strict op silently removed/renamed —
# or a harness that partially crashes yet still emits >=1 dudect line (so the
# no-output FAIL path is not hit) — would drop out of the gate unnoticed: a
# missing label yields zero over-threshold runs, which reads as a pass. We assert
# every EXPECTED label is present and red the gate if any is absent. Keep in
# lock-step with timing/timing_harness.c: adding a dudect op must add its label
# here, a deliberate acknowledgement that the gate now covers it.
GATE_EXPECT_LABELS="scalar_multiply_ct_internal scalar_mul_internal scalar_reduce scalar_inv_internal jp_add_internal fsub_internal fadd_internal fred_internal fneg_internal"

mkdir -p "$GATE_OUT"
REPORT="$GATE_OUT/timing-report.txt"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; sync "$REPORT" 2>/dev/null || true; }
step() { timeout "$GATE_TIMEOUT" "$@"; }

# --- provenance header (written once) ----------------------------------------
cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //' || echo unknown)"
microcode="$(grep -m1 microcode /proc/cpuinfo 2>/dev/null | cut -d: -f2- | tr -d ' ' || echo unknown)"
kernel="$(uname -r 2>/dev/null || echo unknown)"
cur_khz="$([ -n "$GATE_CORE" ] && cat /sys/devices/system/cpu/cpu"$GATE_CORE"/cpufreq/scaling_cur_freq 2>/dev/null || echo n/a)"
src_rev="${GATE_SOURCE_REV:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
# Parse the nixpkgs node's rev specifically (ruby+JSON — always available here),
# not the first "rev" in flake.lock, which stops being nixpkgs the moment another
# input with a rev is added.
npk_rev="${GATE_NIXPKGS_REV:-$(ruby -rjson -e 'begin; print(JSON.parse(File.read(ARGV[0])).dig("nodes","nixpkgs","locked","rev").to_s[0,12]); rescue; end' "$ROOT/flake.lock" 2>/dev/null)}"
npk_rev="${npk_rev:-unknown}"

# --- machine-state diagnostics -----------------------------------------------
# Stamp what the quiet-machine config ACTUALLY did, so a single bare-metal run
# reveals a knob that didn't take (e.g. isolcpus wrong for this CPU, boost still
# on) — instead of a silent physical round-trip. All best-effort ("n/a" off the
# real box).
# Machine-wide state (always meaningful):
ms_cmdline="$(cat /proc/cmdline 2>/dev/null || echo unknown)"
if [ -r /sys/devices/system/cpu/isolated ]; then
  # File present: empty contents mean genuinely no isolated CPUs.
  ms_isolated="$(cat /sys/devices/system/cpu/isolated)"; ms_isolated="${ms_isolated:-<none>}"
else
  # File absent (kernel doesn't expose it) — can't tell; don't misreport as <none>.
  ms_isolated="<unknown (no /sys/.../cpu/isolated on this kernel)>"
fi
ms_online="$(cat /sys/devices/system/cpu/online 2>/dev/null || echo unknown)"
ms_smt="$(cat /sys/devices/system/cpu/smt/control 2>/dev/null || echo n/a)"
ms_boost="$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo n/a)"           # AMD/acpi-cpufreq: 1=on 0=off
ms_noturbo="$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a)" # Intel pstate: 1=turbo off
# Per-core state is only meaningful when a core is actually pinned. In dev/CI
# (GATE_CORE unset) report n/a — don't stamp core 0's stats as "the measured
# core" while the header says isolated=<none> (that would be inconsistent).
if [ -n "$GATE_CORE" ]; then
  mc="$GATE_CORE"
  ms_gov="$(cat /sys/devices/system/cpu/cpu"$mc"/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  ms_min="$(cat /sys/devices/system/cpu/cpu"$mc"/cpufreq/scaling_min_freq 2>/dev/null || echo n/a)"
  ms_max="$(cat /sys/devices/system/cpu/cpu"$mc"/cpufreq/scaling_max_freq 2>/dev/null || echo n/a)"
  # Cumulative IRQ count on the isolated core SINCE BOOT (a total from
  # /proc/interrupts, not a live rate) — should be ~0 if irqaffinity steered them away.
  ms_irq="$(awk -v core="$mc" 'NR==1{for(i=1;i<=NF;i++) if($i=="CPU"core) col=i+1} NR>1 && col && $col ~ /^[0-9]+$/ {s+=$col} END{print (col? s+0 : "n/a")}' /proc/interrupts 2>/dev/null || echo n/a)"
else
  mc="<none>"; ms_gov="n/a"; ms_min="n/a"; ms_max="n/a"; ms_irq="n/a"
fi

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
  echo "dudect runs : $GATE_DUDECT_RUNS   |t|<$THRESHOLD strict (fail if >$GATE_STRICT_OVER_PCT% of runs over) / mean|t|<$GATE_ARTEFACT_MEAN (jp_add,fsub) / <$GATE_LENIENT_MEAN (other field ops) / max<$GATE_LENIENT_MAX / min class n=$GATE_MIN_CLASS_N"
  echo "compilers   : $GATE_COMPILERS"
  echo "-------------------------------- machine state (did the quiet config take?) --"
  echo "cmdline     : $ms_cmdline"
  echo "isolated    : $ms_isolated   (kernel-reported isolated CPUs; want the measurement core listed)"
  echo "online cpus : $ms_online"
  echo "SMT         : $ms_smt   (want 'off'/'forceoff')"
  echo "core $mc gov  : $ms_gov   (want 'performance')"
  echo "core $mc freq : min=$ms_min max=$ms_max cur=$cur_khz kHz   (want min==max==cur, no throttle)"
  echo "boost/turbo : amd boost=$ms_boost (want 0)   intel no_turbo=$ms_noturbo (want 1)"
  echo "core $mc IRQs : $ms_irq   (cumulative since boot; want ~0 — irqaffinity steered interrupts off the isolated core)"
  echo "=========================================================================="
  echo
} > "$REPORT"
sync "$REPORT" 2>/dev/null || true

overall_rc=0
built=0  # compilers that built + staged (and so ran the CT checks below), not
         # SKIPPED — guards against a vacuous all-SKIPPED sweep reporting PASS

for cc in $GATE_COMPILERS; do
  ccver="$("$cc" --version 2>/dev/null | head -1 || echo 'unknown')"
  log "--------------------------------------------------------------------------"
  log "compiler: $cc — $ccver"
  work="$(mktemp -d)"

  # --- 1+2. clobber + vanilla build (SKIPPED on failure, not fatal) ----------
  if ! command -v "$cc" >/dev/null 2>&1; then
    log "  SKIPPED — compiler '$cc' not on PATH"; rm -rf "$work"; continue
  fi
  step $RUBY_EXEC rake clobber >/dev/null 2>&1
  # Guarantee a from-scratch build for THIS compiler. rake clobber handles
  # rake-compiler's tmp/, but the direct extconf/make below leaves ext/*.o +
  # Makefile that rake doesn't track — a stale .o (newer than its .c) would be
  # silently reused by the next compiler in the sweep and we'd measure the wrong
  # binary. Remove them explicitly so a clobber hiccup can't corrupt the sweep.
  rm -f ext/secp256k1_native/*.o ext/secp256k1_native/secp256k1_native.so \
        ext/secp256k1_native/Makefile ext/secp256k1_native/mkmf.log \
        lib/secp256k1_native.so
  mkdir -p "$GATE_OUT"  # defensive: `rake clobber` wipes tmp/; never let it eat the results dir
  if ! ( cd ext/secp256k1_native \
         && NIX_HARDENING_ENABLE="" CC="$cc" step ruby extconf.rb \
         && NIX_HARDENING_ENABLE="" step make CC="$cc" ) >"$work/build.log" 2>&1; then
    log "  SKIPPED — extension failed to build with $cc (dep/toolchain):"
    log "    $(tail -1 "$work/build.log")"
    rm -rf "$work"; continue
  fi
  # Stage the freshly-built extension; fail closed if it doesn't land so that no
  # later step (rspec/ctgrind) can run against a previous compiler's .so.
  if ! cp ext/secp256k1_native/secp256k1_native.so lib/secp256k1_native.so; then
    log "  SKIPPED — staging the built extension into lib/ failed"
    rm -rf "$work"; continue
  fi
  # Certify the TESTED artifact directly: confirm the staged .so (what rspec /
  # ctgrind / dudect actually exercise) was compiled by $cc — vanilla-ext.sh
  # only certifies a separately-compiled proxy object.
  so_major="$(readelf -p .comment lib/secp256k1_native.so 2>/dev/null | grep -oE '(GCC:|clang version)[^0-9]*[0-9]+' | grep -oE '[0-9]+$' | head -1)"
  cc_major="$("$cc" -dumpversion 2>/dev/null | cut -d. -f1)"
  if [ -n "$cc_major" ] && [ "$so_major" != "$cc_major" ]; then
    # NOT a SKIP: the build succeeded but the tested artifact can't be attributed
    # to $cc — a certification failure, so red the gate (fail-closed) rather than
    # let other compilers carry it to PASS. Continue the sweep for visibility.
    log "  FAIL — staged .so built by compiler major '$so_major', not the intended '$cc_major' (cannot certify the tested artifact)"
    overall_rc=1
    rm -rf "$work"; continue
  fi
  built=$((built + 1))

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
  if step $RUBY_EXEC rspec >"$work/rspec.log" 2>&1; then
    rspec="PASS"
  else
    rspec="FAIL"; cc_pass=0
  fi
  log "  rspec   : $rspec ($(grep -oE '[0-9]+ examples?, [0-9]+ failures?' "$work/rspec.log" | tail -1))"

  # --- 5. ctgrind ------------------------------------------------------------
  # GATE_CTGRIND_VG_CFLAGS carries the valgrind-dev include (-isystem ...) for
  # <valgrind/memcheck.h> when it isn't on the default path (the nix ISO/app);
  # empty on a distro where the header is already found. Passed EXPLICITLY as a
  # make var because a bare NIX_CFLAGS_COMPILE is ignored by nix's salted
  # cc-wrapper.
  # NIX_HARDENING_ENABLE="" to match the SHIPPING-SHAPED vanilla codegen (as the
  # extension build above does): the nix cc-wrapper's default hardening alters
  # codegen, and a compiler-reconstructed branch is optimisation- AND flag-specific.
  # This standalone harness is not byte-identical to a `gem install` build (it adds
  # stub-build flags and omits per-user mkmf CFLAGS; see docs/security.md), but
  # building at vanilla -O2 exercises the same optimisation level and hardening-off
  # codegen that ships — or the deterministic backstop would verify a hardened
  # binary users do not run. (Advisory 0001's reconstruction is a vanilla -O2
  # phenomenon.)
  make -C security clean >/dev/null 2>&1
  if NIX_HARDENING_ENABLE="" step make -C security ctgrind CC="$cc" CTGRIND_VG_CFLAGS="${GATE_CTGRIND_VG_CFLAGS:-}" >"$work/ctg.log" 2>&1 \
     && step valgrind -q --error-exitcode=1 ./security/ctgrind_harness >>"$work/ctg.log" 2>&1; then
    ctgrind="PASS"
    log "  ctgrind : PASS"
  else
    ctgrind="FAIL"; cc_pass=0
    log "  ctgrind : FAIL — last lines:"
    tail -6 "$work/ctg.log" | sed 's/^/      /' | tee -a "$REPORT" >/dev/null
  fi

  # --- 6. dudect timing, N runs ----------------------------------------------
  # Vanilla (NIX_HARDENING_ENABLE="") too, so the measured timing is the
  # shipping-shaped codegen's (same optimisation level + hardening-off, though
  # not byte-identical — see the ctgrind note above), not the hardened wrapper
  # default — the calibrated bounds must describe the binary users run.
  make -C timing clean >/dev/null 2>&1
  if ! NIX_HARDENING_ENABLE="" step make -C timing CC="$cc" >"$work/timing.log" 2>&1; then
    log "  dudect  : FAIL — timing harness build failed"; cc_pass=0
  else
    : > "$work/dudect.raw"
    pin=""
    [ -n "$GATE_CORE" ] && pin="taskset -c $GATE_CORE chrt -f 99"
    runs_ok=0
    for run in $(seq 1 "$GATE_DUDECT_RUNS"); do
      # Capture per run so a timeout/crash is DETECTED, not swallowed. CRUCIAL:
      # timing_harness returns 1 whenever ANY op trips its OWN internal |t|>=4.5
      # (e.g. jp_add_internal's operand-value artefact, which exceeds 4.5), so exit
      # 0 AND 1 are both NORMAL completions — we re-derive PASS/FAIL from the
      # t-values below,
      # so the harness's own verdict is not the run-success signal. A real
      # failure is a timeout (`timeout` → 124), a signal (>128), or no output.
      step $pin ./timing/timing_harness >"$work/run" 2>/dev/null; hrc=$?
      got=$(grep -c '^dudect:' "$work/run")
      if { [ "$hrc" -eq 0 ] || [ "$hrc" -eq 1 ]; } && [ "$got" -gt 0 ]; then
        grep '^dudect:' "$work/run" >> "$work/dudect.raw"
        runs_ok=$((runs_ok + 1))
      else
        log "  dudect  : note — run $run discarded (harness exit $hrc, $got lines)"
      fi
    done
    if [ "$runs_ok" -eq 0 ]; then
      # Fail closed (principle 1): zero usable dudect output — every run
      # crashed/timed out — is inconclusive, never a pass.
      log "  dudect  : FAIL — no dudect output from $GATE_DUDECT_RUNS run(s) (crash/timeout)"
      cc_pass=0
    else
      short=0
      if [ "$runs_ok" -lt "$GATE_DUDECT_RUNS" ]; then
        # Fail closed (principle 1): a degraded run-set is inconclusive, not a
        # pass. With nexp=runs_ok the per-label count check alone CANNOT catch
        # this — e.g. 19/20 runs time out and the one survivor emits every label
        # once, so count==nexp==1 and the strict fraction sees 0/1 over — the
        # statistical basis (N independent runs) is gone. Red the gate rather
        # than certify on a shrunken run-set. (Fewer runs by design? lower
        # GATE_DUDECT_RUNS — then all of them must still succeed.)
        short=1
        log "  dudect  : FAIL — only $runs_ok/$GATE_DUDECT_RUNS runs produced output (inconclusive; all $GATE_DUDECT_RUNS required)"
      fi
      # Aggregate per op: n_over threshold, max|t|, mean|t|; apply strict/lenient.
      agg="$(awk -v thr="$THRESHOLD" -v strict="$STRICT_RE" -v artefact="$ARTEFACT_RE" -v amean="$GATE_ARTEFACT_MEAN" -v lmean="$GATE_LENIENT_MEAN" -v lmax="$GATE_LENIENT_MAX" -v spct="$GATE_STRICT_OVER_PCT" -v expect="$GATE_EXPECT_LABELS" -v nexp="$runs_ok" -v minn="$GATE_MIN_CLASS_N" '
        /^dudect:/ {
          label=$2; tv=""; c0=""; c1=""
          # Scan fields once for the class counts (n0=/n1=, printed before t=) and
          # the t-value. dudect prints "t=%+9.4f": a standalone "t=" then the value
          # for small |t|, but GLUED ("t=+875.0000") once |t|>=100 drops the pad
          # space — i.e. exactly a large leak. Take the "t=" suffix or the next
          # field; the tv=="" guard sets it once so a later field cannot overwrite.
          for (i=1; i<=NF; i++) {
            if ($i ~ /^t=/ && tv=="") { tv=$i; sub(/^t=/,"",tv); if (tv=="") tv=$(i+1) }
            else if ($i ~ /^n0=/) { c0=$i; sub(/^n0=/,"",c0) }
            else if ($i ~ /^n1=/) { c1=$i; sub(/^n1=/,"",c1) }
          }
          if (tv=="") { bad++; next }
          # Non-finite t (a degenerate Welch denominator prints nan/inf via %f)
          # must fail closed: tv+0 would coerce it to 0 (BSD awk) or nan (gawk)
          # and silently count as a clean sub-threshold run — a fail-open.
          if (tolower(tv) ~ /nan|inf/) { bad++; next }
          # Class-count validity floor. dudect now returns NAN for a fully
          # degenerate statistic (a class with <2 samples, or both-variances-zero
          # from a constant/broken timer) — the nan/inf check above reds those.
          # This adds the STATISTICAL floor the nan check cannot: a class with
          # 2..minn samples yields a FINITE but untrustworthy t. Reject any line
          # whose class counts are missing or below minn (a broken class
          # generator bucketing every measurement into one class, or an
          # under-sampled run, has no valid Welch test). Fail closed.
          if (c0=="" || c1=="") { bad++; next }
          if (c0+0 < minn || c1+0 < minn) { bad++; next }
          a=tv+0; if(a<0)a=-a
          n[label]++; sum[label]+=a; if(a>mx[label])mx[label]=a; if(a>=thr)ov[label]++
        }
        END {
          anyfail=0
          # Fail closed on any line whose t could not be parsed — never drop it.
          if (bad>0) { anyfail=1; printf "    %-28s %d line(s) with unparseable t <== FAIL\n","(parse-error)",bad }
          for (l in n) {
            mean=sum[l]/n[l]
            isstrict = (l ~ strict)
            isartefact = (l ~ artefact)
            # Strict ops: fail if MORE THAN spct% of runs are at/over 4.5. A
            # compiler-reconstructed branch is compiled IN, so it shows in
            # essentially EVERY run (the #25 ladder leak was 20/20); a lone
            # measurement transient hits one run. Gating on the fraction-over
            # therefore distinguishes the two WITHOUT masking a real leak (a leak
            # is ~100% of runs, far above spct) while not redding the gate on a
            # single blip. Scales with N: at spct=5 and N=20 it tolerates <=1
            # over-threshold run (fails at 2); at small N it stays effectively
            # strict (N=2 -> any run over fails). ctgrind (deterministic, vanilla
            # -O2) is the load-bearing backstop for the marginal band this cannot
            # resolve (a weak/rare-bit partial branch < spct% of runs) — and it
            # poisons the secret inputs of ALL FOUR strict ops (ladder,
            # scalar_mul, scalar_reduce, scalar_inv in ctgrind_harness.c), so no
            # strict label relies on the statistical gate alone for the BRANCH
            # channel. Residual: ctgrind cannot see operand LATENCY, so a
            # secret-correlated latency leak weak enough to stay < spct% of runs
            # is not deterministically excluded — but that sits at the noise
            # floor (a genuine data-dependent effect fires consistently, like the
            # 17/20 and 9/20 artefacts, not 1/20). See docs/security.md. Lenient
            # ops are gated on the MEAN (the stable signal) against a per-tier
            # bound — the wider amean for the elevated artefact ops (jp_add/fsub),
            # the tighter lmean for the near-flat ones — plus a shared loose max
            # backstop (per-run max is noisy for these fast ops, not a spike det).
            # The mean/max bounds compare >= (a value exactly at the bound fails,
            # fail-closed); the strict fraction uses > (tolerate exactly spct%).
            if (isstrict) {
              fail = (ov[l]*100 > n[l]*spct); tier = "[strict]"
            } else if (isartefact) {
              fail = (mean >= amean || mx[l] >= lmax); tier = "[artefact]"
            } else {
              fail = (mean >= lmean || mx[l] >= lmax); tier = "[lenient]"
            }
            if (fail) anyfail=1
            printf "    %-28s runs=%d %d>=%.1f max|t|=%.2f mean|t|=%.2f %s%s\n",
                   l, n[l], ov[l]+0, thr, mx[l], mean, tier, (fail?" <== FAIL":"")
          }
          # Fail closed on coverage anomalies in BOTH directions (principle 1) —
          # the aggregation tiers only the labels it saw, so guard the label set:
          #   (a) every EXPECTED label must be present with the FULL run count.
          #       Absent entirely (op removed/renamed) OR short (a partial-run
          #       harness that emitted it in only some runs) reds the gate — a
          #       silently-dropped or under-sampled op, above all a strict one,
          #       must never pass by omission. Each healthy run emits each label
          #       exactly once, so the expected per-label count is nexp (=runs_ok).
          #   (b) every SEEN label must be EXPECTED. A new/renamed op otherwise
          #       falls through to [lenient] tiering silently; an unknown label
          #       reds the gate and forces an explicit tier decision in
          #       GATE_EXPECT_LABELS + the strict/artefact regexes.
          ne = split(expect, elab, " ")
          for (j=1; j<=ne; j++) known[elab[j]] = 1
          for (j=1; j<=ne; j++) {
            if (!(elab[j] in n)) {
              anyfail=1
              printf "    %-28s MISSING from dudect output <== FAIL\n", elab[j]
            } else if (nexp+0 > 0 && n[elab[j]] != nexp) {
              anyfail=1
              printf "    %-28s incomplete: %d/%d runs <== FAIL\n", elab[j], n[elab[j]], nexp
            }
          }
          for (l in n) if (!(l in known)) {
            anyfail=1
            printf "    %-28s UNEXPECTED label (add to GATE_EXPECT_LABELS + tier) <== FAIL\n", l
          }
          exit anyfail
        }' "$work/dudect.raw")"
      dudect_rc=$?
      [ "$short" -eq 1 ] && dudect_rc=1
      log "  dudect  : $([ $dudect_rc -eq 0 ] && echo PASS || echo FAIL) (N=$runs_ok${GATE_CORE:+, core $GATE_CORE})"
      printf '%s\n' "$agg" | tee -a "$REPORT" >/dev/null
      [ $dudect_rc -ne 0 ] && cc_pass=0
    fi
  fi

  verdict="$([ $cc_pass -eq 1 ] && echo PASS || echo FAIL)"
  log "  => $cc: $verdict"
  [ $cc_pass -ne 1 ] && overall_rc=1
  rm -rf "$work"
done

log "--------------------------------------------------------------------------"
# An all-SKIPPED sweep verified nothing — never report that as a clean PASS
# (fail-closed spirit): if not one compiler built, the run is inconclusive.
if [ "$built" -eq 0 ]; then
  log "GATE: NO COMPILERS BUILT — nothing verified. Check the toolchain (ruby/gcc on PATH)."
  overall_rc=2
else
  log "GATE: $([ $overall_rc -eq 0 ] && echo PASS || echo FAIL)  ($built/$(echo $GATE_COMPILERS | wc -w) compiler(s) built + tested; report: $REPORT)"
fi
step $RUBY_EXEC rake clobber >/dev/null 2>&1 || true
exit $overall_rc
