# frozen_string_literal: true

require 'rake/extensiontask'
require 'rspec/core/rake_task'

Rake::ExtensionTask.new('secp256k1_native') do |ext|
  ext.ext_dir = 'ext/secp256k1_native'
end

RSpec::Core::RakeTask.new(:spec)

task default: %i[compile spec]

namespace :timing do
  desc 'Run dudect constant-time verification (slow — minutes, not seconds)'
  task :verify do
    Dir.chdir('timing') do
      sh 'make clean && make'
      sh './timing_harness'
    end
  end
end

namespace :docs do
  desc 'Generate YARD markdown into docs/reference/'
  task :generate do
    require 'fileutils'
    output_dir = 'docs/reference'
    FileUtils.rm_rf(output_dir)
    FileUtils.mkdir_p(output_dir)
    sh 'bundle exec yardoc --plugin markdown --format markdown --output-dir docs/reference lib/**/*.rb'
    generate_reference_index(output_dir)
  end

  desc 'Build the Jekyll docs site'
  task :build do
    _jekyll 'jekyll build'
  end

  desc 'Serve the Jekyll docs locally with livereload'
  task :serve do
    _jekyll 'jekyll serve --livereload'
  end

  REQUIRED_FRONTMATTER_KEYS = %w[title].freeze
  NAV_KEYS = %w[nav_order nav_exclude].freeze

  desc 'Lint hand-authored docs frontmatter (title + nav_order/nav_exclude)'
  task :lint do
    require 'yaml'

    docs_root = File.expand_path('docs', __dir__)
    excluded_prefixes = %w[_site reference vendor .bundle].map { |p| File.join(docs_root, p) }
    excluded_files = [File.join(docs_root, 'README.md')]

    md_files = Dir.glob(File.join(docs_root, '**', '*.md')).reject do |f|
      excluded_prefixes.any? { |prefix| f.start_with?("#{prefix}/") || f == prefix } ||
        excluded_files.include?(f)
    end

    errors = []
    md_files.each do |path|
      content = File.read(path)
      unless content.start_with?('---')
        errors << "#{path}: missing frontmatter block (file must begin with ---)"
        next
      end
      fm_match = content.match(/\A---\s*\n(.*?)\n---/m)
      unless fm_match
        errors << "#{path}: malformed frontmatter (no closing ---)"
        next
      end
      fm = YAML.safe_load(fm_match[1]) || {}
      REQUIRED_FRONTMATTER_KEYS.each do |k|
        errors << "#{path}: missing required frontmatter key: #{k}" unless fm[k]
      end
      unless NAV_KEYS.any? { |k| fm[k] }
        errors << "#{path}: must declare one of #{NAV_KEYS.join(' or ')}"
      end
    end

    if errors.empty?
      puts "docs:lint — #{md_files.size} file(s) checked, all OK"
    else
      errors.each { |e| warn e }
      exit 1
    end
  end

  desc 'Check internal links and anchors in the built site (offline)'
  task :proofread do
    require 'yaml'

    site_dir = File.expand_path('docs/_site', __dir__)
    unless File.directory?(site_dir) && !Dir.empty?(site_dir)
      abort "docs:proofread — #{site_dir} is missing or empty. Run `bundle exec rake docs:build` first."
    end

    baseurl = YAML.safe_load(File.read(File.expand_path('docs/_config.yml', __dir__)))['baseurl'].to_s
    swap = baseurl.empty? ? '' : %(--swap-urls "^#{Regexp.escape(baseurl)}:")
    _jekyll "htmlproofer _site --disable-external --enforce-https #{swap} " \
            '--ignore-empty-alt --ignore-missing-alt --allow-missing-href'
  end
end

desc 'Generate, build, lint, and proofread the docs site'
task docs: %w[docs:generate docs:build docs:lint docs:proofread]

def generate_reference_index(output_dir)
  require 'csv'
  csv_path = File.join(output_dir, 'index.csv')
  return unless File.exist?(csv_path)

  modules = []
  classes = []
  CSV.foreach(csv_path, headers: true) do |row|
    next unless %w[Module Class].include?(row['type'])

    entry = { name: row['name'], path: row['path'] }
    row['type'] == 'Module' ? modules << entry : classes << entry
  end

  File.open(File.join(output_dir, 'index.md'), 'w') do |f|
    f.puts '# API Reference'
    f.puts
    f.puts 'Auto-generated from source using [YARD](https://yardoc.org/).'
    f.puts
    f.puts '## Modules'
    f.puts
    modules.sort_by { |e| e[:name] }.each { |e| f.puts "- [#{e[:name]}](#{e[:path]})" }
    f.puts
    f.puts '## Classes'
    f.puts
    classes.sort_by { |e| e[:name] }.each { |e| f.puts "- [#{e[:name]}](#{e[:path]})" }
  end
end

def _jekyll(*args)
  Bundler.with_unbundled_env do
    Dir.chdir('docs') { sh "bundle exec #{args.join(' ')}" }
  end
end
