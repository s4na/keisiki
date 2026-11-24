require "json"

example, trace_path, mode = ARGV
ENV["RAILS_ENV"] = "test"
require File.join(example, "config/application")
Rails.application.initialize!
Rails.application.eager_load!
Rails.application.routes.recognize_path("/stock/reservations", method: :post)

events = JSON.parse(File.read(trace_path)).fetch("states").map { |state| state.fetch("event") }
abort "Unexpected counterexample start" unless events.shift.fetch("stage") == "init"

stages = { "read" => :read_stock, "commit" => :commit }
turns = %w[a b].to_h { |request| [request, Queue.new] }
completed = Queue.new
workers = turns.to_h do |request, queue|
  worker = Thread.new do
    trace = TracePoint.new(:call, :return) do |point|
      next unless point.defined_class == ReservationStore && stages.value?(point.method_id)

      if point.event == :call
        expected_method = queue.pop(timeout: 10)
        raise "Unexpected step #{request}.#{point.method_id}" unless expected_method == point.method_id
      else
        completed << [request, point.method_id, point.return_value]
      end
    end

    trace.enable(target_thread: Thread.current) do
      Rack::MockRequest.new(Rails.application).post("/stock/reservations")
    end
  end
  [request, worker]
end

begin
  observed_statuses = {}
  events.each do |event|
    request = event.fetch("request")
    method = stages.fetch(event.fetch("stage"))
    turns.fetch(request) << method
    actual_request, actual_method, result = completed.pop(timeout: 10)
    unless [actual_request, actual_method] == [request, method]
      abort "Rails did not reach the step #{request}.#{method}"
    end

    model_result = Integer(event.fetch("result").fetch("#bigint"), 10)
    if method == :read_stock
      abort "Stock read differed from the model" unless result == model_result
    else
      abort "Expected a boolean commit outcome" unless result == true || result == false
      observed_statuses[request] = result ? 201 : 409
      if mode == "mutant" && observed_statuses.fetch(request) != model_result
        abort "Commit differed from the counterexample"
      end
    end
  end

  responses = workers.transform_values do |worker|
    abort "Rails request did not finish" unless worker.join(10)

    worker.value.status
  end
  expected = { "mutant" => [201, 201], "corrected" => [201, 409] }.fetch(mode)
  unless responses == observed_statuses && observed_statuses.values == expected
    abort "Unexpected Rails responses in #{mode}: #{responses.inspect}"
  end

  order = events.map { |event| "#{event.fetch("request")}.#{event.fetch("stage")}" }
  puts "Rails #{mode}: #{order.join(" -> ")}; HTTP #{observed_statuses.values.join(", ")}"
ensure
  workers.each_value(&:kill)
end
