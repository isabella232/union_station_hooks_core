# Developer quickstart

**Table of contents**

 * [Setting up the development environment](#setting-up-the-development-environment)
 * [Development workflow](#development-workflow)
 * [Testing](#testing)
   - [Running the test suite against a specific Passenger version](#running-the-test-suite-against-a-specific-passenger-version)
   - [Code coverage](#code-coverage)
   - [Writing tests](#writing-tests)

## Setting up the development environment

Before you can start developing `union_station_hooks_core`, you must setup a development environment.

### Step 1: install gem bundle

First, ensure that you have at least Bundler 1.10. Check your Bundler version with:

    bundle -v

If it's less than 1.10, install the latest version:

    gem install bundler --no-document

Go to the `union_station_hooks_core` directory, then install the gem bundle:

    cd /path-to/union_station_hooks_core
    bundle install

### Step 2: setup ruby_versions.yml

Parts of the test suite is to be run against multiple Ruby versions. Therefore, it expects a configuration file `ruby_versions.yml` which specifies which Ruby versions are available and how to execute them.

Create a `ruby_versions.yml` from its example template, then modify it as you see fit:

    cp ruby_versions.yml.example ruby_versions.yml
    editor ruby_versions.yml

### Step 3: install Passenger

During development, the `union_station_hooks_core` unit tests are to be run against a specific Passenger version.

If this copy of `union_station_hooks_core` is [vendored into Passenger](https://github.com/phusion/union_station_hooks_core/blob/master/hacking/Vendoring.md), then you can skip this step. The test suite will automatically use the containing Passenger installation.

Otherwise, you need to install Passenger unless you have already installed it. Here is how you can install Passenger:

 1. Clone the Passenger source code:

        git clone git://github.com/phusion/passenger.git

 2. Add this Passenger installation's `bin` directory to your `$PATH`:

        export PATH=/path-to-passenger/bin:$PATH

    You also need to add this to your bashrc so that the environment variable persists in new shell sessions.

 3. Install the Passenger Standalone runtime:

        passenger-config install-standalone-runtime

## Development workflow

The development workflow is as follows:

 1. Write code (`lib` directory).
 2. Write tests (`spec` directory).
 3. Run tests. Repeat from step 1 if necessary.
 4. Commit code, send a pull request.

## Testing

Once you have set up your development environment per the above instructions, run the test suite with:

    bundle exec rake spec

The unit test suite will automatically detect your Passenger installation by scanning `$PATH` for the `passenger-config` command.

### Running the test suite against a specific Passenger version

If you have multiple Passenger versions installed, and you want to run the test suite against a specific Passenger version (e.g. to test compatibility with that version), then you can do that by setting the `PASSENGER_CONFIG` environment variable to that Passenger installation's `passenger-config` command. For example:

    export PASSENGER_CONFIG=$HOME/passenger-5.0.18/bin/passenger-config
    bundle exec rake spec

### Running a specific test

If you want to run a specific test, then pass the test's name through the `E` environment variable. For example:

    bundle exec rake spec E='UnionStationHooks::Transaction#message logs the given message'

### Code coverage

You can run the test suite with code coverage reporting by setting the `COVERAGE=1` environment variable:

    export COVERAGE=1
    bundle exec rake spec

Afterwards, the coverage report will be available in `coverage/index.html`.

### Writing tests

Tests are written in [RSpec](http://rspec.info/). Most tests follow this pattern:

 1. Start the UstRouter in development mode. The development mode will cause the UstRouter to dump any received data to files on the filesystem, instead of sending them to the Union Station service.
 2. Perform some work, which we expect will send a bunch of data to the UstRouter.
 3. Assert that the UstRouter dump files will **eventually** contain the data that we expect. The "eventually" part is important, because the UstRouter is highly asynchronous and may not write to disk immediately.

The test suite contains a bunch of helper methods that aid you in writing tests that follow these pattern. See `spec/spec_helper.rb` and `lib/union_station_hooks_core/spec_helper.rb`.
