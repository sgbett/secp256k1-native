# frozen_string_literal: true

require 'secp256k1'

Dir[File.join(__dir__, 'support', '**', '*.rb')].sort.each { |f| require f }
