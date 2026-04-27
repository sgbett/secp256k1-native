# frozen_string_literal: true

require_relative 'lib/secp256k1/version'

Gem::Specification.new do |spec|
  spec.name          = 'secp256k1-native'
  spec.version       = Secp256k1::VERSION
  spec.authors       = ['Simon Bettison']
  spec.email         = ['simon@bettison.org']
  spec.summary       = 'Pure native C secp256k1 implementation for Ruby (no libsecp256k1 dependency)'
  spec.description   = <<~DESC
    A standalone Ruby gem providing secp256k1 elliptic curve primitives via a native C
    extension. Implements field arithmetic, scalar operations, Jacobian point arithmetic,
    and constant-time Montgomery ladder scalar multiplication — all without any dependency
    on libsecp256k1. Suitable for any Ruby project requiring secp256k1 operations.
  DESC
  spec.homepage      = 'https://github.com/sgbett/secp256k1-native'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 2.7'

  spec.extensions = ['ext/secp256k1_native/extconf.rb']

  spec.files = Dir.glob('lib/**/*') +
               Dir.glob('ext/**/*.{c,h,rb}') +
               ['secp256k1-native.gemspec', 'LICENSE', 'README.md', 'CHANGELOG.md']

  spec.require_paths = ['lib']
end
