class Hash
  def rmerge!(other_hash)
    merge!(other_hash) do |_, old_value, new_value|
      old_value.is_a?(Hash) ? old_value.rmerge!(new_value) : new_value
    end
  end

  def method_missing(method, *args)
    method_name = method.to_s
    unless respond_to? method_name
      if method_name.end_with? '?'
        method_name.slice! -1
        key = keys.detect {|k| k.to_s == method_name }
        return !!self[key]
      elsif method_name.end_with? '='
        method_name.slice! -1
        key = keys.detect {|k| k.to_s == method_name } || method_name
        return self[key] = args.first
      end
    end
    key = keys.detect {|k| k.to_s == method_name }
    return self[key] if key
    raise NoMethodError, "attribute '#{method_name}' does not exist in #{inspect}"
  end
end

class Time
  def distance_in_words
    distance_of_time_in_words((Time.now - self).abs)
  end
end

def distance_of_time_in_words(seconds)
  return 'less than 1 second' if seconds < 1
  unit_names = %w[ weeks days hours minutes seconds ]
  unit_sizes = [ 7, 24, 60, 60 ]
  units = unit_sizes.reverse.inject [seconds] do |result, unit_size|
    result[0, 0] = result.shift.to_i.divmod(unit_size)
    result
  end
  units.map.with_index.reject {|n, _| n == 0 }.map {|n, i| "#{n} #{unit_names[i][0..(n < 2 ? -2 : -1)]}" }.join(', ')
end

def log(*msgs)
  colour = msgs.first.is_a?(Symbol) ? msgs.shift : :default
  colour = :reset if colour == :yellow && ENV['OS'] == 'Windows_NT'
  msgs[0] = msgs.first.to_s unless msgs.first.is_a? String
  msgs = ["[#{Time.now.strftime('%H:%M:%S')}] #{msgs.shift}", *msgs]
  puts msgs.join(' ').colorize(colour)
end

def fail(message=nil)
  log :red, message if message
  $exiting = true
  puts "Exiting..."
  EM.stop if EM.reactor_running?
  exit 1
end

def http_request(method, address, options={}, &block)
  options[:parser] ||= JSON
  options[:parser_method] ||= :parse

  request_options = options.except(:parser, :parser_method, :attempt, :allow_failure)
  request_options[:redirects] ||= 5
  request_options[:head] ||= {}
  request_options[:head]['User-Agent'] ||= 'ptsync-rb'
  request_options[:head]['Accept-Encoding'] ||= 'gzip, compressed'

  http = EM::HttpRequest.new(address).send(method, request_options)
  http.callback do
    begin
      if method == :head
        block.(http)
      else
        response_body = http.response.force_encoding('utf-8')
        response_body.slice!(3) if response_body[0..2] == "\xEF\xBB\xBF"
        result = case options[:parser]
          when 'raw'
            response_body
          when JSON
            JSON.parse(response_body)
          else
            options[:parser].send(options[:parser_method], response_body)
        end
        catch(:done) { block.arity > 1 ? block.(http, result) : block.(result) }
      end
    rescue Exception => ex
      next if ex.is_a? SystemExit
      log :red, "Exception raised while handling http response: #{method} #{address} (#{ex.class.name})"
      log :red, "Exception: #{ex.message.gsub(/\r?\n/, ' ')[0..512]} (#{ex.class.name})"
      ex.backtrace.each {|line| puts line }
      fail unless options[:allow_failure]
      #log :yellow, http.response
      @last_exception = ex
    end
  end
  http.errback do |error|
    next if $exiting
    options[:attempt] ||= 1
    if options[:attempt] >= 5
      if options[:allow_failure]
        block.arity > 1 ? block.(http, nil) : block.(nil)
      else
        fail "[http_request] #{method} #{address} - All 5 attempts failed! #{http.error.inspect}"
      end
      next
    end
    log :yellow, "[http_request] #{method} #{address} - Attempt ##{options[:attempt]} failed! Code: #{http.response_header.status} Retrying..." if $verbose
    options[:attempt] += 1
    http_request(method, address, options, &block)
  end
end

def sync_client_update_available
  log "Checking if PTSync-rb is up to date..." if $verbose
  http_request :get, "#{UPDATE_URL_BASE}/version.json", allow_failure: true do |http, response|
    if response
      yield response['version'] > PT_SYNC_VERSION, response['files']
    else
      log :yellow, "Warning: Client auto update version check failed! (code: #{http.response_header.status})"
      yield false
    end
  end
  $last_client_update_check_at = Time.now
end

def relaunch_application
  Dir.chdir($root_directory)
  command = $packaged ? File.join($root_directory, '..', 'bin', 'ruby') : 'ruby'
  exec_args = [command, $0, *$argv]
  exec_args << "--ipcport#$ipc_port" if $ipc_port
  exec *exec_args
rescue Exception => ex
  log :red, "Error while relaunching: #{exec_args.inspect}"
  log :red, "Exception raised: #{ex.message} (#{ex.class.name})"
  ex.backtrace.each {|line| puts line }
  fail "Please report the details printed above to bawNg."
end

def update_sync_client_if_needed
  on :updating_client
  sync_client_update_available do |update_available, files|
    if update_available
      log :green, "There is a new version of PTSync-rb available!"
      if $git_repo
        log :red, "Auto-updating is not available since you are using a git repo. Use `git pull` to update your version."
        yield if block_given?
        next
      end
      target_directory = $root_directory # not packaged
      target_directory = File.dirname($root_directory) if $packaged # one level up from src directory
      if $packaged
        # This wrapper binary for the GUI application is never updated since it would be in use
        files << 'ptsync_gui.exe' unless File.exists? "#$root_directory/../ptsync_gui.exe"
      end
      downloaded_files = 0
      files.each do |file_name|
        log :yellow, "Downloading PTSync-rb update file: #{file_name}" if $verbose
        http_request :get, "#{UPDATE_URL_BASE}/#{file_name}", parser: 'raw' do |http, contents|
          target_file_directory = target_directory
          target_file_directory = target_directory + '/src' if $packaged && File.extname(file_name) == '.rb'
          open("#{target_file_directory}/#{file_name}", 'wb') {|f| f << contents }
          downloaded_files += 1
          log :cyan, "[#{downloaded_files}/#{files.size}] Sync client files updated"
          on :updating_client, downloaded_files / files.size * 100
          if downloaded_files == files.size
            log :green, "PTSync-rb updated successfully! Relaunching new version..."
            if $ipc_port
              on :restarting
            else
              relaunch_application
            end
          end
        end
      end
    else
      yield if block_given?
    end
  end
end

def on(event_name, *args, &block)
  $callbacks ||= {}
  if block_given?
    ($callbacks[event_name] ||= []) << block
  elsif (callbacks = $callbacks[event_name])
    callbacks.each {|cb| cb.(*args) }
  end
end

def on_once(event_name, &block)
  raise 'on_once can only be used to register callbacks' unless block_given?
  ($callbacks ||= {})[event_name] ||= []
  callback_wrapper = lambda do |*args|
    $callbacks[event_name].delete(callback_wrapper)
    block.(*args)
  end
  $callbacks[event_name] << callback_wrapper
end

def human_readable_byte_size(byte_size)
  file_size = byte_size
  unit = 'bytes'
  if file_size >= 1024
    file_size /= 1024.0
    unit = 'KB'
  end
  if file_size >= 1024
    file_size /= 1024.0
    unit = 'MB'
  end
  if file_size >= 1024
    file_size /= 1024.0
    unit = 'GB'
  end
  "#{'%.2f' % file_size} #{unit}"
end

def frontend?
  Object.const_defined?(:IpcServer) && !!IpcServer.connection
end