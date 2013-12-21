#!/usr/bin/env ruby
# encoding: utf-8

require 'i18n'
require 'active_support/json'
require 'active_support/core_ext'
require 'eventmachine'
require 'em-http-request'
require 'fileutils'
require 'trollop'
require 'json'
require 'pp'
require './helpers'

PT_SYNC_BRANCH = :beta
PT_SYNC_VERSION = 2.0

UPDATE_URL_BASE = "http://germ.intoxicated.co.za/ns2/ptsync#{'/beta' if PT_SYNC_BRANCH == :beta}"

$stdout.sync = $stderr.sync = true

$root_directory = Dir.getwd

$git_repo = File.directory?('./.git')
if !$git_repo && File.directory?('../bin') && File.directory?('../lib') && File.directory?('../src')
  $packaged = true
end

Signal.trap 'INT' do
  puts "Exiting..."
  $exiting = true
  EM.stop if EM.reactor_running?
  exit 0
end

if $packaged
  at_exit do
    next if $exiting
    STDOUT.flush
    STDERR.flush
    sleep 0.5
    puts "Press enter key to exit"
    STDIN.gets
  end
end

if ENV['OS'] == 'Windows_NT'
  require 'win32console'
  require 'term/ansicolor'
  if defined? Term::ANSIColor
    class String
      include Term::ANSIColor
      def colorize(color, *args)
        return self if $ipc_port
        color = color.is_a?(Hash) ? color[:color] : color
        color == :default ? self : send(color, *args)
      end
    end
  end

  begin
    require 'win32ole'
  rescue LoadError
    if $packaged
      log "Downloading missing dependency..."
      EM.run do
        http_request :get, 'http://germ.intoxicated.co.za/ns2/ptsync/win32ole.so', parser: 'raw' do |_, contents|
          open("#{$root_directory[0..-5]}/lib/ruby/1.9.1/i386-mingw32/win32ole.so", 'wb') {|f| f << contents }
          log "Dependency download complete!"
          EM.stop
        end
      end
      require 'win32ole'
    else
      log :red, "Fatal error: Update your sync client version!"
      exit 1
    end
  end

  $wmi = WIN32OLE.connect("winmgmts://")

  if (ipc_port_arg = ARGV.detect {|arg| arg.start_with? '--ipcport' })
    ARGV.delete(ipc_port_arg)
    $ipc_port = ipc_port_arg[9..-1].to_i
    if $ipc_port > 0
      require './ipc_server'
    else
      log :red, "Warning: Invalid --ipcport command line argument!"
    end
  end

  $windows = true
else
  require 'colorize'
end

$argv = ARGV.dup

$opts = Trollop::options do
  opt :verbose, 'Print extended information', :short => 'v'
  opt :debug, 'Print detailed debug information', :short => 'g'
  opt :once, 'Exit after syncing has completed', :short => 'o'
  opt :createdir, 'Create the local NS2 directory', :short => 'c'
  opt :deleteall, 'Delete files which were not part of the last build', :short => 'l'
  opt :nodelete, 'Ignore additional/removed files', :short => 'n'
  opt :delete, 'Delete additional files without asking', :short => 'd'
  opt :noexcludes, 'Do not sync the .excludes directory', :short => 'e'
  opt :ignorerunning, 'Ignore any running NS2 applications', :short => 'r'
  opt :verify, 'Verify the integrity of all local files', :short => 'y'
  opt :dir, 'Local NS2 directory', :type => :string, :short => 'p'
  opt :beforeupdate, 'Command to run before an update starts', :type => :string, :short => 't'
  opt :afterupdate, 'Command to run after an update', :type => :string, :short => 'a'
  opt :host, 'S3 host address', :type => :string, :short => 'h'
  opt :idkey, 'S3 ID key', :type => :string, :short => 'i'
  opt :secretkey, 'S3 secret key', :type => :string, :short => 's'
  opt :bucket, 'S3 bucket to sync with', :type => :string, :default => 'ns2build', :short => 'b'
  opt :concurrency, 'Max concurrent connections', :default => 48, :short => 'u'
  opt :maxspeed, 'Rough download speed limit in KB/s', :default => -1, :short => 'm'
end

def start_application
  return if $application_started
  $application_started = true
  update_sync_client_if_needed do
    on :initializing
    log "Starting ptsync-rb v#{PT_SYNC_VERSION}"
    require './sync'
  end
end

EM.run do
  if $ipc_port
    log "[IPC] Listening on port #$ipc_port for client connections"
    EM.start_server '127.0.0.1', $ipc_port, IpcServer
  else
    start_application
  end
end