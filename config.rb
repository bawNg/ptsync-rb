DEFAULT_CONFIG = {
    'hash_server' => 'http://173.13.157.10:81/hashes.txt',
    'max_files_removed_without_warning' => 50,
    's3' => {
        'id_key' => 'id key goes here',
        'secret_key' => 'secret key goes here',
        'bucket' => 'ns2build'
    },
    'local_directory' => 'E:\\Natural Selection 2',
    'max_concurrency' => 48,
    'max_speed' => -1
}

def load_config
  contents = File.read('config.yml')
  if contents =~ /^local_directory:\s+".+"\s*$/
    log :yellow, 'Rewriting config.yml file after correcting quotation marks (do not use double quotes around your path)'
    contents.gsub!(/^(local_directory:\s+)"(.+)"\s*$/) { "#$1'#$2'" }
    open('config.yml', 'w') {|f| f << contents }
  end
  if contents =~ /^hash_server:\s+http:\/\/67\.164\.96\.34:81\/hashes\.txt\s*$/
    log :yellow, 'Rewriting config.yml file after updating outdated hashes server address'
    contents.gsub!(/http:\/\/67\.164\.96\.34:81\/hashes\.txt\s*$/, DEFAULT_CONFIG.hash_server)
    open('config.yml', 'w') {|f| f << contents }
  end
  YAML.load(contents)
rescue Exception => ex
  fail "Unable to parse config file: #{ex.message}"
end

def initialize_config
  $config = DEFAULT_CONFIG
  if File.exists?('config.yml')
    $config.rmerge!(load_config)
  else
    open('config.yml', 'w') do |file|
      YAML.dump(DEFAULT_CONFIG, file)
    end
  end
end