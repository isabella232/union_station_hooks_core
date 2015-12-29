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
require 'tmpdir'
require 'fileutils'
require 'base64'
require 'digest/md5'
UnionStationHooks.require_lib 'log'

module UnionStationHooks

shared_examples_for 'API methods on the UnionStationHooks module' do
  before :each do |example|
    @example_full_description = example.full_description
    @username = 'logging'
    @password = '1234'
    @tmpdir   = Dir.mktmpdir
    @dump_dir = "#{@tmpdir}/dump"
    @socket_filename = "#{@dump_dir}/ust_router.socket"
    @socket_address  = "unix:#{@socket_filename}"
    FileUtils.mkdir(@dump_dir)
  end

  after :each do
    kill_agent
    FileUtils.rm_rf(@tmpdir) if @tmpdir
    UnionStationHooks::Log.warn_callback = nil
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

  describe '#log_exception' do
    it 'logs exception information' do
      code = %Q{
        UnionStationHooks.initialize!
        begin
          raise EOFError, 'file has ended'
        rescue => e
          UnionStationHooks.log_exception(e)
        end
      }
      start_agent
      execute(code)

      wait_for_dump_file_existance('exceptions')
      eventually do
        read_dump_file('exceptions').include?('Message: ')
      end
      read_dump_file('exceptions') =~ /Message: (.+)/
      expect(Base64.decode64($1)).to eq('file has ended')

      eventually do
        read_dump_file('exceptions').
          include?("Class: EOFError\n")
      end
      eventually do
        read_dump_file('exceptions') =~ /Backtrace: .+/
      end
    end
  end
end

RUBY_VERSIONS_TO_TEST.each do |spec|
  describe "API methods on the UnionStationHooks module on #{spec['name']}" do
    let(:ruby_name) { spec['name'] }
    let(:ruby_command) { spec['command'] }

    include_examples 'API methods on the UnionStationHooks module'
  end
end

end
