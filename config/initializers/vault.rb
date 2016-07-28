require 'byebug'
if ENV["SECRET_STORAGE_BACKEND"] == "SecretStorage::HashicorpVault"
  require 'vault'
  Rails.logger.info("Vault Client enabled")

  # Assumes that a vault.json file exists which contains an array of hashes.
  # Each hash represents an Vault instance Samson can connect to.
  # The attributes of the hash are:
  #   - vault_address (string, required) - URL of the vault host
  #   - deploy_groups (Array, required) - list of deploy groups for that Vault
  #   - ca_cert (string) - path to CA cert used to verify the Vault server cert
  #   - vault_token (string) - path to file containing an auth token
  #   - vault_auth_pem (string) - path to file containing a client certificate
  #   - tls_verify (boolean) - whether to verify the server's cert

  class VaultClient < Vault::Client
    CERT_AUTH_PATH = '/v1/auth/cert/login'.freeze
    DEFAULT_CLIENT_OPTIONS = {
      use_ssl: true,
      timeout: 5,
      ssl_timeout: 3,
      open_timeout: 3,
      read_timeout: 2
    }.freeze

    def self.auth_token(vault_server)
      uri = URI.parse(vault_server)
      @http = Net::HTTP.start(uri.host, uri.port, DEFAULT_CLIENT_OPTIONS)
      response = @http.request(Net::HTTP::Post.new(CERT_AUTH_PATH))
      if response.code == "200"
        JSON.parse(response.body).fetch("auth")["client_token"]
      else
        raise "Failed to get auth token from vault server"
      end
    end

    def self.client
      @client ||= new
    end

    def initialize
      return if Rails.env.test?
      ensure_config_exists
      # since we have a bunch of servers, don't use the client singlton to
      # talk to them
      # as we configure each client, check to see if the config has a token in it,
      # if it does, then we don't need to worry about going and getting one
      @vaults = {}
      vault_hosts.each do |vault_server|
        instance = vault_server["vault_instance"]
        if vault_server["vault_token"].present?
          @vaults[instance] = Vault::Client.new(DEFAULT_CLIENT_OPTIONS.merge(ssl_verify: vault_server["tls_verify"]))
          @vaults[instance].token = File.read(vault_server["vault_token"]).strip
        else
          pemfile = File.read(vault_server["vault_auth_pem"])
          client_cert_options = {
            cert: OpenSSL::X509::Certificate.new(pemfile),
            key: OpenSSL::PKey::RSA.new(pemfile),
            ssl_pem_file: vault_server["vault_auth_pem"],
            verify_mode: vault_server["tls_verify"]
          }
          writer = Vault::Client.new(DEFAULT_CLIENT_OPTIONS.merge(client_cert_options))
          writer.token = VaultClient.auth_token(vault_server["vault_address"])
        end
        @vaults[instance].address = vault_server["vault_address"]
        @vaults[instance].ssl_ca_cert = vault_server["ca_cert"] if vault_server["ca_cert"]
      end
    end

    # normally we'll only get a single instance back.  if it's global, just read it once
    def read(key)
      vault_instances(key).first.logical.read(key)
    end

    def list(path)
      @vaults.flat_map { |vault| vault.pop.logical.list(path) }
    end

    # make darn sure on deletes and writes that we try a couple of times.
    # not going to catch any other excpeptions as we want this to blow up
    # if anything fails
    def write(key, data)
      Vault.with_retries(Vault::HTTPConnectionError, attempts: 5) do
        vault_instances(key).each { |v| v.logical.write(key, data) }
      end
    end

    def delete(key)
      Vault.with_retries(Vault::HTTPConnectionError, attempts: 5) do
        vault_instances(key).each { |v| v.logical.delete(key) }
      end
    end

    def self.available_instances
      client = self.new
      client.send(:ensure_config_exists)
      JSON.parse(File.read(client.send(:vault_config_file))).map { |v| v["vault_instance"] }
    end

    private

    def ensure_config_exists
      unless File.exist?(vault_config_file)
        raise "VAULT_CONFIG_FILE or config/vault.json is required for #{ENV["SECRET_STORAGE_BACKEND"]}"
      end
    end

    def vault_hosts
      @vault_hosts ||= JSON.parse(File.read(vault_config_file))
    end

    def vault_config_file
      ENV['VAULT_CONFIG_FILE'] || Rails.root.join("config/vault.json")
    end

    # get back the vault instance that's required for this pod.  we'll take
    # the key, and look up the instance or return all of 'em if it's a global key
    def vault_instances(key = nil)
      deploy_group = key.split('/')[4]
      if deploy_group == 'global'
        @vaults.map { |vault| vault.pop }
      else
        deploy_group = DeployGroup.find_by_name(deploy_group)
        if deploy_group.nil?
          raise "no vault_instance configured for deploy group #{deploy_group}"
        end
        [@vaults[deploy_group.vault_instance]]
      end
    end
  end
end
