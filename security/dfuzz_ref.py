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

def _drive(op, args, expect, fails):
    """Send one 'op arg...' line, compare hex result to expect."""
    line = op + " " + " ".join(h(a) for a in args) + "\n"
    out = run_batch([line])
    got = int(out[0].split()[-1], 16) if out else None
    if got != (expect & ((1 << 256) - 1)):
        fails.append((op, [hex(a) for a in args], hex(expect), hex(got) if got is not None else None))


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="differential fuzz: C internals vs independent reference")
    ap.add_argument("--iters", type=int, default=int(os.environ.get("ITERS", 200000)),
                    help="random iterations per op-class (default 200000)")
    ap.add_argument("--seed", type=int, default=1, help="PRNG seed (reproducible)")
    args = ap.parse_args()
    print("reference module loaded; P,N ok")
    rng = random.Random(args.seed)
    fails = []

    # ---- in-contract random pass: operands reduced (< P for field, < N for scalar) ----
    F2 = [("fmul", fmul), ("fadd", fadd), ("fsub", fsub)]
    F1 = [("fsqr", fsqr), ("fneg", fneg)]
    S2 = [("smul", smul), ("sadd", sadd)]
    for _ in range(args.iters):
        a, b = rng.randrange(P), rng.randrange(P)
        for op, ref in F2:
            _drive(op, [a, b], ref(a, b), fails)
        for op, ref in F1:
            _drive(op, [a], ref(a), fails)
        if a:
            _drive("finv", [a], finv(a), fails)
        x, y = rng.randrange(N), rng.randrange(N)
        for op, ref in S2:
            _drive(op, [x, y], ref(x, y), fails)
        if x:
            _drive("sinv", [x], sinv(x), fails)
    print(f"in-contract random pass: {args.iters} iters/op-class, {len(fails)} mismatches")
    incontract = len(fails)

    # ---- structured regression vectors that reproduce the documented findings ----
    # These are the load-bearing cases random testing provably cannot reach
    # (H-1's failing band has density ~2^-384). Each is EXPECTED to diverge on the
    # reviewed v1.0 tree and must turn clean once the H-1/M-1 fixes land.
    print("\nstructured regression vectors (expected to diverge until fixed):")
    regr = []
    _drive("smul", [2**256 - 1, N + 2], smul(2**256 - 1, N + 2), regr)     # H-1
    _drive("sreduce", [N + 1, 0], sreduce(N + 1, 0), regr)                 # I-2 (same root cause)
    _drive("sadd", [N, N], sadd(N, N), regr)                              # M-1
    _drive("sadd", [2**256 - 1, 2**256 - 1], sadd(2**256 - 1, 2**256 - 1), regr)  # M-1
    for op, a, ex, got in regr:
        print(f"  DIVERGES {op}({', '.join(a)}): ref={ex} c={got}")
    if not regr:
        print("  (none diverge — H-1/M-1 fixes appear to be in place)")

    print(f"\nSUMMARY: in-contract mismatches={incontract}; "
          f"known-defect vectors reproducing={len(regr)}/4")
    sys.exit(1 if incontract else 0)
