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

UnionStationHooks.require_lib 'log'
UnionStationHooks.require_lib 'context'
UnionStationHooks.require_lib 'utils'

module UnionStationHooks
  # @private
  class Transaction
    attr_reader :txn_id

    def initialize(connection = nil, txn_id = nil)
      return if !connection
      @connection = connection
      @txn_id = txn_id
      connection.ref
    end

    def null?
      !@connection || !@connection.connected?
    end

    def message(text)
      if !@connection
        timestamp_string = Context.timestamp_string
        UnionStationHooks::Log.debug(
          "[Union Station log to null] #{@txn_id} #{timestamp_string} #{text}")
        return
      end
      @connection.synchronize do
        return if !@connection.connected?
        begin
          timestamp_string = Context.timestamp_string
          UnionStationHooks::Log.debug(
            "[Union Station log] #{@txn_id} #{timestamp_string} #{text}")
          @connection.channel.write('log', @txn_id, timestamp_string)
          @connection.channel.write_scalar(text)
        rescue SystemCallError, IOError => e
          @connection.disconnect
          UnionStationHooks::Log.warn(
            "Error communicating with the UstRouter: #{e.message}")
        rescue Exception => e
          @connection.disconnect
          raise e
        end
      end
    end

    def begin_measure(name, extra_info = nil)
      if extra_info
        extra_info_base64 = [extra_info].pack('m')
        extra_info_base64.delete!("\n")
        extra_info_base64.strip!
      else
        extra_info_base64 = nil
      end
      times = Utils.process_times
      message "BEGIN: #{name} (#{current_timestamp.to_s(36)}," \
        "#{times.utime.to_s(36)},#{times.stime.to_s(36)}) " \
        "#{extra_info_base64}"
    end

    def end_measure(name, error_encountered = false)
      times = Utils.process_times
      if error_encountered
        message "FAIL: #{name} (#{current_timestamp.to_s(36)}," \
          "#{times.utime.to_s(36)},#{times.stime.to_s(36)})"
      else
        message "END: #{name} (#{current_timestamp.to_s(36)}," \
          "#{times.utime.to_s(36)},#{times.stime.to_s(36)})"
      end
    end

    def measure(name, extra_info = nil)
      begin_measure(name, extra_info)
      begin
        yield
      rescue Exception
        error = true
        is_closed = closed?
        raise
      ensure
        end_measure(name, error) if !is_closed
      end
    end

    def measured_time_points(name, begin_time, end_time, extra_info = nil)
      if extra_info
        extra_info_base64 = [extra_info].pack('m')
        extra_info_base64.delete!("\n")
        extra_info_base64.strip!
      else
        extra_info_base64 = nil
      end
      begin_timestamp = begin_time.to_i * 1_000_000 + begin_time.usec
      end_timestamp = end_time.to_i * 1_000_000 + end_time.usec
      message "BEGIN: #{name} (#{begin_timestamp.to_s(36)}) " \
        "#{extra_info_base64}"
      message "END: #{name} (#{end_timestamp.to_s(36)})"
    end

    def close(should_flush_to_disk = false)
      @connection.synchronize do
        return if !@connection.connected?
        begin
          # We need an ACK here. See thread_handler.rb finalize_request.
          @connection.channel.write('closeTransaction', @txn_id,
            Context.timestamp_string, true)

          result = @connection.channel.read
          if result[0] != 'status'
            raise "Expected UstRouter to respond with 'status', " \
              "but got #{result.inspect} instead"
          elsif result[1] == 'ok'
            # Do nothing
          elsif result[1] == 'error'
            if result[2]
              raise "Unable to close transaction: #{result[2]}"
            else
              raise 'Unable to close transaction (no server message given)'
            end
          else
            raise "Expected UstRouter to respond with 'ok' or 'error', " \
              "but got #{result.inspect} instead"
          end

          if should_flush_to_disk
            flush_to_disk
          end
        rescue SystemCallError, IOError => e
          @connection.disconnect
          UnionStationHooks::Log.warn(
            "Error communicating with the UstRouter: #{e.message}")
        rescue Exception => e
          @connection.disconnect
          raise e
        ensure
          @connection.unref
          @connection = nil
        end
      end if @connection
    end

    def closed?
      return nil if !@connection
      @connection.synchronize do
        !@connection.connected?
      end
    end

  private

    def flush_to_disk
      @connection.channel.write('flush')
      result = @connection.channel.read
      if result[0] != 'status'
        raise "Expected UstRouter to respond with 'status', " \
          "but got #{result.inspect} instead"
      elsif result[1] == 'ok'
        # Do nothing
      elsif result[1] == 'error'
        if result[2]
          raise "Unable to close transaction: #{result[2]}"
        else
          raise 'Unable to close transaction (no server message given)'
        end
      else
        raise "Expected UstRouter to respond with 'ok' or 'error', " \
          "but got #{result.inspect} instead"
      end
    end

    def current_timestamp
      time = Time.now
      time.to_i * 1_000_000 + time.usec
    end
  end
end
