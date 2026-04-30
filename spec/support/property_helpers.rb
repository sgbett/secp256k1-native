# frozen_string_literal: true

# Lightweight property-based testing helpers for secp256k1.
#
# Provides a +check_property+ method that runs a block many times with a
# deterministic local RNG, reporting the seed, iteration index, and specific
# inputs on failure.  Generators produce random field elements, scalars, and
# curve points suitable for algebraic law verification.
#
# Iteration count defaults to 1,000 and can be overridden with the
# +PROPERTY_TEST_ITERATIONS+ environment variable.
module PropertyHelpers
  # Default number of iterations per property.
  DEFAULT_ITERATIONS = 1_000

  # Parse the environment override once.  Non-numeric values are silently
  # ignored and the default is used instead.
  def self.iteration_count
    raw = ENV.fetch('PROPERTY_TEST_ITERATIONS', nil)
    return DEFAULT_ITERATIONS if raw.nil? || raw.strip.empty?

    parsed = Integer(raw, exception: false)
    parsed&.positive? ? parsed : DEFAULT_ITERATIONS
  end

  # Run a property check.
  #
  # @param name [String]   human-readable property description (used in
  #   failure messages)
  # @param iterations [Integer]  how many random inputs to test
  # @param seed [Integer]  deterministic seed for +Random.new+
  # @yield [rng, index]  block that should raise or call +expect+ on failure
  # @yieldparam rng [Random]  seeded local RNG — use this, not +Kernel.rand+
  # @yieldparam index [Integer]  zero-based iteration index
  def check_property(name, iterations: PropertyHelpers.iteration_count, seed: 0xC0FFEE, &block)
    rng = Random.new(seed)

    iterations.times do |i|
      block.call(rng, i)
    rescue RSpec::Expectations::ExpectationNotMetError, StandardError => e
      raise RSpec::Expectations::ExpectationNotMetError,
            "Property '#{name}' failed on iteration #{i} (seed: 0x#{seed.to_s(16)}): #{e.message}"
    end
  end

  # -------------------------------------------------------------------------
  # Generators
  # -------------------------------------------------------------------------

  # Random field element in [0, P).
  def random_field_element(rng)
    rng.rand(Secp256k1::P)
  end

  # Random non-zero field element in [1, P).
  def random_nonzero_field_element(rng)
    1 + rng.rand(Secp256k1::P - 1)
  end

  # Random scalar in [1, N).  Zero is excluded because most scalar
  # properties (inverse, multiplication) are undefined or trivial at zero.
  def random_scalar(rng)
    1 + rng.rand(Secp256k1::N - 1)
  end

  # Random curve point, generated as k*G for a random scalar k.
  def random_point(rng)
    Secp256k1::Point.generator.mul_vt(random_scalar(rng))
  end
end
