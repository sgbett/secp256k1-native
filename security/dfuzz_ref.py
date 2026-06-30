#!/usr/bin/env python3
"""Independent secp256k1 reference, written fresh from curve parameters.
Drives the C harness (./dfuzz) over millions of differential cases."""
import os, sys, random, subprocess

P = 2**256 - 2**32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
A = 0
B = 7
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

assert P == 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F

# ---------- field ops mod P ----------
def fadd(a, b): return (a + b) % P
def fsub(a, b): return (a - b) % P
def fneg(a): return (-a) % P
def fmul(a, b): return (a * b) % P
def fsqr(a): return (a * a) % P
def finv(a): return pow(a, P - 2, P)   # a in [1,P)
def fred(hi, lo): return ((hi << 256) + lo) % P

def fsqrt(a):
    """Return (flag, root). Mirrors C: r = a^((P+1)/4); flag=1 iff r^2==a%P.
    C returns the computed r in both cases."""
    am = a % P
    r = pow(am, (P + 1) // 4, P)
    flag = 1 if (r * r) % P == am else 0
    return flag, r

# ---------- scalar ops mod N ----------
def sadd(a, b): return (a + b) % N
def smul(a, b): return (a * b) % N
def sinv(a): return pow(a, N - 2, N)   # a in [1,N)
def sreduce(hi, lo): return ((hi << 256) + lo) % N

# ---------- Jacobian point ops over F_P ----------
# Infinity = [0,1,0]. affine (x,y) -> [x,y,1].
def jp_double(Pt):
    X1, Y1, Z1 = Pt
    # C special-cases Y1==0 -> infinity (independent of Z1). Mirror that.
    if Y1 % P == 0:
        return [0, 1, 0]
    Y1sq = fsqr(Y1)
    S = fmul(4, fmul(X1, Y1sq))
    M = fmul(3, fsqr(X1))
    X3 = fsub(fsqr(M), fmul(2, S))
    Y3 = fsub(fmul(M, fsub(S, X3)), fmul(8, fsqr(Y1sq)))
    Z3 = fmul(2, fmul(Y1, Z1))
    return [X3, Y3, Z3]

def jp_neg(Pt):
    X, Y, Z = Pt
    return [X % P, fneg(Y), Z % P]

def jp_add(Pt, Qt):
    X1, Y1, Z1 = Pt
    X2, Y2, Z2 = Qt
    pz_zero = (Z1 % P == 0)
    qz_zero = (Z2 % P == 0)
    Z1Z1 = fsqr(Z1); Z2Z2 = fsqr(Z2)
    U1 = fmul(X1, Z2Z2); U2 = fmul(X2, Z1Z1)
    S1 = fmul(Y1, fmul(Z2, Z2Z2)); S2 = fmul(Y2, fmul(Z1, Z1Z1))
    H = fsub(U2, U1)
    R = fsub(S2, S1)
    H2 = fsqr(H); H3 = fmul(H, H2)
    V = fmul(U1, H2)
    X3 = fsub(fsub(fsqr(R), H3), fmul(2, V))
    Y3 = fsub(fmul(R, fsub(V, X3)), fmul(S1, H3))
    Z3 = fmul(H, fmul(Z1, Z2))
    res = [X3, Y3, Z3]
    h_zero = (H == 0); r_zero = (R == 0)
    if h_zero and r_zero:
        res = jp_double([X1, Y1, Z1])
    if h_zero and not r_zero:
        res = [0, 1, 0]
    if qz_zero:
        res = [X1 % P, Y1 % P, Z1 % P]
    if pz_zero:
        res = [X2 % P, Y2 % P, Z2 % P]
    return res

def scalar_multiply_ct(k, base):
    """Montgomery ladder, mirroring the C loop exactly (255..0, k arbitrary 256-bit)."""
    r0 = [0, 1, 0]
    r1 = [base[0], base[1], base[2]]
    for i in range(255, -1, -1):
        bit = (k >> i) & 1
        if bit:
            r0, r1 = r1, r0
        r1 = jp_add(r0, r1)
        r0 = jp_double(r0)
        if bit:
            r0, r1 = r1, r0
    return r0

# ---------- on-curve helpers for structured corners ----------
def lift_x(x):
    """Return on-curve y for given x if exists, else None."""
    rhs = (pow(x, 3, P) + 7) % P
    flag, y = fsqrt(rhs)
    if flag:
        return y
    return None

def affine_from_jdouble_chain():
    """Generate small multiples of G as affine (x,y,1) Jacobian points using
    independent python EC math (no C)."""
    pts = []
    # double-and-add over affine with explicit modular inverse
    def aff_add(p, q):
        if p is None: return q
        if q is None: return p
        x1,y1=p; x2,y2=q
        if x1==x2 and (y1+y2)%P==0: return None
        if p==q:
            m=(3*x1*x1)*pow(2*y1,P-2,P)%P
        else:
            m=(y2-y1)*pow((x2-x1)%P,P-2,P)%P
        x3=(m*m-x1-x2)%P
        y3=(m*(x1-x3)-y1)%P
        return (x3,y3)
    G=(Gx,Gy)
    acc=None
    for i in range(1,40):
        acc=aff_add(acc,G)
        pts.append((i,acc))
    return pts

# ---------- harness driver ----------
HARNESS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dfuzz")

def h(x):
    return format(x & ((1<<256)-1), "064x")

def run_batch(lines):
    p = subprocess.run([HARNESS], input="".join(lines), capture_output=True, text=True)
    return p.stdout.splitlines()

MASK = (1 << 256) - 1


def _run_cases(cases):
    """cases: list of (op, args, expect). Sends ALL in one harness invocation
    (one subprocess, not one per op), returns the list of mismatches."""
    lines = [c[0] + " " + " ".join(h(a) for a in c[1]) + "\n" for c in cases]
    out = run_batch(lines)
    fails = []
    for (op, a, expect), line in zip(cases, out):
        got = int(line.split()[-1], 16) if line.split() else None
        if got != (expect & MASK):
            fails.append((op, [hex(x) for x in a], hex(expect & MASK),
                          hex(got) if got is not None else None))
    if len(out) != len(cases):
        fails.append(("<protocol>", [], f"{len(cases)} results", f"{len(out)} lines"))
    return fails


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="differential fuzz: C internals vs independent reference")
    ap.add_argument("--iters", type=int, default=int(os.environ.get("ITERS", 200000)),
                    help="random iterations per op-class (default 200000)")
    ap.add_argument("--seed", type=int, default=1, help="PRNG seed (reproducible)")
    ap.add_argument("--chunk", type=int, default=20000, help="cases per harness batch")
    args = ap.parse_args()
    print("reference module loaded; P,N ok")
    rng = random.Random(args.seed)

    # ---- in-contract random pass: operands reduced (< P for field, < N for scalar) ----
    F2 = [("fmul", fmul), ("fadd", fadd), ("fsub", fsub)]
    F1 = [("fsqr", fsqr), ("fneg", fneg)]
    S2 = [("smul", smul), ("sadd", sadd)]
    fails, batch = [], []

    def flush():
        if batch:
            fails.extend(_run_cases(batch))
            batch.clear()

    for _ in range(args.iters):
        a, b = rng.randrange(P), rng.randrange(P)
        for op, ref in F2:
            batch.append((op, [a, b], ref(a, b)))
        for op, ref in F1:
            batch.append((op, [a], ref(a)))
        if a:
            batch.append(("finv", [a], finv(a)))
        x, y = rng.randrange(N), rng.randrange(N)
        for op, ref in S2:
            batch.append((op, [x, y], ref(x, y)))
        if x:
            batch.append(("sinv", [x], sinv(x)))
        if len(batch) >= args.chunk:
            flush()
    flush()
    print(f"in-contract random pass: {args.iters} iters/op-class, {len(fails)} mismatches")
    incontract = len(fails)

    # ---- structured regression vectors for documented findings ----
    # These are the load-bearing cases random testing provably cannot reach
    # (H-1's failing band has density ~2^-384). Each was EXPECTED to diverge
    # on the reviewed v1.0 tree; post-#21 (scalar reduction carry) and #22
    # (boundary input contracts) all should now turn clean. The vectors stay
    # in the harness as a regression guard.
    print("\nstructured regression vectors (post-#21 / #22: all should be clean):")
    regr = _run_cases([
        # #21: scalar reduction carry
        ("smul", [2**256 - 1, N + 2], smul(2**256 - 1, N + 2)),                  # H-1
        ("sreduce", [N + 1, 0], sreduce(N + 1, 0)),                              # I-2 (same root cause)
        # #22: scalar boundary
        ("sadd", [N, N], sadd(N, N)),                                            # M-1
        ("sadd", [2**256 - 1, 2**256 - 1], sadd(2**256 - 1, 2**256 - 1)),        # M-1
        # #22: field boundary
        ("fadd", [P - 1, P + 1], fadd(P - 1, P + 1)),                            # L-3
        ("fneg", [P], fneg(P)),                                                  # I-3
        ("fsub", [P - 1, P + 5], fsub(P - 1, P + 5)),                            # L-3
    ])
    for op, a, ex, got in regr:
        print(f"  DIVERGES {op}({', '.join(a)}): ref={ex} c={got}")
    if not regr:
        print("  (none diverge — all documented findings closed)")

    print(f"\nSUMMARY: in-contract mismatches={incontract}; "
          f"regression vectors diverging={len(regr)}/7")
    # Fail on either: a new in-contract mismatch (random pass), or a
    # regression in any of the documented vectors (post-#21/#22 they must
    # all stay clean).  The wrapper for `make check` / `run-checks.sh`
    # treats a non-zero exit as FAIL.
    sys.exit(1 if (incontract or regr) else 0)
