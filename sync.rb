#!/usr/bin/env ruby
# encoding: utf-8

require 'i18n'
require 'active_support/json'
require 'active_support/core_ext'
require 'eventmachine'
require 'em-http-request'
require 'happening'
require 'trollop'
require 'fileutils'
require 'digest/md5'
require 'json'
require 'yaml'
require 'pp'
require './helpers'

$git_repo = File.directory?('./.git')

if ENV['OS'] == 'Windows_NT'
  require 'win32console'
  require 'term/ansicolor'
  if defined? Term::ANSIColor
    class String
      include Term::ANSIColor
      def colorize(color, *args)
        send(color.is_a?(Hash) ? color[:color] : color, *args)
      end
    end
  end

  if !$git_repo && File.directory?('../bin') && File.directory?('../lib') && File.directory?('../src')
    $packaged = true
    Dir.chdir('../')
  end
else
  require 'colorize'
end

Signal.trap 'INT' do
  puts "Exiting..."
  $exiting = true
  EM.stop
  exit 0
end

if $packaged
  at_exit do
    next if $exiting
    puts "Press any key to exit"
    STDIN.getc
  end
end

PT_SYNC_VERSION = 0.3

DEFAULT_CONFIG = {
    'hash_server' => 'http://67.164.96.34:81/hashes.txt',
    'max_files_removed_without_warning' => 50,
    'download_type' => 's3',
    's3' => {
        'host' => 's3-website-us-east-1.amazonaws.com',
        'id_key' => 'id key goes here',
        'secret_key' => 'secret key goes here',
        'bucket' => 'ns2build'
    },
    'local_directory' => 'E:\\Natural Selection 2',
    'max_concurrency' => 48,
    'max_speed' => -1
}

USER_AGENT = 'PTSync-Ruby'

$config = DEFAULT_CONFIG
if config = File.exists?('config.yml') && YAML.load_file('config.yml')
  $config.rmerge!(config)
else
  open('config.yml', 'w') do |file|
    YAML.dump(DEFAULT_CONFIG, file)
  end
end

$argv = ARGV.dup

$opts = Trollop::options do
  opt 'verbose', 'Print extended information'
  opt 'watch', 'Check for updates periodically'
  opt 'create-dir', 'Creates the local NS2 directory'
  opt 'no-delete', 'Ignore additional/removed files'
  opt 'delete', 'Delete additional files without asking'
  opt 'exclude-excludes', 'No not sync the .excludes directory'
  opt 'dir', 'Local NS2 Directory', :type => :string
  opt 'host', 'S3 host address', :type => :string
  opt 'id-key', 'S3 ID key', :type => :string
  opt 'secret-key', 'S3 secret key', :type => :string
  opt 'bucket', 'S3 bucket to sync with', :type => :string, :default => $config.s3.bucket
  opt 'concurrency', 'Max concurrent connections', :default => $config.max_concurrency
  opt 'max-speed', 'Rough download speed limit in KB/s', :default => -1
end

$verbose = $opts['verbose']
$config.local_directory = "#{$opts['dir']}" if $opts['dir']
$config.s3.bucket = "#{$opts['bucket']}" if $opts['bucket']
$config.max_concurrency = $opts['concurrency'] if $opts['concurrency']
$config.max_speed = $opts['max-speed'] if $opts['max-speed']
$config.max_speed *= 1024.0 if $config.max_speed? && $config.max_speed > 0

if !$config.s3.id_key? || $config.s3.id_key == '' || $config.s3.id_key == 'id key goes here'
  log :red, "S3 ID key is configuration missing! You need to either add id_key to the s3 section in the config.yml file or use the --id-key command line option."
  exit 1
end

if !$config.s3.secret_key? || $config.s3.secret_key == '' || $config.s3.secret_key == 'secret key goes here'
  log :red, "S3 secret key configuration is missing! You need to either add secret_key to the s3 section in the config.yml file or use the --secret-key command line option."
  exit 1
end

if !$config.s3.bucket? || $config.s3.bucket == ''
  log :red, "S3 bucket configuration is missing! You need to either add bucket to the s3 section in the config.yml file or use the --bucket command line option."
  exit 1
end

if !$config.local_directory? || $config.local_directory == '' || $config.local_directory == 'your local ns2 directory'
  log :red, "Local NS2 directory configuration is missing! You need to either add bucket to the s3 section in the config.yml file or use the --bucket command line option."
  exit 1
end

$config.local_directory.slice!(-1) if $config.local_directory =~ /[\/\\]$/
$config.local_directory.gsub!("\\", "/")

unless File.directory? $config.local_directory
  if $opts['create-dir']
    log :yellow, "Creating directory: #{$config.local_directory}"
    FileUtils.mkpath($config.local_directory)
  else
    log :red, "The configured local NS2 directory does not exist! Check that your configuration is correct or create the directory before syncing to it."
    exit 1
  end
end

$config.s3_item = {
    protocol: 'http',
    aws_access_key_id: $opts['id-key'] || $config.s3.id_key,
    aws_secret_access_key: $opts['secret-key'] || $config.s3.secret_key
}

$config.s3_item[:server] = $opts['host'] if $opts['host']

def fetch_hashes
  log :yellow, "Downloading new file hashes..."

  http_request :get, $config.hash_server do |http, file_hashes|
    log :green, "Hashes have been updated"
    @hashes_last_modified = Time.parse(http.response_header['LAST_MODIFIED'])
    @hashes_generated_at = file_hashes.delete('__DateGeneratedUTC')
    file_hashes.delete('__Server')
    @file_hashes = file_hashes
    data = { date_generated: @hashes_generated_at, last_modified: @hashes_last_modified, hashes: @file_hashes }
    open('cache.dat', 'w') {|f| f << JSON.fast_generate(data) }
    yield if block_given?
  end
end

def update_hashes_if_needed
  unless @hashes_last_modified
    if File.exists? 'cache.dat'
      data = JSON.parse(File.read('cache.dat'))
      @file_hashes = data.hashes
      @hashes_last_modified = Time.parse(data.last_modified)
      @hashes_generated_at = data.date_generated
    end
  end

  unless @hashes_last_modified
    return fetch_hashes { yield true if block_given? }
  end

  log :yellow, "Checking for NS2 updates..."
  http_request :head, $config.hash_server do |http, _| #TODO: change to a GET request with cache conditional headers so that operation is atomic
    last_modified = Time.parse(http.response_header['LAST_MODIFIED'])
    if last_modified > @hashes_last_modified
      fetch_hashes { yield true if block_given? }
    else
      log :yellow, "Local cache is already up to date"
      yield false if block_given?
    end
  end
end

def download_files(sub_paths)
  total_files_to_download = sub_paths.size
  log :yellow, "Downloading #{total_files_to_download} files..."
  @downloading_files = sub_paths

  @downloading_file_count = 0
  @downloaded_file_count = 0

  if $config.max_speed?
    @max_decisecond_speed = $config.max_speed / 10.0
    @current_decisecond = (Time.now.to_f * 10).round
    @decisecond_started_at = Time.now.to_f
    @decisecond_speed = 0
  end

  @current_second = Time.now.to_i
  @current_speed = 0
  @last_speeds = []

  download_complete = -> do
    log :green, "Sync complete (#{sub_paths.size} files downloaded)"
    yield if block_given?
  end

  download_next_file = -> do
    if @downloading_files.size == 0
      download_complete.() if @downloading_file_count == 0
      next
    end

    sub_path = @downloading_files.shift
    file_path = File.join($config.local_directory, sub_path)

    directory_path = File.dirname(file_path)
    unless File.directory? directory_path
      log :yellow, "Creating directory: #{directory_path}"
      FileUtils.mkpath(directory_path)
    end

    @downloading_file_count += 1

    file = open(file_path, 'wb')

    item = Happening::S3::Item.new($config.s3.bucket, sub_path, $config.s3_item)

    failed = proc do |http|
      error_code = http.response_header['X_AMZ_ERROR_CODE'] || http.response_header.status
      error_message = http.response_header['X_AMZ_ERROR_MESSAGE'] || "status: #{http.response_header.status}"
      log :red, "Download failed: #{sub_path.inspect} (#{error_message})"
      @downloading_file_count -= 1
      file.close
      if error_code != 'IncorrectEndpoint' && error_code != 404
        @downloading_files << sub_path
      end
      download_next_file.()
    end

    item.head(on_error: failed) do |http|
      file_size = byte_size = http.response_header['CONTENT_LENGTH'].to_i
      unit = 'bytes'
      if file_size >= 1024
        file_size /= 1024.0
        unit = 'KB'
      end
      if file_size >= 1024
        file_size /= 1024.0
        unit = 'MB'
      end

      succeeded = proc do
        log :magenta, "Download complete: #{sub_path}" if $verbose
        @downloading_file_count -= 1
        @downloaded_file_count += 1
        file.close #TODO: correct the mtime?

        if @downloading_file_count < 6 || byte_size < 20.megabytes
          download_next_file.()
        end
      end

      log :magenta, "Downloading #{sub_path} (#{'%.2f' % file_size} #{unit})"

      current_second = @current_second
      bytes_written = 0

      item.get(on_success: succeeded, on_error: failed).stream do |chunk|
        file << chunk

        chunk_size = chunk.bytesize
        bytes_written += chunk_size

        now = Time.now.to_i

        unless current_second == now
          log :magenta, "[#{bytes_written}/#{byte_size}] Downloading #{sub_path} (#{'%.2f' % (bytes_written / byte_size.to_f * 100)}%)" if $verbose
          current_second = now
        end

        if @max_decisecond_speed
          current_decisecond = (Time.now.to_f * 10).round

          if @current_decisecond == current_decisecond
            @decisecond_speed += chunk_size
          else
            @current_decisecond = current_decisecond
            @decisecond_started_at = Time.now.to_f
            @decisecond_speed = chunk_size
          end

          if @decisecond_speed >= @max_decisecond_speed
            decisecond_ends_at = @decisecond_started_at + 0.1
            sleep_time = decisecond_ends_at - Time.now.to_f

            excess_speed = @decisecond_speed - @max_decisecond_speed
            sleep_time += excess_speed / @max_decisecond_speed * 0.1

            sleep(sleep_time) if sleep_time > 0.01
          end
        end

        if @current_second == now
          @current_speed += chunk_size
        else
          @last_speeds << @current_speed
          @last_speeds.shift if @last_speeds.size > 3
          last_speed = 0
          @last_speeds.each {|speed| last_speed += speed }
          last_speed /= @last_speeds.size.to_f
          @current_speed = 0
          @current_second = now
          percentage = @downloaded_file_count / total_files_to_download.to_f * 100
          log :cyan, "[#{'%.2f' % percentage}%] Downloading #@downloading_file_count files - #{'%.2f' % (last_speed / 1024.0)} KB/s"
        end
      end

      if @downloading_file_count < $config.max_concurrency
        if @downloading_file_count < 6 || byte_size < 20.megabytes
          download_next_file.()
        end
      end
    end
  end

  download_next_file.()
end

def delete_files(paths)
  log :yellow, "Deleting #{paths.size} files..."
  paths.each do |path|
    log :yellow, "Deleting file: #{path}" if $verbose
    File.delete(path)
  end
end

def check_for_redundant_files
  log :yellow, "Checking for redundant files..."
  files_to_delete = Dir[File.join($config.local_directory, '**/*')].reject do |path|
    next true if $opts['exclude-excludes'] && path[$config.local_directory.size+1..-1] == '.excludes'
    File.directory?(path) || @file_hashes.include?(path[$config.local_directory.size..-1])
  end

  if !$opts['delete'] && files_to_delete.size > $config.max_files_removed_without_warning
    log :yellow, "First file that needs to be deleted: #{files_to_delete.first}" if $verbose
    loop do
      print "Are you sure you want to delete #{files_to_delete.size} files? [Y/N] "
      case gets
        when /^ye?s?$/i
          delete_files(files_to_delete)
          break
        when /^no?$/i
          break
      end
    end
  elsif files_to_delete.size > 0
    delete_files(files_to_delete)
  end
end

def check_files
  check_for_redundant_files unless $opts['no-delete']

  log :yellow, "Hashing and comparing #{@file_hashes.size} files..."

  started_at = Time.now
  last_update_at = started_at

  files_to_download = []
  @file_hashes.each.with_index do |(sub_path, info), i|
    next if $opts['exclude-excludes'] && sub_path[/^\/?([^\/]+)/, 1] == '.excludes'
    file_path = File.join($config.local_directory, sub_path)
    if !File.exists?(file_path) || info['hash'] != Digest::MD5.file(file_path).hexdigest
      files_to_download << sub_path[1..-1]
    end
    if Time.now - last_update_at >= 1
      log :magenta, "Checked #{i+1}/#{@file_hashes.size} files (#{'%.2f' % ((i+1) / @file_hashes.size.to_f * 100)}%)"
      last_update_at = Time.now
    end
    #if files_to_download.size > 0
    #  break #debug
    #end
  end

  log :yellow, "Hashing and comparing files took #{'%.2f' % (Time.now - started_at)} seconds."

  if files_to_download.size < 1
    log :green, "All #{@file_hashes.size} files are up to date."
    yield if block_given?
  else
    download_files(files_to_download) do
      yield if block_given?
    end
  end
end

def update_if_needed(force=false)
  update_hashes_if_needed do |updated_hashes|
    if force || updated_hashes
      check_files do
        if $opts['watch']
          log :yellow, "Checking for updates again in 5 minutes"
          EM.add_timer(5.minutes) { update_if_needed }
        else
          EM.stop
          exit 0
        end
      end
    else
      yield if block_given?
    end
  end
end

def sync_client_update_available
  log :yellow, "Checking if PTSync-rb is up to date..."
  http_request :get, 'http://germ.intoxicated.co.za/ns2/ptsync/version.json', allow_failure: true do |http, response|
    if response
      yield response['version'] > PT_SYNC_VERSION, response['files']
    else
      log :red, "Warning: Auto update version check failed! (code: #{http.response_header.status})"
      yield false
    end
  end
end

def update_sync_client_if_needed
  sync_client_update_available do |update_available, files|
    if update_available
      log :green, "There is a new version of PTSync-rb available!"
      downloaded_files = 0
      files.each do |file_name|
        log :yellow, "Downloading PTSync-rb update file: #{file_name}" if $verbose
        http_request :get, 'http://germ.intoxicated.co.za/ns2/ptsync/' + file_name, parser: 'raw' do |http, contents|
          open("#{$packaged ? './src' : '.'}/#{file_name}", 'wb') {|f| f << contents }
          downloaded_files += 1
          log :cyan, "[#{downloaded_files}/#{files.size}] Sync client files updated"
          if downloaded_files == files.size
            log :green, "PTSync-rb updated successfully! Relaunching new version..."
            Dir.chdir('./src') if $packaged
            exec_args = [$0, *$argv]
            exec_args.insert 0, 'ruby' if $0.end_with?('.rb')
            exec *exec_args
          end
        end
      end
    else
      yield if block_given?
    end
  end
end

exit 0 if ENV['DEVMODE101']

EM.run do
  if $git_repo
    update_if_needed(true)
  else
    update_sync_client_if_needed do
      update_if_needed(true)
    end
  end
end