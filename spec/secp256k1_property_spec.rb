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
end
