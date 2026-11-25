require "json"
require "yaml"

module ReservationContract
  class InvalidInput < StandardError; end

  PROPERTIES = %w[P1 P2 P3 P4].freeze
  OPERATORS = %w[eq gte count_lte].freeze

  def self.compile(source)
    raise InvalidInput, "expected contract version 1" unless source.fetch("version") == 1

    operation = source.fetch("operation")
    unless operation.fetch("method") == "POST" && operation.fetch("path").start_with?("/") &&
        operation.fetch("fields") == %w[reservation_id quantity]
      raise InvalidInput, "invalid operation"
    end

    cases = source.fetch("cases").transform_values do |scenario|
      checks = scenario.fetch("checks").map do |name, rule|
        unless rule.is_a?(Array) && rule.length == 3
          raise InvalidInput, "#{name}: expected [observation, operator, value]"
        end

        field, operator, value = rule
        unless field.is_a?(String) && OPERATORS.include?(operator) &&
            (operator == "eq" || value.is_a?(Integer))
          raise InvalidInput, "#{name}: invalid observation or operator operand"
        end

        { "name" => name, "field" => field, "operator" => operator, "value" => value }
      end
      given = scenario.fetch("given")
      unless given.is_a?(Hash) && !given.empty? && !checks.empty?
        raise InvalidInput, "each case needs preconditions and checks"
      end

      { "property" => scenario.fetch("property"), "given" => given, "checks" => checks }
    end
    unless cases.values.map { |scenario| scenario.fetch("property") }.uniq.sort == PROPERTIES
      raise InvalidInput, "contract must describe P1 through P4"
    end

    { "format" => "keisiki.reservation-observations.v1", "operation" => operation, "cases" => cases }
  end

  def self.check(scenario, given, observations)
    unless scenario.fetch("given").all? { |field, value| given.fetch(field) == value }
      raise InvalidInput, "case preconditions do not match the history"
    end

    scenario.fetch("checks").filter_map do |rule|
      field = rule.fetch("field")
      operator = rule.fetch("operator")
      actual = observations.fetch(field)
      value = rule.fetch("value")

      passes = case operator
      when "eq"
        actual == value
      when "gte"
        raise InvalidInput, "#{field}: expected an integer" unless actual.is_a?(Integer)

        actual >= value
      when "count_lte"
        raise InvalidInput, "#{field}: expected an array" unless actual.is_a?(Array)

        actual.length <= value
      else
        raise InvalidInput, "unsupported operator: #{operator}"
      end

      rule.fetch("name") unless passes
    end
  end

  def self.verify(compiled, fixtures)
    unless compiled.fetch("format") == "keisiki.reservation-observations.v1"
      raise InvalidInput, "unsupported compiled contract format"
    end

    cases = compiled.fetch("cases")
    unless fixtures.keys.sort == cases.keys.sort
      raise InvalidInput, "fixture and contract case names differ"
    end

    cases.flat_map do |name, scenario|
      fixture = fixtures.fetch(name)
      examples = fixture.fetch("cases")
      expectations = examples.map { |example| example.fetch("expected") }
      unless expectations.any?(&:empty?) && expectations.any? { |violations| !violations.empty? }
        raise InvalidInput, "#{name}: expected accepting and rejecting examples"
      end

      examples.map do |example|
        expected = example.fetch("expected")
        violations = check(scenario, fixture.fetch("given"), example.fetch("observations"))
        {
          "property" => scenario.fetch("property"),
          "case" => name,
          "example" => example.fetch("name"),
          "expected_violations" => expected,
          "observed_violations" => violations,
          "verified" => expected.sort == violations.sort
        }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    case ARGV.fetch(0)
    when "compile"
      source = YAML.safe_load_file(ARGV.fetch(1))
      puts JSON.pretty_generate(ReservationContract.compile(source))
    when "verify"
      compiled = JSON.parse(File.read(ARGV.fetch(1)))
      fixtures = YAML.safe_load_file(ARGV.fetch(2))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = ReservationContract.verify(compiled, fixtures)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts JSON.pretty_generate(elapsed_milliseconds: elapsed * 1_000, results: results)
      exit(results.all? { |result| result.fetch("verified") } ? 0 : 1)
    else
      raise ReservationContract::InvalidInput, "expected compile or verify"
    end
  rescue ReservationContract::InvalidInput, KeyError, IndexError, Psych::Exception, JSON::ParserError, Errno::ENOENT => error
    warn "Invalid experiment input: #{error.message}"
    exit 2
  end
end
