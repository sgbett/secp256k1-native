# frozen_string_literal: true

require 'rake/extensiontask'
require 'rspec/core/rake_task'

Rake::ExtensionTask.new('secp256k1_native') do |ext|
  ext.ext_dir = 'ext/secp256k1_native'
end

RSpec::Core::RakeTask.new(:spec)

task default: %i[compile spec]
