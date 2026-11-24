require_relative "../lib/postgres_update_to_lean"

abort "Usage: ruby script/postgres_to_lean.rb QUERY.sql" unless ARGV.length == 1

begin
  puts PostgresUpdateToLean.generate(File.binread(ARGV.first))
rescue PostgresUpdateToLean::Unsupported => error
  warn "UNSUPPORTED #{error.message}"
  exit 2
end
