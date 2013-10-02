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

PT_SYNC_VERSION = 1.1

$git_repo = File.directory?('./.git')

if ENV['OS'] == 'Windows_NT'
  require 'win32console'
  require 'term/ansicolor'
  if defined? Term::ANSIColor
    class String
      include Term::ANSIColor
      def colorize(color, *args)
        color = color.is_a?(Hash) ? color[:color] : color
        color == :default ? self : send(color, *args)
      end
    end
  end
  $windows = true
else
  require 'colorize'
end

Signal.trap 'INT' do
  puts "Exiting..."
  $exiting = true
  EM.stop if EM.reactor_running?
  exit 0
end

$git_repo = File.directory?('./.git')

if !$git_repo && File.directory?('../bin') && File.directory?('../lib') && File.directory?('../src')
  $packaged = true
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

$root_directory = Dir.getwd

$argv = ARGV.dup

$opts = Trollop::options do
  opt :verbose, 'Print extended information', :short => 'v'
  opt :once, 'Exit after syncing has completed', :short => 'o'
  opt :createdir, 'Create the local NS2 directory', :short => 'c'
  opt :nodelete, 'Ignore additional/removed files', :short => 'n'
  opt :delete, 'Delete additional files without asking', :short => 'd'
  opt :noexcludes, 'Do not sync the .excludes directory', :short => 'e'
  opt :ignorerunning, 'Ignore any running NS2 applications', :short => 'r'
  opt :verify, 'Verify the integrity of all local files', :short => 'y'
  opt :dir, 'Local NS2 directory', :type => :string, :short => 'p'
  opt :afterupdate, 'Command to run after each update', :type => :string, :short => 'a'
  opt :host, 'S3 host address', :type => :string, :short => 'h'
  opt :idkey, 'S3 ID key', :type => :string, :short => 'i'
  opt :secretkey, 'S3 secret key', :type => :string, :short => 's'
  opt :bucket, 'S3 bucket to sync with', :type => :string, :default => 'ns2build', :short => 'b'
  opt :concurrency, 'Max concurrent connections', :default => 48, :short => 'u'
  opt :maxspeed, 'Rough download speed limit in KB/s', :default => -1, :short => 'm'
end

unless $git_repo
  EM.run do
    update_sync_client_if_needed do
      EM.stop
    end
  end
end

log "Starting ptsync-rb v#{PT_SYNC_VERSION}"
require './sync'