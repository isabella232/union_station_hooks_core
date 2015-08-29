#  Union Station - https://www.unionstationapp.com/
#  Copyright (c) 2010-2015 Phusion Holding B.V.
#
#  "Union Station" and "Passenger" are trademarks of Phusion Holding B.V.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.

require 'digest/md5'
UnionStationHooks.require_lib 'utils'

module UnionStationHooks
  class RequestReporter
    ###### Logging miscellaneous other information ######

    # Logs a user-defined activity, for display in the activity timeline.
    #
    # An activity is a block in the activity timeline in the Union Station
    # user interace. It has a name, a begin time and an end time.
    #
    # This form takes a block. Before and after the block runs, the time
    # is measured.
    #
    # @param name The name that should show up in the activity timeline.
    #   It can be any arbitrary name but may not contain newlines.
    # @return The block's return value.
    # @yield The block is expected to perform the activity.
    # @example
    #   reporter.log_activity("Preheat cache") do
    #     calculate_preheat_values.each_pair do |key, value|
    #       Rails.cache.write(key, value)
    #     end
    #   end
    def log_activity(name, &block)
      if null?
        yield
      else
        @transaction.log_activity(name, &block)
      end
    end

    # Logs a benchmarking activity, for display in the activity timeline.
    #
    # An activity is a block in the activity timeline in the Union Station
    # user interace. It has a name, a begin time and an end time.
    #
    # The primary use case of this method is to integrate with Rails's
    # benchmarking API (`ActiveSupport::Benchmarkable`). The Rails benchmarking
    # API allows you to run a block and to log how long that block has taken.
    # But you can also use it to integrate with the Ruby standard library's
    # `Benchmark` class.
    #
    # You can wrap a benchmark call in a `UnionStationHooks.log_benchmark`
    # call, so that an entry for it is displayed in the acitivity timeline.
    # This method measures the time before and after the block runs.
    #
    # The difference between this method and {#log_activity} is that this
    # method generates timeline blocks of a different color, as to differentiate
    # user-defined activities from benchmark activities.
    #
    # If your app is a Rails app, then the `union_station_hooks_rails` gem
    # automatically calls this for you every time
    # `ActiveSupport::Benchmarkable#benchmark` is called. This includes
    # `benchmark` calls from controllers and from views.
    #
    # @param title A title for this benchmark.
    # @return The block's return value.
    # @yield The block is expected to perform the benchmarking activity.
    # @example Rails example
    #   # This example shows what to put inside a Rails controller action
    #   # method. Note that the `log_benchmark` call is automatically done for
    #   # you if you use the union_station_hooks_rails gem.
    #   UnionStationHooks.log_benchmark('Process data files') do
    #     benchmark('Process data files') do
    #       expensive_files_operation
    #     end
    #   end
    def log_benchmark(title = 'Benchmarking', &block)
      if null?
        yield
      else
        log_activity("BENCHMARK: #{title}", &block)
      end
    end

    # Logs an exception that occurred during a request.
    #
    # If {#log_controller_action} or {#log_controller_action_happened}
    # was called during the same request, then the information passed to
    # those methods will be included in the exception report.
    #
    # @param [Exception] exception
    def log_exception(exception)
      transaction = @context.new_transaction(
        @app_group_name,
        :exceptions,
        @key)
      begin
        base64_message = exception.message
        base64_message = exception.to_s if base64_message.empty?
        base64_message = Utils.base64(base64_message)
        base64_backtrace = Utils.base64(exception.backtrace.join("\n"))

        if @txn_id
          transaction.message("Request transaction ID: #{@txn_id}")
        end
        if @controller_action
          transaction.message("Controller action: #{@controller_action}")
        end
        transaction.message("Message: #{base64_message}")
        transaction.message("Class: #{exception.class.name}")
        transaction.message("Backtrace: #{base64_backtrace}")
      ensure
        transaction.close
      end
    end

    # Logs a database query that was performed during the request.
    #
    # @option options [String] :name (optional) A name for this database
    #   query activity. Default: "SQL"
    # @option options [TimePoint or Time] :begin_time The time at which this
    #   database query begun. See {UnionStationHooks.now} to learn more.
    # @option options [TimePoint or Time] :end_time The time at which this
    #   database query ended. See {UnionStationHooks.now} to learn more.
    # @option options [String] :query The database query string.
    def log_database_query(options)
      return if null?
      Utils.require_key(options, :begin_time)
      Utils.require_key(options, :end_time)
      Utils.require_non_empty_key(options, :query)

      name = options[:name] || 'SQL'
      begin_time = options[:begin_time]
      end_time = options[:end_time]
      query = options[:query]

      digest = Digest::MD5.hexdigest("#{name}\0#{query}\0#{rand}")
      @transaction.log_activity_happened("DB BENCHMARK: #{digest}",
        begin_time, end_time, "#{name}\n#{query}")
    end

    # Logs that something was successfully retrieved from a cache.
    # This can be any cache, be it an in-memory Hash, Redis, Memcached, a
    # flat file or whatever.
    #
    # There is just one exception. You should not use this method to log cache
    # hits in the ActiveRecord SQL cache or similar mechanisms.
    # Database-related timing should be logged with {#log_database_query}.
    #
    # If your app is a Rails app, then the `union_station_hooks_rails` gem
    # automatically calls this for you every time an `ActiveSupport::Cache`
    # `#fetch` or `#read` call success. This includes calls to
    # `Rails.cache.fetch` or `Rails.cache.read`, because `Rails.cache` is
    # an instance of `ActiveSupport::Cache`.
    #
    # @param [String] name A unique name for this cache hit event. The cache
    #   key is a good value to use.
    def log_cache_hit(name)
      return if null?
      @transaction.message("Cache hit: #{name}")
    end

    # Logs the failure to retrieve something from a cache.
    # This can be any cache, be it an in-memory Hash, Redis, Memcached, a
    # flat file or whatever.
    #
    # There is just one exception. You should not use this method to log cache
    # misses in the ActiveRecord SQL cache or similar mechanisms.
    # Database-related timing should be logged with {#log_database_query}.
    #
    # If your app is a Rails app, then the `union_station_hooks_rails` gem
    # automatically calls this for you every time an `ActiveSupport::Cache`
    # `#fetch` or `#read` call success. This includes calls to
    # `Rails.cache.fetch` or `Rails.cache.read`, because `Rails.cache` is
    # an instance of `ActiveSupport::Cache`.
    #
    # @param [String] name A unique name for this cache miss event. The cache
    #   key is a good value to use.
    # @param [Integer] miss_cost_duration The amount of time that was spent in
    #   calculating or processing something, as a result of this cache miss.
    #   This time is in **microseconds**.
    def log_cache_miss(name, miss_cost_duration = nil)
      return if null?
      if miss_cost_duration
        @transaction.message("Cache miss (#{miss_cost_duration.to_i} usec): " \
          "#{name}")
      else
        @transaction.message("Cache miss: #{name}")
      end
    end
  end
end
