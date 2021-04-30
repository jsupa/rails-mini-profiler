# frozen_string_literal: true

module RailsMiniProfiler
  class Middleware
    def initialize(app)
      @app = app
      @context = RailsMiniProfiler.context
      subscribe_to_default
    end

    DEFAULT_SUBSCRIPTIONS = %w[
      sql.active_record
      render_template.action_view
      render_partial.action_view
      process_action.action_controller
      rails_mini_profiler.total_time
    ].freeze

    def call(env)
      request = Request.new(env)
      return @app.call(env) unless Guard.new(request).profile?

      self.profiled_request = ProfiledRequest.new(request: request)
      status, headers, response = ActiveSupport::Notifications.instrument('rails_mini_profiler.total_time') do
        if defined?(StackProf) && StackProf.respond_to?(:run)
          results = nil
          flamegraph = StackProf.run(
            mode: :wall,
            raw: true,
            aggregate: false,
            interval: (2 * 1000).to_i
          ) { results = @app.call(env) }
          profiled_request.flamegraph = flamegraph
          results
        else
          @app.call(env)
        end
      end

      profiled_request.response = Response.new(status: status, headers: headers, response: response)
      save_request!

      response = modify_response
      [response.status, response.headers, response.response]
    end

    def profiled_request
      Thread.current[:rails_mini_profiler_current_request]
    end

    def profiled_request=(profiled_request)
      Thread.current[:rails_mini_profiler_current_request] = profiled_request
    end

    def track_trace(trace)
      return if profiled_request.nil?

      profiled_request.traces.append(trace)
    end

    private

    def save_request!
      profiled_request.complete!

      storage_instance = @context.storage_instance
      storage_instance.save(profiled_request)
    end

    def modify_response
      Badge.new(profiled_request).render
    end

    def subscribe_to_default
      DEFAULT_SUBSCRIPTIONS.each do |event|
        subscribe(event)
      end
    end

    def subscribe(*subscriptions)
      subscriptions.each do |subscription|
        ActiveSupport::Notifications.monotonic_subscribe(subscription) do |event|
          trace = Trace.new(
            name: event.name,
            start: event.time.to_f,
            finish: event.end.to_f,
            duration: event.duration.to_f.round(2),
            allocations: event.allocations,
            backtrace: Rails.backtrace_cleaner.clean(caller),
            payload: event.payload
          )
          track_trace(trace)
        end
      end
    end
  end
end
