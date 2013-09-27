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

def log(*msgs)
  colour = msgs.first.is_a?(Symbol) ? msgs.shift : :default
  colour = :reset if colour == :yellow && ENV['OS'] == 'Windows_NT'
  msgs[0] = msgs.first.to_s unless msgs.first.is_a? String
  msgs = ["[#{Time.now.strftime('%H:%M:%S')}] #{msgs.shift}", *msgs]
  puts msgs.join(' ').colorize(colour)
end

def fail(message=nil)
  log :red, message if message
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
        result = case options[:parser]
          when 'raw'
            http.response
          when JSON
            JSON.parse(http.response.force_encoding('utf-8'))
          else
            options[:parser].send(options[:parser_method], http.response)
        end
        catch(:done) { block.arity > 1 ? block.(http, result) : block.(result) }
      end
    rescue Exception => ex
      next if ex.is_a? SystemExit
      log :red, "Exception raised while handling http response: #{method} #{address} (#{ex.class.name})"
      log :red, "Exception: #{ex.message.gsub(/\r?\n/, ' ')} (#{ex.class.name})"
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
  log :yellow, "Checking if PTSync-rb is up to date..."
  http_request :get, 'http://germ.intoxicated.co.za/ns2/ptsync/version.json', allow_failure: true do |http, response|
    if response
      yield response['version'] > PT_SYNC_VERSION, response['files']
    else
      log :red, "Warning: Auto update version check failed! (code: #{http.response_header.status})"
      yield false
    end
  end
  $last_client_update_check_at = Time.now
end

def relaunch_application
  Dir.chdir($root_directory)
  command = $packaged ? File.join($root_directory, '..', 'bin', 'ruby') : 'ruby'
  exec_args = [command, $0, *$argv]
  exec *exec_args
rescue Exception => ex
  log :red, "Error while relaunching: #{exec_args.inspect}"
  log :red, "Exception raised: #{ex.message} (#{ex.class.name})"
  ex.backtrace.each {|line| puts line }
  fail "Please report the details printed above to bawNg."
end

def update_sync_client_if_needed
  sync_client_update_available do |update_available, files|
    if update_available
      log :green, "There is a new version of PTSync-rb available!"
      downloaded_files = 0
      files.each do |file_name|
        log :yellow, "Downloading PTSync-rb update file: #{file_name}" if $verbose
        http_request :get, 'http://germ.intoxicated.co.za/ns2/ptsync/' + file_name, parser: 'raw' do |http, contents|
          open("#$root_directory/#{file_name}", 'wb') {|f| f << contents }
          downloaded_files += 1
          log :cyan, "[#{downloaded_files}/#{files.size}] Sync client files updated"
          if downloaded_files == files.size
            log :green, "PTSync-rb updated successfully! Relaunching new version..."
            relaunch_application
          end
        end
      end
    else
      yield if block_given?
    end
  end
end