#!/usr/bin/env ruby

# If copying this template by hand, replace the settings below including the angle brackets
SETTINGS = {
  :url          => "https://foreman.example.com",  # e.g. https://foreman.example.com
  :puppetdir    => "/var/lib/puppet",  # e.g. /var/lib/puppet
  :puppetuser   => "puppet",  # e.g. puppet
  :facts        => true,          # true/false to upload facts
  :timeout      => 10,
  # if CA is specified, remote Foreman host will be verified
  :ssl_ca       => "/var/lib/puppet/ssl/certs/ca.pem",      # e.g. /var/lib/puppet/ssl/certs/ca.pem
  # ssl_cert and key are required if require_ssl_puppetmasters is enabled in Foreman
  :ssl_cert     => "/var/lib/puppet/ssl/certs/worker1.example.com.pem",    # e.g. /var/lib/puppet/ssl/certs/FQDN.pem
  :ssl_key      => "/var/lib/puppet/ssl/private_keys/worker1.example.com.pem"      # e.g. /var/lib/puppet/ssl/private_keys/FQDN.pem
}

# Script usually acts as an ENC for a single host, with the certname supplied as argument
#   if 'facts' is true, the YAML facts for the host are uploaded
#   ENC output is printed and cached
#
# If --push-facts is given as the only arg, it uploads facts for all hosts and then exits.
# Useful in scenarios where the ENC isn't used.

### Do not edit below this line

def url
  SETTINGS[:url] || raise("Must provide URL - please edit file")
end

def puppetdir
  SETTINGS[:puppetdir] || raise("Must provide puppet base directory - please edit file")
end

def puppetuser
  SETTINGS[:puppetuser] || 'puppet'
end

def stat_file(certname)
  FileUtils.mkdir_p "#{puppetdir}/yaml/foreman/"
  "#{puppetdir}/yaml/foreman/#{certname}.yaml"
end

def tsecs
  SETTINGS[:timeout] || 3
end

require 'etc'
require 'net/http'
require 'net/https'
require 'fileutils'
require 'timeout'
require 'yaml'
begin
  require 'json'
rescue LoadError
  # Debian packaging guidelines state to avoid needing rubygems, so
  # we only try to load it if the first require fails (for RPMs)
  begin
    require 'rubygems' rescue nil
    require 'json'
  rescue LoadError => e
    puts "You need the `json` gem to use the Foreman ENC script"
    # code 1 is already used below
    exit 2
  end
end

def upload_all_facts
  Dir["#{puppetdir}/yaml/facts/*.yaml"].each do |f|
    certname = File.basename(f, ".yaml")
    # Skip empty host fact yaml files
    if File.size(f) != 0
      upload_facts(certname, f)
    end
  end
end

def build_body(certname,filename)
  # Strip the Puppet:: ruby objects and keep the plain hash
  facts        = File.read(filename)
  puppet_facts = YAML::load(facts.gsub(/\!ruby\/object.*$/,''))
  hostname     = puppet_facts['values']['fqdn'] || certname
  {'facts' => puppet_facts['values'], 'name' => hostname, 'certname' => certname}
end

def upload_facts(certname, filename)
  # Temp file keeping the last run time
  stat = stat_file("#{certname}-push-facts")
  last_run = File.exists?(stat) ? File.stat(stat).mtime.utc : Time.now - 365*24*60*60
  last_fact = File.stat(filename).mtime.utc
  if last_fact > last_run
    begin
      uri = URI.parse("#{url}/api/hosts/facts")
      req = Net::HTTP::Post.new(uri.request_uri)
      req.add_field('Accept', 'application/json,version=2' )
      req.content_type = 'application/json'
      req.body         = build_body(certname, filename).to_json
      res              = Net::HTTP.new(uri.host, uri.port)
      res.use_ssl      = uri.scheme == 'https'
      if res.use_ssl?
        if SETTINGS[:ssl_ca] && !SETTINGS[:ssl_ca].empty?
          res.ca_file = SETTINGS[:ssl_ca]
          res.verify_mode = OpenSSL::SSL::VERIFY_PEER
        else
          res.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end
        if SETTINGS[:ssl_cert] && !SETTINGS[:ssl_cert].empty? && SETTINGS[:ssl_key] && !SETTINGS[:ssl_key].empty?
          res.cert = OpenSSL::X509::Certificate.new(File.read(SETTINGS[:ssl_cert]))
          res.key  = OpenSSL::PKey::RSA.new(File.read(SETTINGS[:ssl_key]), nil)
        end
      end
      res.start { |http| http.request(req) }
      cache("#{certname}-push-facts", "Facts from this host were last pushed to #{uri} at #{Time.now}\n")
    rescue => e
      raise "Could not send facts to Foreman: #{e}"
    end
  end
end

def cache(certname, result)
  File.open(stat_file(certname), 'w') {|f| f.write(result) }
end

def read_cache(certname)
  File.read(stat_file(certname))
rescue => e
  raise "Unable to read from Cache file: #{e}"
end

def enc(certname)
  foreman_url      = "#{url}/node/#{certname}?format=yml"
  uri              = URI.parse(foreman_url)
  req              = Net::HTTP::Get.new(uri.request_uri)
  http             = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl     = uri.scheme == 'https'
  if http.use_ssl?
    if SETTINGS[:ssl_ca] && !SETTINGS[:ssl_ca].empty?
      http.ca_file = SETTINGS[:ssl_ca]
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    else
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    if SETTINGS[:ssl_cert] && !SETTINGS[:ssl_cert].empty? && SETTINGS[:ssl_key] && !SETTINGS[:ssl_key].empty?
      http.cert = OpenSSL::X509::Certificate.new(File.read(SETTINGS[:ssl_cert]))
      http.key  = OpenSSL::PKey::RSA.new(File.read(SETTINGS[:ssl_key]), nil)
    end
  end
  res = http.start { |http| http.request(req) }

  raise "Error retrieving node #{certname}: #{res.class}" unless res.code == "200"
  res.body
end

# Actual code starts here

if __FILE__ == $0 then
  # Setuid to puppet user if we can
  begin
    Process::GID.change_privilege(Etc.getgrnam(puppetuser).gid) unless Etc.getpwuid.name == puppetuser
    Process::UID.change_privilege(Etc.getpwnam(puppetuser).uid) unless Etc.getpwuid.name == puppetuser
  rescue
    $stderr.puts "cannot switch to user #{puppetuser}, continuing as '#{Etc.getpwuid.name}'"
  end

  begin
    no_env = ARGV.delete("--no-environment")
    if ARGV.delete("--push-facts")
      # push all facts files to Foreman and don't act as an ENC
      upload_all_facts
    else
      certname = ARGV[0] || raise("Must provide certname as an argument")
      # send facts to Foreman - enable 'facts' setting to activate
      # if you use this option below, make sure that you don't send facts to foreman via the rake task or push facts alternatives.
      #
      if SETTINGS[:facts]
        upload_facts certname, "#{puppetdir}/yaml/facts/#{certname}.yaml"
      end
      #
      # query External node
      begin
        result = ""
        timeout(tsecs) do
          result = enc(certname)
          cache(certname, result)
        end
      rescue TimeoutError, SocketError, Errno::EHOSTUNREACH, Errno::ECONNREFUSED
        # Read from cache, we got some sort of an error.
        result = read_cache(certname)
      ensure
        require 'yaml'
        yaml = YAML.load(result)
        if no_env
          yaml.delete('environment')
        end
        # Always reset the result to back to clean yaml on our end
        puts yaml.to_yaml
      end
    end
  rescue => e
    warn e
    exit 1
  end
end
