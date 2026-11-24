require_relative "../lib/ruby_to_lean"

abort "Usage: ruby script/ruby_to_lean.rb SOURCE.rb [SOURCE.rb ...]" if ARGV.empty?

begin
  print RubyToLean.generate(ARGV)
rescue RubyToLean::Unsupported => error
  warn "UNSUPPORTED #{error.message}"
  exit 2
end
