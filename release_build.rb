require 'i18n'
require 'active_support/json'
require 'active_support/core_ext'
require 'eventmachine'
require 'em-http-request'
require 'fileutils'
require 'trollop'
require 'happening'
require 'digest/md5'
require 'yaml'
require 'json'
require 'pp'
require './helpers'

class String
  def colorize(color)
    self
  end
end

module Happening
  module S3
    class Item
      def store(file_path, request_options={}, &blk)
         headers = construct_aws_headers('PUT', request_options.delete(:headers) || {})
         request_options[:on_success] = blk if blk
         request_options.update(:headers => headers, :file => file_path)
         Happening::S3::Request.new(:put, url, {:ssl => options[:ssl]}.update(request_options)).execute
      end
    end

    class Request
      def initialize(http_method, url, options={})
        @options = { timeout: 10, retry_count: 4, headers: {}, ssl: { verify_peer: false } }.update(options)
        assert_valid_keys(options, :timeout, :on_success, :on_error, :retry_count, :headers, :data, :ssl, :file)
        @http_method = http_method
        @url = url
        validate
      end

      def execute
        Happening::Log.debug "Request: #{http_method.to_s.upcase} #{url}"
        @response = http_class.new(url).send(http_method, :timeout => options[:timeout], :head => options[:headers], :body => options[:data], :ssl => options[:ssl], :file => options[:file])
        @response.errback { error_callback }
        @response.callback { success_callback }
        @response
      end
    end
  end
end

Encoding.default_external = 'utf-8'

Signal.trap 'INT' do
  log "Exiting..."
  $exiting = true
  EM.stop if EM.reactor_running?
  exit 0
end

$opts = Trollop::options do
  opt :verbose, 'Print extended information', :short => 'v'
  opt :debug, 'Print detailed debug information', :short => 'g'
  opt :noexcludes, 'Do not hash the .excludes directory', :short => 'e'
  opt :force, 'Rehash all local files instead of only updated files', :short => 'f'
  opt :dir, 'Local directory', :type => :string, :short => 'p'
  opt :hashesdir, 'Directory to write hashes.txt to', :type => :string, :short => 't'
  opt :host, 'S3 host address', :type => :string, :short => 'h'
  opt :idkey, 'S3 ID key', :type => :string, :short => 'i'
  opt :secretkey, 'S3 secret key', :type => :string, :short => 's'
  opt :bucket, 'S3 bucket to sync with', :type => :string, :default => 'ns2build', :short => 'b'
  opt :concurrency, 'Max concurrent connections', :default => 32, :short => 'u'
end

Happening::Log.level = Logger::DEBUG if $opts[:debug]

$verbose = $opts[:verbose]

unless $opts[:idkey]
  log :red, "S3 ID key is configuration missing! You need to use the --idkey command line option."
  exit 1
end

unless $opts[:secretkey]
  log :red, "S3 secret key configuration is missing! You need to use the --secretkey command line option."
  exit 1
end

unless $opts[:bucket]
  log :red, "S3 bucket configuration is missing! You need to use the --bucket command line option."
  exit 1
end

unless $local_directory = $opts[:dir]
  log "You need to specify a local directory with the --dir option"
  exit 1
end

$local_directory = $local_directory.gsub("\\", "/")
$local_directory = $local_directory[0..-2] if $local_directory =~ /[\/\\]$/

@local_file_info = {}

def load_cache
  cache_data = Marshal.load(File.binread('builder_cache.dat'))
  return unless cache = cache_data[$local_directory]
  @local_file_info = cache.local_files if cache.local_files?
  @generated_at = cache.generated_at if cache.generated_at?
  log "Loaded #{cache.local_files.size} local hashes from cache"
rescue Exception => ex
  log "An error occurred while loading your local cache: #{ex.message} (#{ex.class.name})"
  log "Local cache will need to be rebuilt"
end

def save_cache
  log "Saving cached data to disk..."
  cache = { local_files: @local_file_info, generated_at: @generated_at }
  cache_data = File.file?('builder_cache.dat') ? Marshal.load(File.binread('builder_cache.dat')) : {}
  cache_data[$local_directory] = cache
  open('builder_cache.dat', 'wb') {|f| f << Marshal.dump(cache_data) }
end

def compare_files
  file_paths = Dir[File.join($local_directory, '**/*')].reject {|path| File.directory?(path) }

  file_paths.reject! {|path| path[$local_directory.size+1, 9] == '.excludes' } if $opts[:noexcludes]

  sub_paths = file_paths.map {|path| path[$local_directory.size+1..-1] }

  if @local_file_info.present?
    removed_file_info = @local_file_info.reject {|sub_path, _| sub_paths.include? sub_path }
    @local_file_info.reject! {|sub_path, _| removed_file_info[sub_path] }
    @files_to_delete = removed_file_info.keys
    log "#{@files_to_delete.size} files have been deleted from disk"
  end

  log "Hashing and comparing #{sub_paths.size} files..."

  started_at = Time.now

  @files_to_upload = []

  last_update_at = started_at
  file_paths.each.with_index do |file_path, i|
    sub_path = file_path[$local_directory.size+1..-1]

    file_size = File.size(file_path)
    file_mtime = File.mtime(file_path)

    unless $opts[:force]
      if cached_file = @local_file_info[sub_path]
        if file_size == cached_file.fsize && file_mtime == cached_file.mtime
          next
        end
      end
    end

    hash = Digest::MD5.file(file_path).hexdigest
    @local_file_info[sub_path] = { fsize: file_size, mtime: file_mtime, hash: hash }

    @files_to_upload << sub_path

    if Time.now - last_update_at >= 0.1
      log "Hashed #{i+1}/#{file_paths.size} files"
      last_update_at = Time.now
    end
  end

  @generated_at = Time.now

  log "#{@files_to_upload.size}/#{file_paths.size} files have been updated. Hashing and comparing took #{started_at.distance_in_words}."
end

def delete_file(sub_path)
  log "Deleting file: #{sub_path}" if $verbose
  @delete_attempts[sub_path] += 1
  started_at = Time.now
  attempt_complete = proc do
    if @files_to_delete.size > 0
      delete_file(@files_to_delete.shift)
    elsif @files_to_delete.size + @delete_attempts.size == 0
      @delete_callback.() if @delete_callback
    end
  end
  delete_failed = proc do |http|
    http_status = http.response_header.status
    api_response = Hash[(http.response.scan(/\<([^>]+)\>([^<]+?)\<\/([^>]+)\>/).map {|arr| arr.take(2) })] rescue { }
    error_code = http.response_header['X_AMZ_ERROR_CODE'] || api_response['Code'] || 'Unknown'
    error_message = http.response_header['X_AMZ_ERROR_MESSAGE'] || api_response['Message'] || 'Error'
    log "Delete failed: #{sub_path} (attempt: #{@delete_attempts[sub_path]}, status: #{http_status}, #{error_code}: #{error_message})"
    @files_to_delete << sub_path
    attempt_complete.()
  end
  item = Happening::S3::Item.new($opts[:bucket], sub_path, protocol: 'http', aws_access_key_id: $opts[:idkey], aws_secret_access_key: $opts[:secretkey])
  item.delete(on_error: delete_failed) do
    log "File deleted: #{sub_path} (took #{'%.2f' % (Time.now - started_at)} seconds)" if $verbose
    @delete_attempts.delete(sub_path)
    @deleted_file_count += 1
    attempt_complete.()
  end
end

def remove_deleted_files(&block)
  unless @files_to_delete.present?
    log "There are no files which need to be deleted"
    yield if block_given?
    return
  end
  @delete_callback = block
  @started_deleting_at = Time.now
  @deleted_file_count = 0
  @delete_attempts = Hash.new {|hash, key| hash[key] = 0 }
  [$opts[:concurrency], @files_to_delete.size].min.times do
    delete_file(@files_to_delete.shift)
  end
end

def upload_file(sub_path)
  log "Uploading file: #{sub_path} (#{@local_file_info[sub_path].fsize} bytes)" if $verbose
  @upload_attempts[sub_path] += 1
  started_at = Time.now
  attempt_complete = proc do
    if @files_to_upload.size > 0
      upload_file(@files_to_upload.shift)
    elsif @files_to_upload.size + @upload_attempts.size == 0
      log "Upload complete. #@uploaded_file_count file uploaded in #{'%.2f' % (Time.now - started_at)} seconds"
      @upload_callback.() if @upload_callback
    end
  end
  upload_failed = proc do |http|
    http_status = http.response_header.status
    api_response = Hash[(http.response.scan(/\<([^>]+)\>([^<]+?)\<\/([^>]+)\>/).map {|arr| arr.take(2) })] rescue { }
    error_code = http.response_header['X_AMZ_ERROR_CODE'] || api_response['Code'] || 'Unknown'
    error_message = http.response_header['X_AMZ_ERROR_MESSAGE'] || api_response['Message'] || 'Error'
    log "Upload failed: #{sub_path} (attempt: #{@upload_attempts[sub_path]}, status: #{http_status}, #{error_code}: #{error_message})"
    @files_to_upload << sub_path
    attempt_complete.()
  end
  item = Happening::S3::Item.new($opts[:bucket], sub_path, protocol: 'http', aws_access_key_id: $opts[:idkey], aws_secret_access_key: $opts[:secretkey])
  #item.store("#$local_directory/#{sub_path}", on_error: upload_failed) do |info| # streaming uploads are disabled until blocking IO error can be solved
  item.put(File.binread("#$local_directory/#{sub_path}"), on_error: upload_failed) do
    log "File uploaded: #{sub_path} (took #{'%.2f' % (Time.now - started_at)} seconds)" if $verbose
    @upload_attempts.delete(sub_path)
    @uploaded_file_count += 1
    attempt_complete.()
  end
end

def upload_changes(&block)
  if @files_to_upload.size == 0
    log "There are no files which need to be uploaded"
    yield if block_given?
    return
  end
  @upload_callback = block
  @started_uploading_at = Time.now
  @uploaded_file_count = 0
  @upload_attempts = Hash.new {|hash, key| hash[key] = 0 }
  [$opts[:concurrency], @files_to_upload.size].min.times do
    upload_file(@files_to_upload.shift)
  end
end

def write_hashes_files
  hashes = { __Server: 'BUILDER', __DateGeneratedUTC: @generated_at.strftime('%y-%m-%d-%H-%M-%S') }
  @local_file_info.each do |sub_path, info|
    hashes["/#{sub_path}"] = { size: info[:fsize], time: info[:mtime].strftime('%Y-%m-%d %H:%M:%S'), hash: info[:hash] }
  end
  hashes_path = File.join($opts[:hashesdir] || '.', 'hashes.txt')
  open(hashes_path, 'w') {|f| f << JSON.fast_generate(hashes) }
  log "The hashes.txt file has been written to #{hashes_path}"
end

load_cache if File.exists? 'builder_cache.dat'

compare_files

save_cache

EM.run do
  remove_deleted_files do
    upload_changes do
      EM.stop
    end
  end
end

write_hashes_files