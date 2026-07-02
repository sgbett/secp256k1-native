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
# Symbol: scalar_multiply_ct_internal.
# Region: the trailing backward-branching loop (its target is the loop top,
#   its own address is the bottom).
# Failure conditions inside that region:
#   1. more than one conditional-jump mnemonic (j<cond>), OR
#   2. any conditional-move mnemonic (cmov<cond>).
#
# The check is deliberately scoped to the ladder loop body because that is
# the primitive whose *structural* branchlessness the CT contract depends on.
# Adjacent guards (#34 grep, dudect gate) cover the callee `jp_add_internal`
# where H-2's `uint256_select` calls compile.
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
require 'shellwords'

SYMBOL = 'scalar_multiply_ct_internal'

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
  version_out, status = Open3.capture2e(objdump, '--version')
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

# Report offences as an array of human-readable lines.
def report_offences(loop_jumps, loop_cmovs)
  problems = []
  if loop_jumps.size != 1
    problems << "expected exactly 1 conditional jump in ladder loop body, found #{loop_jumps.size}:"
    loop_jumps.each do |addr, mnem, target|
      problems << "    #{format('%#x', addr)}: #{mnem} -> #{format('%#x', target)}"
    end
  end
  unless loop_cmovs.empty?
    problems << "expected no conditional moves in ladder loop body, found #{loop_cmovs.size}:"
    loop_cmovs.each do |addr, mnem|
      problems << "    #{format('%#x', addr)}: #{mnem}"
    end
  end
  problems
end

def report_pass(top_addr, bottom_addr, loop_jumps)
  lo = format('%#x', top_addr)
  hi = format('%#x', bottom_addr)
  addr, mnem, = loop_jumps.first
  puts "check-ct-assembly: PASS -- #{SYMBOL} loop body [#{lo}..#{hi}] " \
       "contains exactly 1 conditional jump (#{format('%#x', addr)}: #{mnem}) and 0 cmov."
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

def check_host_arch!
  host = RbConfig::CONFIG['host_cpu'] || RUBY_PLATFORM
  return if host.include?('x86_64') || host.include?('amd64')

  skip("host CPU `#{host}` is not x86_64; this check targets GCC x86_64 codegen")
end

def main(argv)
  input = argv[0] || '/tmp/jacobian.o'
  die("input object file `#{input}` not found") unless File.file?(input)
  check_host_arch!

  disasm = objdump_disassembly(input)
  body = symbol_body(disasm, SYMBOL)
  die("symbol `#{SYMBOL}` not found in `#{input}` (was it compiled from jacobian.c?)") if body.nil?

  cond_jumps = collect_cond_jumps(body)
  cmovs = collect_cmovs(body)
  range = find_loop_range(body, cond_jumps)
  if range.nil?
    die("could not locate ladder loop in `#{SYMBOL}` -- no backward conditional jump found. " \
        'Codegen may have changed shape (unrolled?). Inspect objdump -dl output manually.')
  end

  top_addr, bottom_addr = range
  loop_jumps = in_range(cond_jumps, top_addr, bottom_addr)
  loop_cmovs = in_range(cmovs, top_addr, bottom_addr)
  problems = report_offences(loop_jumps, loop_cmovs)

  if problems.empty?
    report_pass(top_addr, bottom_addr, loop_jumps)
    exit 0
  end

  report_fail(problems, body, top_addr, bottom_addr)
  exit 1
end

main(ARGV) if $PROGRAM_NAME == __FILE__
