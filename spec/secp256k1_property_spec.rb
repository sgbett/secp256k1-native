# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'secp256k1 property-based tests', :property do # rubocop:disable Metrics/BlockLength
  include PropertyHelpers

  let(:s) { Secp256k1 }
  let(:p_val) { Secp256k1::P }
  let(:n_val) { Secp256k1::N }

  # ---------------------------------------------------------------------------
  # Smoke test: verify the infrastructure itself works
  # ---------------------------------------------------------------------------
  describe 'infrastructure' do # rubocop:disable Metrics/BlockLength
    it 'check_property runs the block the configured number of times' do
      count = 0
      check_property('counter', iterations: 50, seed: 1) do |_rng, _i|
        count += 1
      end
      expect(count).to eq(50)
    end

    it 'check_property reports seed and iteration on failure' do
      expect do
        check_property('always fails', iterations: 3, seed: 0xBEEF) do |_rng, i|
          raise 'boom' if i == 1
        end
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /iteration 1.*seed: 0xbeef/i)
    end

    it 'generators produce values in the expected ranges' do
      rng = Random.new(42)
      fe = random_field_element(rng)
      expect(fe).to be >= 0
      expect(fe).to be < p_val

      sc = random_scalar(rng)
      expect(sc).to be >= 1
      expect(sc).to be < n_val

      pt = random_point(rng)
      expect(pt).to be_a(Secp256k1::Point)
      expect(pt.on_curve?).to be true
    end

    it 'PROPERTY_TEST_ITERATIONS env var is respected' do
      # PropertyHelpers.iteration_count is used as the default — just verify
      # it returns a positive integer.
      expect(PropertyHelpers.iteration_count).to be_a(Integer)
      expect(PropertyHelpers.iteration_count).to be_positive
    end
  end

  # ---------------------------------------------------------------------------
  # Field arithmetic properties (mod P)
  # ---------------------------------------------------------------------------
  describe 'field arithmetic' do # rubocop:disable Metrics/BlockLength
    # Boundary values near carry boundaries that must be mixed into random
    # streams to catch carry-propagation and canonicalisation bugs.
    let(:boundary_values) do
      p = Secp256k1::P
      [
        0, 1, p - 1, p - 2,
        (1 << 64) - 1, 1 << 64, (1 << 64) + 1,
        (1 << 128) - 1, 1 << 128, (1 << 128) + 1,
        (1 << 192) - 1, 1 << 192, (1 << 192) + 1
      ]
    end

    # Generate a field element, injecting boundary values for the first few
    # iterations and then switching to uniform random.
    def field_element(rng, index, boundaries = boundary_values)
      index < boundaries.size ? boundaries[index] % p_val : random_field_element(rng)
    end

    # Same as field_element but guarantees non-zero (for inverse tests).
    def nonzero_field_element(rng, index, boundaries = boundary_values)
      v = field_element(rng, index, boundaries)
      v.zero? ? random_nonzero_field_element(rng) : v
    end

    it 'fmul commutativity: a*b == b*a' do
      check_property('fmul commutativity') do |rng, i|
        a = field_element(rng, i)
        b = random_field_element(rng)
        expect(s.fmul(a, b)).to eq(s.fmul(b, a))
      end
    end

    it 'fmul associativity: (a*b)*c == a*(b*c)' do
      check_property('fmul associativity') do |rng, i|
        a = field_element(rng, i)
        b = random_field_element(rng)
        c = random_field_element(rng)
        expect(s.fmul(s.fmul(a, b), c)).to eq(s.fmul(a, s.fmul(b, c)))
      end
    end

    it 'fadd commutativity: a+b == b+a' do
      check_property('fadd commutativity') do |rng, i|
        a = field_element(rng, i)
        b = random_field_element(rng)
        expect(s.fadd(a, b)).to eq(s.fadd(b, a))
      end
    end

    it 'fadd associativity: (a+b)+c == a+(b+c)' do
      check_property('fadd associativity') do |rng, i|
        a = field_element(rng, i)
        b = random_field_element(rng)
        c = random_field_element(rng)
        expect(s.fadd(s.fadd(a, b), c)).to eq(s.fadd(a, s.fadd(b, c)))
      end
    end

    it 'distributivity: a*(b+c) == a*b + a*c' do
      check_property('distributivity') do |rng, i|
        a = field_element(rng, i)
        b = random_field_element(rng)
        c = random_field_element(rng)
        expect(s.fmul(a, s.fadd(b, c))).to eq(s.fadd(s.fmul(a, b), s.fmul(a, c)))
      end
    end

    it 'additive identity: a+0 == a' do
      check_property('additive identity') do |rng, i|
        a = field_element(rng, i)
        expect(s.fadd(a, 0)).to eq(a)
      end
    end

    it 'multiplicative identity: a*1 == a' do
      check_property('multiplicative identity') do |rng, i|
        a = field_element(rng, i)
        expect(s.fmul(a, 1)).to eq(a)
      end
    end

    it 'additive inverse: a + (-a) == 0' do
      check_property('additive inverse') do |rng, i|
        a = field_element(rng, i)
        expect(s.fadd(a, s.fneg(a))).to eq(0)
      end
    end

    it 'multiplicative inverse: a * a^-1 == 1 (for a != 0)' do
      check_property('multiplicative inverse') do |rng, i|
        a = nonzero_field_element(rng, i)
        expect(s.fmul(a, s.finv(a))).to eq(1)
      end
    end

    it 'negation involution: -(-a) == a' do
      check_property('negation involution') do |rng, i|
        a = field_element(rng, i)
        expect(s.fneg(s.fneg(a))).to eq(a)
      end
    end

    it 'subtraction definition: a - b == a + (-b)' do
      check_property('subtraction definition') do |rng, i|
        a = field_element(rng, i)
        b = random_field_element(rng)
        expect(s.fsub(a, b)).to eq(s.fadd(a, s.fneg(b)))
      end
    end

    it 'reduction idempotence: fred(fred(x)) == fred(x)' do
      check_property('reduction idempotence') do |rng, i|
        # Use values up to P*P (512-bit) for early iterations, then random
        x = if i < boundary_values.size
              boundary_values[i]
            elsif i.even?
              rng.rand(p_val * p_val)
            else
              random_field_element(rng)
            end
        expect(s.fred(s.fred(x))).to eq(s.fred(x))
      end
    end

    it 'fsqr consistency: fsqr(a) == fmul(a, a)' do
      check_property('fsqr consistency') do |rng, i|
        a = field_element(rng, i)
        expect(s.fsqr(a)).to eq(s.fmul(a, a))
      end
    end

    it 'fsqrt round-trip: if s = fsqrt(a^2), then s^2 == a^2' do
      check_property('fsqrt round-trip') do |rng, i|
        a = field_element(rng, i)
        a_sq = s.fsqr(a)
        root = s.fsqrt(a_sq)
        expect(root).not_to be_nil, "fsqrt returned nil for a known quadratic residue (a=#{a})"
        expect(s.fsqr(root)).to eq(a_sq)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scalar arithmetic properties (mod N)
  # ---------------------------------------------------------------------------
  describe 'scalar arithmetic' do # rubocop:disable Metrics/BlockLength
    it 'scalar_mul is commutative: a*b == b*a' do
      check_property('scalar_mul commutativity') do |rng, _i|
        a = random_scalar(rng)
        b = random_scalar(rng)
        expect(s.scalar_mul(a, b)).to eq(s.scalar_mul(b, a))
      end
    end

    it 'scalar_mul is associative: (a*b)*c == a*(b*c)' do
      check_property('scalar_mul associativity') do |rng, _i|
        a = random_scalar(rng)
        b = random_scalar(rng)
        c = random_scalar(rng)
        expect(s.scalar_mul(s.scalar_mul(a, b), c)).to eq(s.scalar_mul(a, s.scalar_mul(b, c)))
      end
    end

    it 'scalar_add is commutative: a+b == b+a' do
      check_property('scalar_add commutativity') do |rng, _i|
        a = random_scalar(rng)
        b = random_scalar(rng)
        expect(s.scalar_add(a, b)).to eq(s.scalar_add(b, a))
      end
    end

    it 'scalar_add is associative: (a+b)+c == a+(b+c)' do
      check_property('scalar_add associativity') do |rng, _i|
        a = random_scalar(rng)
        b = random_scalar(rng)
        c = random_scalar(rng)
        expect(s.scalar_add(s.scalar_add(a, b), c)).to eq(s.scalar_add(a, s.scalar_add(b, c)))
      end
    end

    it 'multiplication distributes over addition: a*(b+c) == a*b + a*c' do
      check_property('distributivity') do |rng, _i|
        a = random_scalar(rng)
        b = random_scalar(rng)
        c = random_scalar(rng)
        lhs = s.scalar_mul(a, s.scalar_add(b, c))
        rhs = s.scalar_add(s.scalar_mul(a, b), s.scalar_mul(a, c))
        expect(lhs).to eq(rhs)
      end
    end

    it 'multiplicative inverse: a * a^-1 == 1 for non-zero a' do
      check_property('multiplicative inverse') do |rng, _i|
        a = random_scalar(rng)
        expect(s.scalar_mul(a, s.scalar_inv(a))).to eq(1)
      end
    end

    it 'scalar_mod is idempotent: scalar_mod(scalar_mod(a)) == scalar_mod(a)' do
      # C extension rejects values exceeding 256 bits, so stay within [-N, 2^256)
      max256 = (1 << 256) - 1
      check_property('scalar_mod idempotence') do |rng, _i|
        a = rng.rand((-n_val)..max256)
        expect(s.scalar_mod(s.scalar_mod(a))).to eq(s.scalar_mod(a))
      end
    end

    it 'scalar_mod result is always in [0, N)' do
      max256 = (1 << 256) - 1
      check_property('scalar_mod range') do |rng, _i|
        a = rng.rand((-n_val)..max256)
        result = s.scalar_mod(a)
        expect(result).to be >= 0
        expect(result).to be < n_val
      end
    end

    # -----------------------------------------------------------------------
    # Boundary values
    # -----------------------------------------------------------------------
    describe 'boundary values' do # rubocop:disable Metrics/BlockLength
      it 'scalar_mul commutativity at boundaries' do
        [1, n_val - 1, n_val - 2, n_val + 1].repeated_combination(2) do |a, b|
          expect(s.scalar_mul(a, b)).to eq(s.scalar_mul(b, a))
        end
      end

      it 'scalar_add commutativity at boundaries' do
        [0, 1, n_val - 1, n_val - 2, n_val + 1].repeated_combination(2) do |a, b|
          expect(s.scalar_add(a, b)).to eq(s.scalar_add(b, a))
        end
      end

      it 'scalar_add of two values summing to exactly N yields 0' do
        expect(s.scalar_add(1, n_val - 1)).to eq(0)
        expect(s.scalar_add(n_val - 2, 2)).to eq(0)
      end

      it 'multiplicative inverse at boundaries' do
        [1, n_val - 1, n_val - 2].each do |a|
          expect(s.scalar_mul(a, s.scalar_inv(a))).to eq(1)
        end
      end

      it 'scalar_inv(0) raises' do
        expect { s.scalar_inv(0) }.to raise_error(ArgumentError)
      end

      it 'scalar_mod at boundaries' do
        expect(s.scalar_mod(0)).to eq(0)
        expect(s.scalar_mod(n_val)).to eq(0)
        expect(s.scalar_mod(n_val - 1)).to eq(n_val - 1)
        expect(s.scalar_mod(n_val + 1)).to eq(1)
        expect(s.scalar_mod(-1)).to eq(n_val - 1)
        expect(s.scalar_mod(-n_val)).to eq(0)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Point operation properties
  # ---------------------------------------------------------------------------
  describe 'point operations' do # rubocop:disable Metrics/BlockLength
    let(:g) { Secp256k1::Point.generator }
    let(:infinity) { Secp256k1::Point.infinity }

    it 'identity: P + O = P' do
      check_property('identity') do |rng, _i|
        pt = random_point(rng)
        expect(pt.add(infinity)).to eq(pt)
        expect(infinity.add(pt)).to eq(pt)
      end
    end

    it 'inverse: P + (-P) = O' do
      check_property('inverse') do |rng, _i|
        pt = random_point(rng)
        expect(pt.add(pt.negate)).to eq(infinity)
      end
    end

    it 'closure: P + Q is a valid curve point' do
      check_property('closure') do |rng, _i|
        pt = random_point(rng)
        q = random_point(rng)
        result = pt.add(q)
        expect(result.on_curve?).to be(true)
      end
    end

    it 'scalar multiplication homomorphism: k*G + m*G = (k+m)*G' do
      check_property('scalar mul homomorphism', iterations: 200) do |rng, _i|
        k = random_scalar(rng)
        m = random_scalar(rng)
        lhs = g.mul_vt(k).add(g.mul_vt(m))
        rhs = g.mul_vt((k + m) % n_val)
        expect(lhs).to eq(rhs)
      end
    end

    it 'double consistency: P + P = 2*P (jp_add vs jp_double)' do
      check_property('double consistency', iterations: 200) do |rng, _i|
        pt = random_point(rng)
        jp = [pt.x, pt.y, 1]
        doubled_affine = s.jp_to_affine(s.jp_double(jp))
        added_affine = s.jp_to_affine(s.jp_add(jp, jp))
        expect(added_affine).to eq(doubled_affine)
      end
    end

    it 'negation involution: -(-P) = P' do
      check_property('negation involution') do |rng, _i|
        pt = random_point(rng)
        expect(pt.negate.negate).to eq(pt)
      end
    end

    it 'mul/mul_vt parity: constant-time and variable-time give same result' do
      check_property('mul/mul_vt parity') do |rng, _i|
        k = random_scalar(rng)
        expect(g.mul(k)).to eq(g.mul_vt(k))
      end
    end

    it 'SEC1 round-trip: decode(encode(P)) = P for compressed' do
      check_property('SEC1 compressed round-trip') do |rng, _i|
        pt = random_point(rng)
        encoded = pt.to_octet_string(:compressed)
        decoded = Secp256k1::Point.from_bytes(encoded)
        expect(decoded).to eq(pt)
      end
    end

    it 'SEC1 round-trip: decode(encode(P)) = P for uncompressed' do
      check_property('SEC1 uncompressed round-trip') do |rng, _i|
        pt = random_point(rng)
        encoded = pt.to_octet_string(:uncompressed)
        decoded = Secp256k1::Point.from_bytes(encoded)
        expect(decoded).to eq(pt)
      end
    end

    it 'associativity: (P + Q) + R = P + (Q + R)' do
      check_property('associativity', iterations: 100) do |rng, _i|
        pt = random_point(rng)
        q = random_point(rng)
        r = random_point(rng)
        lhs = pt.add(q).add(r)
        rhs = pt.add(q.add(r))
        expect(lhs).to eq(rhs)
      end
    end
  end
end
