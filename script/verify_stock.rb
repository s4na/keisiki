require "json"
require "uri"
require_relative "../lib/stock_verifier"

ENV["RAILS_ENV"] = "test"
example = File.expand_path(ARGV.fetch(0, "../example"), __dir__)
require File.join(example, "config/application")
Rails.application.initialize!

begin
  result, inputs = StockVerifier.new(Stock.method(:remaining)).check
rescue StockVerifier::Unsupported => error
  warn "UNSUPPORTED: #{error.message}"
  exit 2
end

case result
when :unsat
  puts "UNSAT: Stock.remaining is nonnegative for all nonnegative integer inputs"
when :sat
  path = "/stock/remaining?#{URI.encode_www_form(inputs)}"
  response = Rack::MockRequest.new(Rails.application).get(path)
  remaining = JSON.parse(response.body).fetch("remaining") if response.status == 200
  unless remaining.is_a?(Integer) && remaining.negative?
    abort "Z3 counterexample did not reproduce through Rails: GET #{path} (#{response.status})"
  end

  puts "COUNTEREXAMPLE: GET #{path} -> #{response.status} #{response.body}"
  exit 10
when :unknown
  warn "UNKNOWN: Z3 could not solve the query"
  exit 2
end
