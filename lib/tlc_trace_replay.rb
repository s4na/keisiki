module TlcTraceReplay
  def self.call(steps, stages:, target:, &request)
    turns = steps.map { |step| step.fetch("request") }.uniq.to_h { |id| [id, Queue.new] }
    completed = Queue.new
    workers = turns.to_h do |id, queue|
      worker = Thread.new do
        trace = TracePoint.new(:call, :return) do |point|
          next unless point.defined_class == target && stages.value?(point.method_id)

          if point.event == :call
            planned = queue.pop(timeout: 5)
            raise "Unexpected #{id}.#{point.method_id}" unless planned == point.method_id
          else
            completed << [id, point.method_id]
          end
        end
        trace.enable(target_thread: Thread.current) { request.call(id) }
      end
      [id, worker]
    end

    steps.each do |step|
      id = step.fetch("request")
      method = stages.fetch(step.fetch("stage"))
      turns.fetch(id) << method
      unless completed.pop(timeout: 5) == [id, method]
        raise "Did not reach #{id}.#{method}"
      end
    end

    workers.transform_values do |worker|
      raise "Unit operation did not finish" unless worker.join(5)

      worker.value
    end
  ensure
    workers&.each_value(&:kill)
  end
end
