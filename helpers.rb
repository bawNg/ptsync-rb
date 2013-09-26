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

def fail(message)
  log :red, message
  puts "Exiting..."
  EM.stop
  exit 1
end

def http_request(method, address, options={}, &block)
  options[:parser] ||= JSON
  options[:parser_method] ||= :parse

  request_options = options.except(:parser, :parser_method, :attempt, :allow_failure)
  request_options[:redirects] ||= 5
  request_options[:head] ||= {}
  request_options[:head]['User-Agent'] ||= USER_AGENT
  request_options[:head]['Accept-Encoding'] ||= 'gzip, compressed'

  http = EM::HttpRequest.new(address).send(method, request_options)
  http.callback do
    begin
      if method == :head
        block.(http)
      else
        doc = options[:parser] == 'raw' ? http.response : options[:parser].send(options[:parser_method], http.response)
        catch(:done) { block.arity > 1 ? block.(http, doc) : block.(doc) }
      end
    rescue Exception => ex
      next if $exiting
      log :red, "Exception raised while parsing http response: #{method} #{address} (#{ex.class.name})"
      if options[:allow_failure]
        log :red, "Exception: #{ex.message.gsub(/\r?\n/, ' ')}"
      else
        fail "Exception: #{ex.message.gsub(/\r?\n/, ' ')} (#{ex.class.name})"
      end
      #log :yellow, http.response
      ex.backtrace.each {|line| print line + "\n" }
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