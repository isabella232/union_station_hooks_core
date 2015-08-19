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

require 'thread'
UnionStationHooks.require_lib 'connection'
UnionStationHooks.require_lib 'transaction'
UnionStationHooks.require_lib 'log'
UnionStationHooks.require_lib 'lock'
UnionStationHooks.require_lib 'utils'

module UnionStationHooks
  class Core
    RETRY_SLEEP = 0.2
    NETWORK_ERRORS = [Errno::EPIPE, Errno::ECONNREFUSED, Errno::ECONNRESET,
      Errno::EHOSTUNREACH, Errno::ENETDOWN, Errno::ENETUNREACH, Errno::ETIMEDOUT]

    include Utils

    def self.new_from_options(options)
      if options["analytics"] && options["ust_router_address"]
        new(options["ust_router_address"],
          options["ust_router_username"],
          options["ust_router_password"],
          options["node_name"])
      else
        nil
      end
    end

    attr_accessor :max_connect_tries
    attr_accessor :reconnect_timeout

    def initialize(ust_router_address, username, password, node_name)
      @server_address = ust_router_address
      @username = username
      @password = password
      if node_name && !node_name.empty?
        @node_name = node_name
      else
        @node_name = `hostname`.strip
      end
      @random_dev = File.open("/dev/urandom")

      # This mutex protects the following instance variables, but
      # not the contents of @connection.
      @mutex = Mutex.new

      @connection = Connection.new(nil)
      if @server_address && local_socket_address?(@server_address)
        @max_connect_tries = 10
      else
        @max_connect_tries = 1
      end
      @reconnect_timeout = 1
      @next_reconnect_time = Time.utc(1980, 1, 1)
    end

    def clear_connection
      @mutex.synchronize do
        @connection.synchronize do
          @random_dev = File.open("/dev/urandom") if @random_dev.closed?
          @connection.unref
          @connection = Connection.new(nil)
        end
      end
    end

    def close
      @mutex.synchronize do
        @connection.synchronize do
          @random_dev.close
          @connection.unref
          @connection = nil
        end
      end
    end

    def new_transaction(group_name, category = :requests, union_station_key = "-")
      if !@server_address
        return Transaction.new
      elsif !group_name || group_name.empty?
        raise ArgumentError, "Group name may not be empty"
      end

      txn_id = (Time.now.to_i / 60).to_s(36)
      txn_id << "-#{random_token(11)}"

      Lock.new(@mutex).synchronize do |lock|
        if Time.now < @next_reconnect_time
          return Transaction.new
        end

        Lock.new(@connection.mutex).synchronize do |connection_lock|
          if !@connection.connected?
            begin
              connect
              connection_lock.reset(@connection.mutex)
            rescue SystemCallError, IOError
              @connection.disconnect
              UnionStationHooks::Log.warn(
                "Cannot connect to the UstRouter at #{@server_address}; " +
                "retrying in #{@reconnect_timeout} second(s).")
              @next_reconnect_time = Time.now + @reconnect_timeout
              return Transaction.new
            rescue Exception => e
              @connection.disconnect
              raise e
            end
          end

          begin
            @connection.channel.write("openTransaction",
              txn_id, group_name, "", category,
              Core.timestamp_string,
              union_station_key,
              true,
              true)
            result = @connection.channel.read
            if result[0] != "status"
              raise "Expected UstRouter to respond with 'status', but got #{result.inspect} instead"
            elsif result[1] == "ok"
              # Do nothing
            elsif result[1] == "error"
              if result[2]
                raise "Unable to close transaction: #{result[2]}"
              else
                raise "Unable to close transaction (no server message given)"
              end
            else
              raise "Expected UstRouter to respond with 'ok' or 'error', but got #{result.inspect} instead"
            end

            return Transaction.new(@connection, txn_id)
          rescue SystemCallError, IOError
            @connection.disconnect
            UnionStationHooks::Log.warn(
              "The UstRouter at #{@server_address}" <<
              " closed the connection; will reconnect in " <<
              "#{@reconnect_timeout} second(s).")
            @next_reconnect_time = Time.now + @reconnect_timeout
            return Transaction.new
          rescue Exception => e
            @connection.disconnect
            raise e
          end
        end
      end
    end

    def continue_transaction(txn_id, group_name, category = :requests, union_station_key = "-")
      if !@server_address
        return Transaction.new
      elsif !txn_id || txn_id.empty?
        raise ArgumentError, "Transaction ID may not be empty"
      end

      Lock.new(@mutex).synchronize do |lock|
        if Time.now < @next_reconnect_time
          return Transaction.new
        end

        Lock.new(@connection.mutex).synchronize do |connection_lock|
          if !@connection.connected?
            begin
              connect
              connection_lock.reset(@connection.mutex)
            rescue SystemCallError, IOError
              @connection.disconnect
              UnionStationHooks::Log.warn(
                "Cannot connect to the UstRouter at #{@server_address}; " +
                "retrying in #{@reconnect_timeout} second(s).")
              @next_reconnect_time = Time.now + @reconnect_timeout
              return Transaction.new
            rescue Exception => e
              @connection.disconnect
              raise e
            end
          end

          begin
            @connection.channel.write("openTransaction",
              txn_id, group_name, "", category,
              Core.timestamp_string,
              union_station_key,
              true)
            return Transaction.new(@connection, txn_id)
          rescue SystemCallError, IOError
            @connection.disconnect
            UnionStationHooks::Log.warn(
              "The UstRouter at #{@server_address}" <<
              " closed the connection; will reconnect in " <<
              "#{@reconnect_timeout} second(s).")
            @next_reconnect_time = Time.now + @reconnect_timeout
            return Transaction.new
          rescue Exception => e
            @connection.disconnect
            raise e
          end
        end
      end
    end

  private
    RANDOM_CHARS = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
      'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
      'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
      'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
      '0', '1', '2', '3', '4', '5', '6', '7', '8', '9']

    def connect
      socket  = connect_to_server(@server_address)
      channel = MessageChannel.new(socket)

      result = channel.read
      if result.nil?
        raise EOFError
      elsif result.size != 2 || result[0] != "version"
        raise IOError, "The UstRouter didn't sent a valid version identifier"
      elsif result[1] != "1"
        raise IOError, "Unsupported UstRouter protocol version #{result[1]}"
      end

      channel.write_scalar(@username)
      channel.write_scalar(@password)

      result = channel.read
      if result.nil?
        raise EOFError
      elsif result[0] != "status"
        raise "Invalid UstRouter authentication response: expected \"status\", got #{result[0].inspect}"
      elsif result[1] == "ok"
        # Do nothing
      elsif result[1] == "error"
        if result[2]
          raise SecurityError, "UstRouter authentication error: #{result[2]}"
        else
          raise SecurityError, "UstRouter authentication error (no server message given)"
        end
      else
        raise "Invalid UstRouter authentication response: #{result.inspect}"
      end

      channel.write("init", @node_name)
      args = channel.read
      if !args
        raise Errno::ECONNREFUSED, "Cannot connect to UstRouter"
      elsif result[0] != "status"
        raise "Invalid UstRouter client initialization response: expected \"status\", got #{result[0].inspect}"
      elsif result[1] == "ok"
        # Do nothing
      elsif result[1] == "error"
        if result[2]
          raise SecurityError, "UstRouter client initialization error: #{result[2]}"
        else
          raise SecurityError, "UstRouter client initialization error (no server message given)"
        end
      else
        raise "Invalid UstRouter client initialization response: #{result.inspect}"
      end

      @connection.unref
      @connection = Connection.new(socket)
    rescue Exception => e
      socket.close if socket && !socket.closed?
      raise e
    end

    def random_token(length)
      token = ""
      @random_dev.read(length).each_byte do |c|
        token << RANDOM_CHARS[c % RANDOM_CHARS.size]
      end
      return token
    end

    def self.timestamp_string(time = Time.now)
      timestamp = time.to_i * 1_000_000 + time.usec
      return timestamp.to_s(36)
    end
  end
end
