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

USH_GEMFILE = ENV['BUNDLE_GEMFILE']
if !USH_GEMFILE
  abort 'The test suite must be run in Bundler.'
end

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.command_name('RSpec')
  SimpleCov.start('test')
end

ROOT = File.expand_path(File.dirname(File.dirname(__FILE__)))
require("#{ROOT}/lib/union_station_hooks_core")
UnionStationHooks.require_lib 'spec_helper'
UnionStationHooks.require_lib 'utils'
UnionStationHooks::SpecHelper.initialize!

require 'yaml'
require 'timecop'

ruby_versions_file_path = "#{ROOT}/ruby_versions.yml"
if !File.exist?(ruby_versions_file_path)
  abort 'Please create a file "ruby_versions.yml". ' \
    'See "ruby_versions.yml.example" for more information.'
end

RUBY_VERSIONS_TO_TEST = YAML.load_file(ruby_versions_file_path)

module SpecHelper
  # Generic helper method for spawning a process in the background.
  #
  # @return [Integer] The process's PID.
  def spawn_process(*args)
    args.map! { |arg| arg.to_s }
    if Process.respond_to?(:spawn)
      Process.spawn(*args)
    else
      fork do
        exec(*args)
      end
    end
  end

  # Spawns an instance of the UstRouter in the background. The UstRouter will
  # be started in development mode, which means that it will dump all data sent
  # to it to files on the filesystem, instead of sending that data to the Union
  # Station service.
  #
  # This method requires that the `@dump_dir` variable is set. That directory
  # will be used as a scratch area. In addition, the UstRouter dump files will
  # be stored there.
  #
  # @param [String] socket_filename  The filename of the Unix domain socket
  #   that the UstRouter should listen on.
  # @param [String] password  The password that the UstRouter should use for.
  #   authenticating clients. Since we're testing, a simple password like `1234`
  #   will do.
  # @return [Integer] The UstRouter's PID.
  def spawn_ust_router(socket_filename, password)
    raise '@dump_dir variable required' if !@dump_dir
    password_filename = "#{@dump_dir}/password"
    write_file(password_filename, password)
    agent = PhusionPassenger.find_support_binary(PhusionPassenger::AGENT_EXE)
    pid = spawn_process(agent,
      'ust-router',
      '--passenger-root', PhusionPassenger.install_spec,
      '--log-level', debug? ? '6' : '2',
      '--dev-mode',
      '--dump-dir', @dump_dir,
      '--listen', "unix:#{socket_filename}",
      '--password-file', password_filename)
    eventually do
      File.exist?(socket_filename)
    end
    pid
  rescue Exception => e
    if pid
      Process.kill('KILL', pid)
      Process.waitpid(pid)
    end
    raise e
  end

  def base64(data)
    UnionStationHooks::Utils.base64(data)
  end
end

RSpec.configure do |config|
  config.include(UnionStationHooks::SpecHelper)
  config.include(SpecHelper)
end
