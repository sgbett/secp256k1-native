# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'cross-implementation parity', :property do # rubocop:disable Metrics/BlockLength
  include PropertyHelpers

  # Skip the entire file when the native extension is not available.
  before(:all) do
    require 'secp256k1_native'
  rescue LoadError
    skip 'Native extension not compiled — run `bundle exec rake compile` first'
  end

  let(:nat) { Secp256k1Native }
  let(:p_val) { Secp256k1::P }
  let(:n_val) { Secp256k1::N }
  let(:gx) { Secp256k1::GX }
  let(:gy) { Secp256k1::GY }

  # Convert a Jacobian point [X, Y, Z] to affine [x, y] for comparison.
  # Different implementations may produce different Z values; affine
  # coordinates are the canonical form.
  def to_affine(jac_pt)
    Secp256k1.jp_to_affine(jac_pt)
  end

  # ---------------------------------------------------------------------------
  # Field arithmetic: C extension vs mathematical definition
  # ---------------------------------------------------------------------------
  describe 'field arithmetic parity' do # rubocop:disable Metrics/BlockLength
    it 'fred: C matches x mod P' do
      check_property('fred parity') do |rng, i|
        # Use values up to P*P for the first half, smaller values after
        x = i.even? ? rng.rand(p_val * p_val) : rng.rand(p_val)
        expect(nat.fred(x)).to eq(x % p_val)
      end
    end

    it 'fmul: C matches (a * b) mod P' do
      check_property('fmul parity') do |rng, _i|
        a = rng.rand(p_val)
        b = rng.rand(p_val)
        expect(nat.fmul(a, b)).to eq((a * b) % p_val)
      end
    end

    it 'fsqr: C matches (a * a) mod P' do
      check_property('fsqr parity') do |rng, _i|
        a = rng.rand(p_val)
        expect(nat.fsqr(a)).to eq((a * a) % p_val)
      end
    end

    it 'fadd: C matches (a + b) mod P' do
      check_property('fadd parity') do |rng, _i|
        a = rng.rand(p_val)
        b = rng.rand(p_val)
        expect(nat.fadd(a, b)).to eq((a + b) % p_val)
      end
    end

    it 'fsub: C matches (a - b) mod P' do
      check_property('fsub parity') do |rng, _i|
        a = rng.rand(p_val)
        b = rng.rand(p_val)
        expected = (a - b) % p_val
        expect(nat.fsub(a, b)).to eq(expected)
      end
    end

    it 'fneg: C matches (-a) mod P' do
      check_property('fneg parity') do |rng, _i|
        a = rng.rand(p_val)
        expected = a.zero? ? 0 : p_val - a
        expect(nat.fneg(a)).to eq(expected)
      end
    end

    it 'finv: C matches a^(P-2) mod P' do
      check_property('finv parity') do |rng, _i|
        a = 1 + rng.rand(p_val - 1) # non-zero
        expect(nat.finv(a)).to eq(a.pow(p_val - 2, p_val))
      end
    end

    it 'fsqrt: C and Ruby agree on squares of random elements' do
      check_property('fsqrt parity') do |rng, _i|
        a = rng.rand(p_val)
        a_sq = (a * a) % p_val

        c_root = nat.fsqrt(a_sq)
        ruby_root = a_sq.pow((p_val + 1) / 4, p_val)
        ruby_root = nil unless (ruby_root * ruby_root) % p_val == a_sq % p_val

        # Both should find a root for a known quadratic residue
        expect(c_root).not_to be_nil
        # Compare via squaring — either root (r or P-r) is valid
        expect(nat.fsqr(c_root)).to eq(a_sq)
        expect((ruby_root * ruby_root) % p_val).to eq(a_sq)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scalar arithmetic: C extension vs mathematical definition
  # ---------------------------------------------------------------------------
  describe 'scalar arithmetic parity' do # rubocop:disable Metrics/BlockLength
    it 'scalar_mod: C matches a mod N' do
      check_property('scalar_mod parity') do |rng, _i|
        # C extension rejects values exceeding 256 bits, so stay within range
        a = rng.rand(n_val)
        expect(nat.scalar_mod(a)).to eq(a % n_val)
      end
    end

    it 'scalar_mul: C matches (a * b) mod N' do
      check_property('scalar_mul parity') do |rng, _i|
        a = rng.rand(n_val)
        b = rng.rand(n_val)
        expect(nat.scalar_mul(a, b)).to eq((a * b) % n_val)
      end
    end

    it 'scalar_inv: C matches a^(N-2) mod N' do
      check_property('scalar_inv parity') do |rng, _i|
        a = 1 + rng.rand(n_val - 1) # non-zero
        expect(nat.scalar_inv(a)).to eq(a.pow(n_val - 2, n_val))
      end
    end

    it 'scalar_add: C matches (a + b) mod N' do
      check_property('scalar_add parity') do |rng, _i|
        a = rng.rand(n_val)
        b = rng.rand(n_val)
        expect(nat.scalar_add(a, b)).to eq((a + b) % n_val)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Jacobian point operations: C extension vs Ruby reference
  #
  # Jacobian representations may differ (different Z values), so we always
  # compare in affine coordinates.
  # ---------------------------------------------------------------------------
  describe 'Jacobian point operation parity' do # rubocop:disable Metrics/BlockLength
    # Build a random on-curve Jacobian point from a random scalar k*G.
    def random_jacobian(rng)
      k = 1 + rng.rand(Secp256k1::N - 1)
      pt = Secp256k1::Point.generator.mul_vt(k)
      [pt.x, pt.y, 1]
    end

    it 'jp_double: C matches Ruby for random on-curve points' do
      check_property('jp_double parity') do |rng, _i|
        jp = random_jacobian(rng)
        c_result = nat.jp_double(jp)
        ruby_result = Secp256k1.jp_double(jp)
        expect(to_affine(c_result)).to eq(to_affine(ruby_result))
      end
    end

    it 'jp_add: C matches Ruby for random on-curve point pairs' do
      check_property('jp_add parity') do |rng, _i|
        jp1 = random_jacobian(rng)
        jp2 = random_jacobian(rng)
        c_result = nat.jp_add(jp1, jp2)
        ruby_result = Secp256k1.jp_add(jp1, jp2)
        expect(to_affine(c_result)).to eq(to_affine(ruby_result))
      end
    end

    it 'jp_neg: C matches Ruby for random on-curve points' do
      check_property('jp_neg parity') do |rng, _i|
        jp = random_jacobian(rng)
        c_result = nat.jp_neg(jp)
        ruby_result = Secp256k1.jp_neg(jp)
        # jp_neg preserves Z, so raw comparison should work,
        # but use affine for consistency
        expect(to_affine(c_result)).to eq(to_affine(ruby_result))
      end
    end

    it 'scalar_multiply_ct: C matches Ruby for random scalars on G' do
      check_property('scalar_multiply_ct parity', iterations: 100) do |rng, _i|
        k = 1 + rng.rand(Secp256k1::N - 1)
        c_result = nat.scalar_multiply_ct(k, gx, gy)
        ruby_result = Secp256k1.scalar_multiply_ct(k, gx, gy)
        expect(to_affine(c_result)).to eq(to_affine(ruby_result))
      end
    end
  end
end
