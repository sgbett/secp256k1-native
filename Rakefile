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
    inject_reference_frontmatter(output_dir)
  end

  desc 'Build the Jekyll docs site (runs docs:generate first)'
  task build: :generate do
    _jekyll 'jekyll', 'build'
  end

  desc 'Serve the Jekyll docs locally with livereload'
  task :serve do
    _jekyll 'jekyll', 'serve', '--livereload'
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
      begin
        fm = YAML.safe_load(fm_match[1]) || {}
      rescue Psych::SyntaxError => e
        errors << "#{path}: invalid frontmatter YAML — #{e.message}"
        next
      end
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
    args = %w[htmlproofer _site --disable-external --enforce-https]
    args += ['--swap-urls', "^#{Regexp.escape(baseurl)}:"] unless baseurl.empty?
    args += %w[--ignore-empty-alt --ignore-missing-alt --allow-missing-href]
    _jekyll(*args)
  end
end

desc 'Generate, build, lint, and proofread the docs site'
task docs: %w[docs:build docs:lint docs:proofread]

def inject_reference_frontmatter(output_dir)
  require 'csv'
  csv_path = File.join(output_dir, 'index.csv')
  return unless File.exist?(csv_path)

  CSV.foreach(csv_path, headers: true) do |row|
    next unless %w[Module Class].include?(row['type'])

    file = File.join(output_dir, row['path'])
    next unless File.exist?(file)

    content = File.read(file)
    next if content.start_with?('---')

    File.write(file, "---\ntitle: #{row['name']}\nparent: API Reference\n---\n\n#{content}")
  end
end

def _jekyll(*cmd)
  Bundler.with_unbundled_env do
    Dir.chdir('docs') { sh 'bundle', 'exec', *cmd }
  end
end
