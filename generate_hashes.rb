require 'active_support/json'
require 'active_support/core_ext'
require 'trollop'
require 'json'
require 'pp'
require './helpers'

class String
  def colorize(color)
    self
  end
end

Encoding.default_external = 'utf-8'

$opts = Trollop::options do
  opt :noexcludes, 'Do not hash the .excludes directory', :short => 'e'
  opt :force, 'Rehash all local files instead of only updated files', :short => 'f'
  opt :dir, 'Local directory', :type => :string, :short => 'p'
end

unless $local_directory = $opts[:dir]
  log "You need to specify a local directory with the --dir option"
  exit 1
end

@local_file_info = {}

if File.exists? 'builder_cache.dat'
  begin
    cache = Marshal.load(File.binread('builder_cache.dat'))
    @hashes_generated_at = cache.generated_at if cache.date_generated?
    @hashed_local_directory = cache.local_directory if cache.local_directory?
    if @hashed_local_directory && @hashed_local_directory == $local_directory
      @local_file_info = cache.local_files if cache.local_files?
    end
    log "Loaded #{@local_file_info.size} local hashes from cache"
  rescue Exception => ex
    log "An error occurred while loading your local cache: #{ex.message} (#{ex.class.name})"
    log "Local cache will need to be rebuilt"
  end
end

file_paths = Dir[File.join($local_directory, '**/*')].reject {|path| File.directory?(path) }

file_paths.reject! {|path| path[$local_directory.size, 9] == '.excludes' } if $opts[:noexcludes]

sub_paths = file_paths.map {|path| path[$local_directory.size..-1] }

if @local_file_info.present?
  cached_file_count = @local_file_info.size
  @local_file_info.select! {|sub_path, _| sub_path.include? sub_path }
  log "Removed #{cached_file_count - @local_file_info.size} deleted files from cache"
end

log "Hashing and comparing #{sub_paths.size} files..."

started_at = Time.now

updated_file_count = 0

last_update_at = started_at
file_paths.each.with_index do |file_path, i|
  sub_path = file_path[$local_directory.size..-1]

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

  updated_file_count += 1

  if Time.now - last_update_at >= 0.1
    log "Hashed #{i+1}/#{file_paths.size} files"
    last_update_at = Time.now
  end
end

@hashed_local_directory = $local_directory

log "#{updated_file_count}/#{file_paths.size} files have been updated. Hashing and comparing took #{started_at.distance_in_words}."

log "Saving cached data to disk..."
cache = { local_directory: @hashed_local_directory, local_files: @local_file_info, generated_at: Time.now }
open('builder_cache.dat', 'wb') {|f| f << Marshal.dump(cache) }

hashes = { __Server: 'BUILDER', __DateGeneratedUTC: cache.generated_at.strftime('%y-%m-%d-%H-%M-%S') }
cache.local_files.each do |sub_path, info|
  hashes["/#{sub_path}"] = { size: info[:fsize], time: info[:mtime].strftime('%Y-%m-%d %H:%M:%S'), hash: info[:hash] }
end
open('hashes.txt', 'w') {|f| f << JSON.fast_generate(hashes) }

log "The hashes.txt file has been written to disk"