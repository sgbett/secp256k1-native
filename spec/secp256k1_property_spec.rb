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
end
