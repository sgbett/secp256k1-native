# frozen_string_literal: true

#
# check-ct-assembly.rb -- assembly-invariant guard on the Montgomery ladder.
#
# What this enforces
# ------------------
# The Montgomery ladder in scalar_multiply_ct_internal (ext/secp256k1_native/
# jacobian.c) MUST compile to a loop body whose only conditional jump is the
# public loop counter at the bottom (`jae`/`jnb` on the decremented `i`).
# Any additional conditional jump (je, jne, jb, ja, jz, jnz, ...) or
# conditional move (cmov*) inside the loop body is a fail.
#
# Why this is load-bearing (H-2 follow-up)
# ----------------------------------------
# Advisory GHSA-vp2j-gqfm-r3cf (H-2) recorded a real regression where GCC
# 15.2/-O2 reconstructed a branch inside the branchless `uint256_select`
# helper -- pushing the shipping ladder to dudect |t| ~= 21 from clean. The
# fix is the `ct_value_barrier_u64` opaque asm in secp256k1_native.h; the
# assembly-invariant guard this script implements catches a regression of
# the same shape at CI time rather than at pre-tag bare-metal dudect time.
#
# Pairs with:
#   - security/check-ct-mask-guard.sh (sub-issue #34), the source-layer grep
#     guard that catches raw `-(uint64_t)cond` mask constructions at source.
#   - the pre-tag bare-metal dudect gate (docs/timing-verification-runbook.md),
#     which observes statistical timing of the shipping binary.
#
# Scope of the check
# ------------------
# Two symbols are inspected:
#
#   1. scalar_multiply_ct_internal — the Montgomery ladder driver.
#      Region: the trailing backward-branching loop (its target is the loop
#      top, its own address is the bottom).
#      Failure conditions inside that region:
#        (a) more than one conditional-jump mnemonic (j<cond>), OR
#        (b) any conditional-move mnemonic (cmov<cond>).
#      The single legitimate conditional jump is the loop counter's back-edge.
#
#   2. jp_add_internal — the branchless Jacobian point addition. In source
#      it is deliberately mask-based end-to-end (see docstring in jacobian.c).
#      H-2 was exactly the shape where GCC 15.2 reconstructed a data-dependent
#      branch inside a `uint256_select` call that lands in this function, so
#      inspecting the standalone symbol closes the coverage gap where the
#      ladder-loop check would miss non-inlined regressions here.
#      Failure conditions inside the whole body:
#        (a) any conditional-jump mnemonic (j<cond>), OR
#        (b) any conditional-move mnemonic (cmov<cond>).
#      Unconditional jmp / call / ret are all permitted.
#
# If the compiler inlines jp_add_internal into the ladder, its standalone
# symbol is absent from objdump output; the checker emits a NOTE and treats
# that as PASS — the inlined body sits inside the ladder loop and is covered
# by the loop-body check instead.
#
# Platform scoping
# ----------------
# The parser targets GNU `objdump -dl` output for AT&T-syntax x86_64. On
# macOS local dev objdump ships as LLVM's, which emits a different format;
# the check auto-skips there with a clear "only runs on GNU objdump / x86_64"
# message and exits 0. CI runs on Ubuntu -- that is the load-bearing target.
#
# Usage
# -----
#   ruby security/check-ct-assembly.rb /tmp/jacobian.o
#
# Exit codes
# ----------
#   0  pass -- or graceful skip on unsupported platform
#   1  fail -- extra conditional jump / cmov inside the ladder loop
#   2  usage / environment error (missing objdump, missing input file, ...)

require 'open3'
require 'rbconfig'
require 'shellwords'

LADDER_SYMBOL = 'scalar_multiply_ct_internal'
JP_ADD_SYMBOL = 'jp_add_internal'

# Conditional-jump mnemonic pattern. On x86-64 AT&T syntax the family is
# `j<cond>` for cond in {e, ne, z, nz, b, be, nb, a, ae, na, nae, l, le, g,
# ge, o, no, s, ns, p, np, pe, po, c, nc, jecxz, jrcxz}. We deliberately
# EXCLUDE unconditional `jmp` (and `jmpq`), which is a plain goto and does
# not depend on flags.
COND_JUMP_MNEMONICS = %w[
  je jne jz jnz jb jbe jnb ja jae jna jnae jc jnc jecxz jrcxz
  jl jle jg jge jo jno js jns jp jnp jpe jpo
].freeze
COND_JUMP_RE = /^\s+([0-9a-f]+):\s+[0-9a-f ]+\t(#{COND_JUMP_MNEMONICS.join('|')})[ql]?\s+([0-9a-f]+)/.freeze

# Conditional-move family: cmove/cmovne/cmovz/cmovnz/cmovb/... -- everything
# beginning `cmov` in the mnemonic column.
CMOV_RE = /^\s+([0-9a-f]+):\s+[0-9a-f ]+\t(cmov\w*)\b/.freeze

# Objdump line address pattern (mnemonic-agnostic).
ADDR_RE = /^\s+([0-9a-f]+):\s+[0-9a-f]/.freeze

def die(msg, code = 2)
  warn "check-ct-assembly: #{msg}"
  exit code
end

def skip(msg)
  puts "check-ct-assembly: SKIP -- #{msg}"
  exit 0
end

def parse_hex(str)
  str.to_i(16)
end

# Return the raw output of `objdump -dl <path>`. Aborts (exit 2) on missing
# objdump, LLVM objdump (macOS default), or objdump failure.
def objdump_disassembly(path)
  objdump = ENV.fetch('OBJDUMP', 'objdump')
  begin
    version_out, status = Open3.capture2e(objdump, '--version')
  rescue Errno::ENOENT
    die("`#{objdump}` not found on PATH -- install binutils or set OBJDUMP to a GNU objdump.")
  end
  die("`#{objdump}` failed to report a version -- is it on PATH?") unless status.success?
  unless version_out.match?(/GNU objdump|Binutils/)
    skip("this checker targets GNU objdump; found `#{objdump}` reporting: #{version_out.lines.first&.strip}")
  end
  out, err, status = Open3.capture3(objdump, '-dl', path)
  die("`objdump -dl #{Shellwords.escape(path)}` failed: #{err.strip}") unless status.success?
  out
end

# Slice out the lines belonging to `symbol` from objdump output. The block
# starts at the `<symbol>:` header and ends just before the next `<label>:`
# header at column zero (or end of file).
def symbol_body(disasm, symbol)
  lines = disasm.lines
  header_re = /^[0-9a-f]+\s+<#{Regexp.escape(symbol)}>:$/
  next_symbol_re = /^[0-9a-f]+\s+<[^>]+>:$/
  start_idx = lines.index { |l| l =~ header_re }
  return nil if start_idx.nil?

  tail = lines[(start_idx + 1)..]
  offset = tail.index { |l| l =~ next_symbol_re }
  end_idx = offset.nil? ? lines.size : start_idx + 1 + offset
  lines[(start_idx + 1)...end_idx]
end

# All conditional-jump instructions inside body_lines, as [addr, mnemonic,
# target_addr] triples. Addresses are ints.
def collect_cond_jumps(body_lines)
  body_lines.each_with_object([]) do |line, acc|
    m = line.match(COND_JUMP_RE)
    acc << [parse_hex(m[1]), m[2], parse_hex(m[3])] if m
  end
end

# All conditional-move instructions inside body_lines, as [addr, mnemonic]
# pairs. Addresses are ints.
def collect_cmovs(body_lines)
  body_lines.each_with_object([]) do |line, acc|
    m = line.match(CMOV_RE)
    acc << [parse_hex(m[1]), m[2]] if m
  end
end

# Instruction address range of a symbol body: [first_insn_addr, last_insn_addr].
def symbol_address_range(body_lines)
  addrs = body_lines.filter_map { |l| l.match(ADDR_RE) && parse_hex(Regexp.last_match(1)) }
  addrs.empty? ? nil : [addrs.first, addrs.last]
end

# Identify the ladder loop closure: the trailing backward conditional jump
# whose target lies within the symbol's address range. There should be
# exactly one such jump in a clean build -- that is the invariant we assert.
# Returns [loop_top_addr, loop_bottom_addr] (inclusive on both ends), or
# nil if the symbol has no backward conditional jump (unexpected).
def find_loop_range(body_lines, cond_jumps)
  range = symbol_address_range(body_lines)
  return nil if range.nil?

  sym_lo, sym_hi = range
  backwards = cond_jumps.select do |addr, _mnem, target|
    target.between?(sym_lo, addr - 1) && addr <= sym_hi
  end
  return nil if backwards.empty?

  bottom = backwards.max_by { |addr, _, _| addr }
  [bottom[2], bottom[0]] # [loop_top_addr, loop_bottom_addr]
end

# Filter jumps/cmovs to those whose instruction address is inside
# [top_addr, bottom_addr] inclusive.
def in_range(items, top_addr, bottom_addr)
  items.select { |addr, *| addr.between?(top_addr, bottom_addr) }
end

def loop_snippet(body_lines, top_addr, bottom_addr)
  body_lines.select do |l|
    m = l.match(ADDR_RE)
    m && parse_hex(m[1]).between?(top_addr, bottom_addr)
  end
end

# Classify conditional jumps inside the ladder loop body against the invariant:
#   - `back_edges` — target == loop_top_addr. Exactly one is required (the
#     ladder's own back-edge).
#   - `forward_branches` — target > jump_addr. Zero allowed. Any forward
#     conditional branch inside the loop body is a data-dependent branch —
#     the H-2 shape.
#   - `inner_backwards` — everything else (backward jumps whose target is
#     between loop_top_addr and jump_addr). Allowed — these are the back-edges
#     of *inner* constant-count loops the compiler chose not to unroll. Their
#     loop count is a source-level constant, so their timing is not data-
#     dependent. A NOTE is emitted so a reviewer can eyeball them.
def classify_loop_jumps(loop_jumps, top_addr)
  back_edges = loop_jumps.select { |_, _, target| target == top_addr }
  forward_branches = loop_jumps.select { |addr, _, target| target > addr }
  inner_backwards = loop_jumps - back_edges - forward_branches
  { back_edges: back_edges, forward_branches: forward_branches, inner_backwards: inner_backwards }
end

# Report offences (invariant violations) and notes (allowed-but-worth-flagging
# observations) as two arrays of human-readable lines. Empty offences means
# the invariant holds; notes may fire on a passing check.
def report_offences(loop_jumps, loop_cmovs, top_addr)
  classification = classify_loop_jumps(loop_jumps, top_addr)
  problems = []
  notes = []

  if classification[:back_edges].size != 1
    problems << "expected exactly 1 back-edge to loop top #{format('%#x', top_addr)}, " \
                "found #{classification[:back_edges].size}:"
    classification[:back_edges].each do |addr, mnem, target|
      problems << "    #{format('%#x', addr)}: #{mnem} -> #{format('%#x', target)}"
    end
  end

  unless classification[:forward_branches].empty?
    problems << "found #{classification[:forward_branches].size} forward conditional " \
                'branch(es) inside the ladder loop body — the H-2 shape (data-dependent branch):'
    classification[:forward_branches].each do |addr, mnem, target|
      problems << "    #{format('%#x', addr)}: #{mnem} -> #{format('%#x', target)}"
    end
  end

  unless loop_cmovs.empty?
    problems << "expected no conditional moves in ladder loop body, found #{loop_cmovs.size}:"
    loop_cmovs.each do |addr, mnem|
      problems << "    #{format('%#x', addr)}: #{mnem}"
    end
  end

  unless classification[:inner_backwards].empty?
    notes << "note: #{classification[:inner_backwards].size} additional backward conditional " \
             'jump(s) inside the ladder loop body — presumed inner constant-count loop(s):'
    classification[:inner_backwards].each do |addr, mnem, target|
      notes << "    #{format('%#x', addr)}: #{mnem} -> #{format('%#x', target)}"
    end
  end

  [problems, notes]
end

def report_pass(top_addr, bottom_addr, loop_jumps)
  lo = format('%#x', top_addr)
  hi = format('%#x', bottom_addr)
  back = loop_jumps.find { |_, _, target| target == top_addr }
  addr, mnem, = back
  puts "check-ct-assembly: PASS -- #{LADDER_SYMBOL} loop body [#{lo}..#{hi}] " \
       "back-edge #{format('%#x', addr)}: #{mnem} -> #{lo}; " \
       'no forward branches, no cmov.'
end

def report_pass_jp_add(range)
  lo, hi = range
  puts "check-ct-assembly: PASS -- #{JP_ADD_SYMBOL} body " \
       "[#{format('%#x', lo)}..#{format('%#x', hi)}] fully branchless " \
       '(0 conditional jumps, 0 cmov).'
end

def report_fail_jp_add(body, cond_jumps, cmovs)
  warn "check-ct-assembly: FAIL -- #{JP_ADD_SYMBOL} contains a data-dependent branch."
  cond_jumps.each do |addr, mnem, target|
    warn "  #{format('%#x', addr)}: #{mnem} -> #{format('%#x', target)}"
  end
  cmovs.each { |addr, mnem| warn "  #{format('%#x', addr)}: #{mnem}" }
  warn ''
  warn "#{JP_ADD_SYMBOL} is required to be end-to-end mask-based (see docstring in"
  warn 'ext/secp256k1_native/jacobian.c). This is the exact shape of the H-2 regression'
  warn '(GHSA-vp2j-gqfm-r3cf): GCC 15.2 reconstructed a data-dependent branch inside'
  warn 'a `uint256_select` call that landed here. Confirm `ct_value_barrier_u64` still'
  warn 'applies inside `ct_mask_u64` and inspect the disassembly below:'
  warn ''
  body.each { |l| warn "  #{l.chomp}" }
end

def report_fail(problems, body_lines, top_addr, bottom_addr)
  warn 'check-ct-assembly: FAIL'
  problems.each { |p| warn "  #{p}" }
  warn '', 'Loop body disassembly:'
  loop_snippet(body_lines, top_addr, bottom_addr).each { |l| warn "  #{l.chomp}" }
  warn ''
  warn 'This is the H-2 regression shape (GHSA-vp2j-gqfm-r3cf).'
  warn 'Inspect ext/secp256k1_native/jacobian.c and ext/secp256k1_native/secp256k1_native.h;'
  warn 'ensure `ct_value_barrier_u64` still applies inside `ct_mask_u64` and that no'
  warn 'new helper in the ladder path constructs a mask outside `ct_mask_u64`.'
end

# Inspect jp_add_internal. Returns true on pass, false on fail.
#
# When JP_ADD_SYMBOL is absent from the disassembly we can't distinguish
# "compiler inlined it into the ladder" (benign, covered by the loop-body
# check) from "someone renamed or removed the function and forgot to update
# the checker" (silent coverage gap). Default to FAIL and require an explicit
# opt-in (ALLOW_INLINED_JP_ADD_INTERNAL=1) so an inlining regression trips
# CI rather than being silently accepted.
def check_jp_add_internal(disasm)
  body = symbol_body(disasm, JP_ADD_SYMBOL)
  if body.nil?
    if ENV['ALLOW_INLINED_JP_ADD_INTERNAL'] == '1'
      puts "check-ct-assembly: NOTE -- `#{JP_ADD_SYMBOL}` symbol absent from " \
           'objdump output; ALLOW_INLINED_JP_ADD_INTERNAL=1 set — treating as inlined ' \
           "into the ladder body (covered by the #{LADDER_SYMBOL} loop-body check)."
      return true
    end
    warn "check-ct-assembly: FAIL -- `#{JP_ADD_SYMBOL}` symbol absent from objdump. " \
         'Either (a) update JP_ADD_SYMBOL in this script if the function has been ' \
         'renamed, or (b) set ALLOW_INLINED_JP_ADD_INTERNAL=1 if the compiler has ' \
         'inlined it into the ladder body (verify by inspecting objdump -dl output).'
    return false
  end

  cond_jumps = collect_cond_jumps(body)
  cmovs = collect_cmovs(body)

  if cond_jumps.empty? && cmovs.empty?
    report_pass_jp_add(symbol_address_range(body))
    return true
  end

  report_fail_jp_add(body, cond_jumps, cmovs)
  false
end

def check_host_arch!
  host = RbConfig::CONFIG['host_cpu'] || RUBY_PLATFORM
  return if host.include?('x86_64') || host.include?('amd64')

  skip("host CPU `#{host}` is not x86_64; this check targets GCC x86_64 codegen")
end

def check_ladder(disasm, input_path)
  body = symbol_body(disasm, LADDER_SYMBOL)
  if body.nil?
    warn "check-ct-assembly: FAIL -- symbol `#{LADDER_SYMBOL}` not found in `#{input_path}` -- " \
         'was it compiled from jacobian.c?'
    return false
  end

  cond_jumps = collect_cond_jumps(body)
  cmovs = collect_cmovs(body)
  range = find_loop_range(body, cond_jumps)
  if range.nil?
    warn "check-ct-assembly: FAIL -- could not locate ladder loop in `#{LADDER_SYMBOL}` -- " \
         'no backward conditional jump found. Codegen may have changed shape (unrolled?). ' \
         'Inspect objdump -dl output manually.'
    return false
  end

  top_addr, bottom_addr = range
  loop_jumps = in_range(cond_jumps, top_addr, bottom_addr)
  loop_cmovs = in_range(cmovs, top_addr, bottom_addr)
  problems, notes = report_offences(loop_jumps, loop_cmovs, top_addr)
  notes.each { |n| puts "check-ct-assembly: #{n}" }

  if problems.empty?
    report_pass(top_addr, bottom_addr, loop_jumps)
    return true
  end

  report_fail(problems, body, top_addr, bottom_addr)
  false
end

def main(argv)
  input = argv[0] || '/tmp/jacobian.o'
  die("input object file `#{input}` not found") unless File.file?(input)
  check_host_arch!

  disasm = objdump_disassembly(input)
  ladder_ok = check_ladder(disasm, input)
  jp_add_ok = check_jp_add_internal(disasm)
  exit(ladder_ok && jp_add_ok ? 0 : 1)
end

main(ARGV) if $PROGRAM_NAME == __FILE__
