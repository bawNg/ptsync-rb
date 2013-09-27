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

def load_config
  YAML.load_file('config.yml')
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