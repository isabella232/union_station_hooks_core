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

require File.expand_path(File.dirname(__FILE__) + '/spec_helper')
require 'stringio'
require 'tmpdir'
require 'fileutils'
UnionStationHooks.require_lib 'context'

module UnionStationHooks

describe Transaction do
  before :each do
    @username = 'logging'
    @password = '1234'
    @tmpdir   = Dir.mktmpdir
    @dump_dir = "#{@tmpdir}/dump"
    @socket_filename = "#{@dump_dir}/ust_router.socket"
    @socket_address  = "unix:#{@socket_filename}"
  end

  after :each do
    @transaction.close if @transaction
    @context.close if @context
    kill_agent
    FileUtils.rm_rf(@tmpdir) if @tmpdir
    Timecop.return
    UnionStationHooks::Log.warn_callback = nil
  end

  def create_context
    @context = Context.new(@socket_address, @username, @password, 'localhost')
  end

  def create_transaction
    @transaction = @context.new_transaction('foobar')
    expect(@transaction).not_to be_null
  end

  def start_agent
    @agent_pid = spawn_ust_router(@socket_filename, @password)
  end

  def kill_agent
    if @agent_pid
      Process.kill('KILL', @agent_pid)
      Process.waitpid(@agent_pid)
      File.unlink(@socket_filename)
      @agent_pid = nil
    end
  end

  def prepare_debug_shell
    Dir.chdir(@tmpdir)
    puts "You are at #{@tmpdir}."
    puts "You can find UstRouter dump files in 'dump'."
  end

  it 'complains if a connection is given without transaction ID' do
    connection = double('Connection')
    expect { Transaction.new(connection, nil) }.to raise_error(ArgumentError)
  end

  it 'enters the null mode upon closing' do
    start_agent
    create_context
    create_transaction
    @transaction.close
    expect(@transaction).to be_null
  end

  describe '#message' do
    it 'logs the given message' do
      start_agent
      create_context
      create_transaction
      @transaction.message('hello')
      @transaction.close(true)
      eventually do
        File.exist?(dump_file_path) &&
          read_dump_file.include?('hello')
      end
    end

    it "enters null mode upon encountering an I/O error" do
      start_agent
      create_context
      create_transaction

      expect(@transaction).to receive(:io_operation).
        at_least(:once).and_call_original
      expect(@context.connection).to receive(:disconnect).
        and_call_original
      silence_warnings
      kill_agent
      @transaction.message('hello')
      expect(@transaction).to be_null

      should_never_happen do
        File.exist?(dump_file_path) &&
          read_dump_file.include?('hello')
      end
    end
  end

  describe '#log_activity_begin' do
    def create_working_context_and_transaction
      create_context
      start_agent
      create_transaction
    end

    it 'logs a BEGIN message' do
      create_working_context_and_transaction
      expect(@transaction).to receive(:message).with(
        /^BEGIN: hello \(.+?\) $/).
        and_call_original
      expect(@transaction).to receive(:io_operation).
        at_least(:once).and_call_original
      @transaction.log_activity_begin('hello')
    end

    it 'adds extra information as base64' do
      create_working_context_and_transaction
      expect(@transaction).to receive(:message).with(
        /^BEGIN: hello \(.+?\) YWJjZA==$/).
        and_call_original
      expect(@transaction).to receive(:io_operation).
        at_least(:once).and_call_original
      @transaction.log_activity_begin('hello', UnionStationHooks.now, 'abcd')
    end

    it 'accepts a TimePoint as time' do
      create_working_context_and_transaction
      expect(@transaction).to receive(:message).with(
        /^BEGIN: hello \([a-z0-9]+,[a-z0-9]+,[a-z0-9]+\) $/).
        and_call_original
      expect(@transaction).to receive(:io_operation).
        at_least(:once).and_call_original
      @transaction.log_activity_begin('hello', UnionStationHooks.now)
    end

    it 'accepts a Time as time, but outputs less detailed information' do
      create_working_context_and_transaction
      expect(@transaction).to receive(:message).with(
        /^BEGIN: hello \([a-z0-9]+\) $/).
        and_call_original
      expect(@transaction).to receive(:io_operation).
        at_least(:once).and_call_original
      @transaction.log_activity_begin('hello', Time.now)
    end

    it "enters null mode upon encountering an I/O error" do
      create_working_context_and_transaction

      expect(@transaction).to receive(:io_operation).
        at_least(:once).and_call_original
      expect(@context.connection).to receive(:disconnect).
        and_call_original
      kill_agent
      silence_warnings
      @transaction.log_activity_begin('hello')
      expect(@transaction).to be_null

      should_never_happen do
        File.exist?(dump_file_path) &&
          read_dump_file.include?('hello')
      end
    end
  end

  describe '#log_activity_end' do
    def create_working_context_and_transaction
      create_context
      start_agent
      create_transaction
    end

    context 'if has_error=false' do
      it 'logs an END message' do
        create_working_context_and_transaction
        expect(@transaction).to receive(:message).with(
          /^END: hello \(.+?\)$/).
          and_call_original
        expect(@transaction).to receive(:io_operation).
          at_least(:once).and_call_original
        @transaction.log_activity_end('hello')
      end

      it 'accepts a TimePoint as time' do
        create_working_context_and_transaction
        expect(@transaction).to receive(:message).with(
          /^END: hello \([a-z0-9]+,[a-z0-9]+,[a-z0-9]+\)$/).
          and_call_original
        expect(@transaction).to receive(:io_operation).
          at_least(:once).and_call_original
        @transaction.log_activity_end('hello', UnionStationHooks.now)
      end

      it 'accepts a Time as time, but outputs less detailed information' do
        create_working_context_and_transaction
        expect(@transaction).to receive(:message).with(
          /^END: hello \([a-z0-9]+\)$/).
          and_call_original
        expect(@transaction).to receive(:io_operation).
          at_least(:once).and_call_original
        @transaction.log_activity_end('hello', Time.now)
      end
    end

    context 'if has_error=true' do
      it 'logs a FAIL message' do
        create_working_context_and_transaction
        expect(@transaction).to receive(:message).with(
          /^FAIL: hello \(.+?\)$/)
        expect(@transaction).to receive(:io_operation).
          at_least(:once).and_call_original
        @transaction.log_activity_end('hello', UnionStationHooks.now, true)
      end

      it 'accepts a TimePoint as time' do
        create_working_context_and_transaction
        expect(@transaction).to receive(:message).with(
          /^FAIL: hello \([a-z0-9]+,[a-z0-9]+,[a-z0-9]+\)$/).
          and_call_original
        expect(@transaction).to receive(:io_operation).
          at_least(:once).and_call_original
        @transaction.log_activity_end('hello', UnionStationHooks.now, true)
      end

      it 'accepts a Time as time, but outputs less detailed information' do
        create_working_context_and_transaction
        expect(@transaction).to receive(:message).with(
          /^FAIL: hello \([a-z0-9]+\)$/).
          and_call_original
        expect(@transaction).to receive(:io_operation).
          at_least(:once).and_call_original
        @transaction.log_activity_end('hello', Time.now, true)
      end
    end

    it "enters null mode upon encountering an I/O error" do
      create_working_context_and_transaction

      expect(@transaction).to receive(:io_operation).
        at_least(:once).and_call_original
      expect(@context.connection).to receive(:disconnect).
        and_call_original
      kill_agent
      silence_warnings
      @transaction.log_activity_end('hello')
      expect(@transaction).to be_null

      should_never_happen do
        File.exist?(dump_file_path) &&
          read_dump_file.include?('hello')
      end
    end
  end
end

end # module UnionStationHooks
