# encoding: utf-8

if __FILE__ == $0
  if ENV['OS'] == 'Windows_NT'
    if File.directory?('../bin') && File.directory?('../lib') && File.directory?('../src')
      begin
        exec File.join(Dir.getwd, '..', 'bin', 'ruby'), 'ptsync.rb', *ARGV
      rescue
        puts "Bad news, looks like you are using a really outdated ptsync-rb windows package. Please download the latest package from: https://github.com/bawNg/ptsync-rb/releases"
        exit 1
      end
    end
  end
  puts "This file is not meant to be run directly. You need to run ptsync.rb instead."
  exit 1
end

require 'happening'
require 'digest/md5'
require 'yaml'
require './config'

if $windows
  require 'win32ole'
  $wmi = WIN32OLE.connect("winmgmts://")
end

Dir.chdir('../') if $packaged

Encoding.default_external = 'utf-8'

initialize_config

$verbose = $opts[:verbose]
$config.local_directory = "#{$opts[:dir]}" if $opts[:dir]
$config.s3.bucket = "#{$opts[:bucket]}" if $opts[:bucket]
$config.max_concurrency = $opts[:concurrency] if $opts[:concurrency]
$config.max_speed = $opts[:maxspeed] if $opts[:maxspeed]
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
  if $opts[:createdir]
    log :yellow, "Creating directory: #{$config.local_directory}"
    FileUtils.mkpath($config.local_directory)
  else
    log :red, "The configured local NS2 directory does not exist! Check that your configuration is correct or create the directory before syncing to it."
    exit 1
  end
end

$config.s3_item = {
    protocol: 'http',
    aws_access_key_id: $opts[:idkey] || $config.s3.id_key,
    aws_secret_access_key: $opts[:secretkey] || $config.s3.secret_key
}

$config.s3_item[:server] = $opts[:host] if $opts[:host]

@local_file_info = {}

def running_ns2_processes
  if $windows
    escaped_path = $config.local_directory.gsub('/', '\\').gsub('\\', '\\\\\\\\')
    $wmi.ExecQuery("SELECT * FROM win32_process WHERE ExecutablePath LIKE '#{escaped_path}%'").each.map(&:Name)
  else
    [] #TODO: linux support
  end
end

def load_cached_data(data)
  cache = Marshal.load(data)
  @file_hashes = cache.hashes if cache.hashes?
  @hashes_last_modified = cache.last_modified if cache.last_modified?
  @hashes_generated_at = cache.date_generated if cache.date_generated?
  @hashed_local_directory = cache.local_directory if cache.local_directory?
  if @hashed_local_directory && @hashed_local_directory == $config.local_directory
    @local_file_info = cache.local_files if cache.local_files?
  end
  log :yellow, "Loaded #{@file_hashes.size} remote hashes and #{@local_file_info.size} local hashes from cache" if $verbose
rescue Exception => ex
  log :red, "An error occurred while loading your local cache: #{ex.message} (#{ex.class.name})"
  log :yellow, "Local cache will need to be rebuilt"
end

if File.exists? 'cache.dat'
  data = File.binread('cache.dat')
  if data[0] == '{' && data[-1] == '}'
    log :cyan, '=' * 62
    log :cyan, ' Your local cache format is outdated and needs to be rebuilt.'
    log :cyan, ' Hashing could take a while, this only needs to be done once.'
    log :cyan, '=' * 62
    File.delete('cache.dat')
  else
    load_cached_data(data)
  end
end

def save_cached_data
  log :yellow, "Saving cached data to disk..." if $verbose
  cache = { date_generated: @hashes_generated_at, last_modified: @hashes_last_modified, hashes: @file_hashes }
  if @hashed_local_directory
    cache[:local_directory] = @hashed_local_directory
    cache[:local_files] = @local_file_info
  end
  open('cache.dat', 'wb') {|f| f << Marshal.dump(cache) }
end

def fetch_hashes
  log :yellow, "Downloading new file hashes..."

  http_request :get, $config.hash_server do |http, file_hashes|
    log :green, "Hashes have been updated"
    @hashes_last_modified = Time.parse(http.response_header['LAST_MODIFIED'])
    @hashes_generated_at = file_hashes.delete('__DateGeneratedUTC')
    file_hashes.delete('__Server')
    @file_hashes = file_hashes
    save_cached_data
    yield if block_given?
  end
end

def update_hashes_if_needed
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

def after_update
  log :yellow, "Executing afterupdate command: #{$opts[:afterupdate]}"
  system($opts[:afterupdate])
rescue Exception => ex
  log :red, "Error while executing afterupdate command: #{ex.message} (#{ex.class.name})"
end

def download_files(sub_paths)
  @total_files_downloaded = total_files_to_download = sub_paths.size
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
    log :green, "Sync complete (#@total_files_downloaded files downloaded)"
    after_update if $opts[:afterupdate] unless @total_files_downloaded == 0
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

    log :yellow, "Starting download: #{sub_path}" if $verbose

    unless (file = open(file_path, 'wb') rescue nil)
      log :red, "Unable to write file: #{sub_path.inspect}"
      @total_files_downloaded -= 1
      next download_next_file.()
    end

    @downloading_file_count += 1

    item = Happening::S3::Item.new($config.s3.bucket, sub_path, $config.s3_item)

    failed = proc do |http|
      http_status = http.response_header.status
      error_code = http.response_header['X_AMZ_ERROR_CODE'] || 'None'
      error_message = http.response_header['X_AMZ_ERROR_MESSAGE'] || 'Unknown error'
      log :red, "Download failed: #{sub_path.inspect} (code: #{error_code}, message: #{error_message}, status: #{http_status})"
      @downloading_file_count -= 1
      file.close
      if error_code != 'IncorrectEndpoint' && error_code != 400 && error_code != 404
        @downloading_files << sub_path
      else
        @total_files_downloaded -= 1
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
    @local_file_info.delete(path[$config.local_directory.size..-1])
  end
  save_cached_data
end

def check_for_redundant_files
  log :yellow, "Checking for redundant files..."
  files_to_delete = Dir[File.join($config.local_directory, '**/*')].reject do |path|
    next true if $opts[:noexcludes] && path[$config.local_directory.size+1..-1] == '.excludes'
    File.directory?(path) || @file_hashes.include?(path[$config.local_directory.size..-1])
  end

  if !$opts[:delete] && files_to_delete.size > $config.max_files_removed_without_warning
    log :yellow, "First file that needs to be deleted: #{files_to_delete.first}" if $verbose
    loop do
      print "Are you sure you want to delete #{files_to_delete.size} files? [Y/N] "
      case STDIN.gets
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

def file_hash(sub_path)
  file_path = File.join($config.local_directory, sub_path)
  file_size = File.size(file_path)
  file_mtime = File.mtime(file_path).to_i

  unless $opts[:verify]
    if cached_file = @local_file_info[sub_path]
      if file_size == cached_file.fsize && file_mtime == cached_file.mtime
        return cached_file[:hash]
      end
    end
  end

  hash = Digest::MD5.file(file_path).hexdigest
  @local_file_info[sub_path] = { fsize: file_size, mtime: file_mtime, hash: hash }
  return hash
end

def check_files
  check_for_redundant_files unless $opts[:nodelete]

  log :yellow, "Hashing and comparing #{@file_hashes.size} files..."

  started_at = Time.now
  last_update_at = started_at

  files_to_download = []
  @file_hashes.each.with_index do |(sub_path, info), i|
    next if $opts[:noexcludes] && sub_path[/^\/?([^\/]+)/, 1] == '.excludes'
    file_path = File.join($config.local_directory, sub_path)
    if File.exists?(file_path)
      hash = file_hash(sub_path)
      if info['hash'] != hash
        files_to_download << sub_path[1..-1]
      end
    else
      files_to_download << sub_path[1..-1]
    end
    if Time.now - last_update_at >= 1
      log :magenta, "Checked #{i+1}/#{@file_hashes.size} files (#{'%.2f' % ((i+1) / @file_hashes.size.to_f * 100)}%)"
      last_update_at = Time.now
    end
  end

  @hashed_local_directory = $config.local_directory

  save_cached_data

  log :yellow, "Hashing and comparing files took #{'%.2f' % (Time.now - started_at)} seconds."

  if files_to_download.size < 1
    log :green, "All #{@file_hashes.size} files are up to date."
    yield if block_given?
  else
    download_files(files_to_download) do
      check_files do
        yield if block_given?
      end
    end
  end
end

def schedule_next_update
  if $last_client_update_check_at
    if Time.now - $last_client_update_check_at >= 30.minutes
      update_sync_client_if_needed do
        schedule_next_update
      end
      return
    end
  end
  log :yellow, "Will check for updates again after 3 minutes" if $verbose
  EM.add_timer(3.minutes) do
    update_if_needed do
      schedule_next_update
    end
  end
end

def update_if_needed(force=false, &block)
  unless $opts[:ignorerunning]
    if (running_process_names = running_ns2_processes).present?
      unless running_process_names == @running_process_names
        log :red, "Updating will only start once the following application(s) have been closed: #{running_process_names.to_sentence}"
        @running_process_names = running_process_names
      end
      return EM.add_timer(5) { update_if_needed(force, &block) }
    end
    @running_process_names = nil
  end

  update_hashes_if_needed do |updated_hashes|
    if force || updated_hashes
      check_files do
        yield if block_given?
      end
    else
      yield if block_given?
    end
  end
end

exit 0 if ENV['DEVMODE101']

EM.run do
  update_if_needed(true) do
    if $opts[:once]
      EM.stop
      exit 0
    else
      schedule_next_update
    end
  end
end