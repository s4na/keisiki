require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

ENV["RAILS_ENV"] = "test"
example = File.expand_path("../example", __dir__)
verifier = File.expand_path("../script/verify_stock.rb", __dir__)
require File.join(example, "config/application")
Rails.application.initialize!

requests = Rack::MockRequest.new(Rails.application)
{
  "/stock/remaining?stock=7&quantity=2" => 5,
  "/stock/remaining?stock=7&quantity=7" => 0,
  "/stock/remaining?stock=7&quantity=8" => 7
}.each do |path, remaining|
  response = requests.get(path)
  unless response.status == 200 && JSON.parse(response.body) == { "remaining" => remaining }
    abort "Unexpected Rails response for GET #{path}: #{response.status} #{response.body}"
  end
end

[
  "/stock/remaining?stock=7",
  "/stock/remaining?stock=7&quantity=invalid",
  "/stock/remaining?stock=7&quantity=-1",
  "/stock/remaining?stock=7&quantity[]=2"
].each do |path|
  response = requests.get(path)
  abort "Expected a 400 response for GET #{path}, got #{response.status}" unless response.status == 400
end
puts "Rails HTTP checks passed (3 accepted, 4 rejected)"

def expect_verifier(verifier, example, exit_status, output_prefix)
  output, status = Open3.capture2e(RbConfig.ruby, verifier, example)
  puts output
  unless status.exitstatus == exit_status && output.lines.any? { |line| line.start_with?(output_prefix) }
    abort "Expected #{output_prefix} with exit status #{exit_status}, got #{status.exitstatus}"
  end
end

expect_verifier(verifier, example, 0, "UNSAT:")

Dir.mktmpdir("keisiki-smoke-") do |directory|
  mutated_example = File.join(directory, "example")
  FileUtils.cp_r(example, mutated_example)
  source = File.join(mutated_example, "app/services/stock.rb")
  original = File.read(source)
  guarded_body = <<~RUBY.lines.map { |line| "    #{line}" }.join
    if quantity > stock
      stock
    else
      stock - quantity
    end
  RUBY
  abort "Could not locate the stock guard to mutate" unless original.include?(guarded_body)

  File.write(source, original.sub(guarded_body, "    stock - quantity\n"))
  expect_verifier(verifier, mutated_example, 10, "COUNTEREXAMPLE:")

  File.write(source, original.sub(guarded_body, "    stock.to_i\n"))
  expect_verifier(verifier, mutated_example, 2, "UNSUPPORTED:")
end
