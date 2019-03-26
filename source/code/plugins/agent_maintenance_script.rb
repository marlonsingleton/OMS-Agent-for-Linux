require 'optparse'

module MaintenanceModule

  class Maintenance
    require 'openssl'
    require 'fileutils'
    require 'net/http'
    require 'uri'
    require 'gyoku'
    require 'syslog/logger'
    require 'etc'

    require_relative 'oms_common'
    require_relative 'oms_configuration'
    require_relative 'agent_topology_request_script'

    attr_reader :AGENT_USER, :load_config_return_code
    attr_accessor :suppress_stdout
  
    def initialize(omsadmin_conf_path, cert_path, key_path, pid_path, proxy_path,
                   os_info, install_info, log = nil, verbose = false)
      @suppress_logging = true  # suppress_logging suppresses all output, including both print and logger
      @suppress_stdout = false  # suppress_stdout suppresses only print

      @AGENT_USER = "omsagent"
      @AGENT_GROUP = "omiusers"
      @omsadmin_conf_path = omsadmin_conf_path
      @cert_path = cert_path
      @key_path = key_path
      @pid_path = pid_path
      @proxy_path = proxy_path
      @os_info = os_info
      @install_info = install_info
      @verbose = verbose
      # Config to be read/written from omsadmin.conf
      @WORKSPACE_ID = nil
      @AGENT_GUID = nil
      @URL_TLD = nil
      @LOG_FACILITY = nil
      @CERTIFICATE_UPDATE_ENDPOINT = nil

      @load_config_return_code = load_config
      @logger = log ? log : OMS::Common.get_logger(@LOG_FACILITY)

      @suppress_logging = false
    end

    # Return true if the current executing user is root
    def is_current_user_root
      return true if (Process.euid == 0)
    end

    # Return true if the user should be running this script (root or omsagent or testing)
    def check_user
      if (!ENV["TEST_WORKSPACE_ID"].nil? or !ENV["TEST_SHARED_KEY"].nil?) or
          (is_current_user_root or Etc.getpwuid(Process.euid).name == @AGENT_USER)
        return true
      else
        log_error("This script must be run as root or as the #{@AGENT_USER} user.")
        return false
      end
    end

    # Return variable derived from install_info.txt (like "LinuxMonitoringAgent/1.2.0-148")
    def get_user_agent
      user_agent = "LinuxMonitoringAgent/"
      if OMS::Common.file_exists_nonempty(@install_info)
        user_agent.concat(File.readlines(@install_info)[0].split.first)
      end
      return user_agent
    end

    # Ensure files generated by this script are owned by omsagent
    def chown_omsagent(file_list)
      if is_current_user_root
        FileUtils.chown(@AGENT_USER, @AGENT_GROUP, file_list)
      end
    end

    # Logging methods
    def log_info(message)
      print("info\t#{message}\n") if !@suppress_logging and !@suppress_stdout
      @logger.info(message) if !@suppress_logging
    end

    def log_error(message)
      print("error\t#{message}\n") if !@suppress_logging and !@suppress_stdout
      @logger.error(message) if !@suppress_logging
    end

    def log_debug(message)
      print("debug\t#{message}\n") if !@suppress_logging and !@suppress_stdout
      @logger.debug(message) if !@suppress_logging
    end

    # Load necessary configuration values from omsadmin.conf
    def load_config
      if !File.exist?(@omsadmin_conf_path)
        log_error("Missing configuration file: #{@omsadmin_conf_path}")
        return OMS::MISSING_CONFIG_FILE
      end

      File.open(@omsadmin_conf_path, "r").each_line do |line|
        if line =~ /^WORKSPACE_ID/
          @WORKSPACE_ID = line.sub("WORKSPACE_ID=","").strip
        elsif line =~ /^AGENT_GUID/
          @AGENT_GUID = line.sub("AGENT_GUID=","").strip
        elsif line =~ /^URL_TLD/
          @URL_TLD = line.sub("URL_TLD=","").strip
        elsif line =~ /^LOG_FACILITY/
          @LOG_FACILITY = line.sub("LOG_FACILITY=","").strip
        elsif line =~ /^CERTIFICATE_UPDATE_ENDPOINT/
          @CERTIFICATE_UPDATE_ENDPOINT = line.sub("CERTIFICATE_UPDATE_ENDPOINT=","").strip
        end
      end

      return 0
    end

    # Update omsadmin.conf with the specified variable's value
    def update_config(var, val)
      if !File.exist?(@omsadmin_conf_path)
        return OMS::MISSING_CONFIG_FILE
      end

      old_text = File.read(@omsadmin_conf_path)
      new_text = old_text.sub(/^#{var}=.*\n/,"#{var}=#{val}\n")

      File.open(@omsadmin_conf_path, "w") { |file|
        file.puts(new_text)
      }
    end

    # Updates the CERTIFICATE_UPDATE_ENDPOINT variable and renews certificate if requested
    def apply_certificate_update_endpoint(server_resp, check_for_renew_request = true)
      update_attr = ""
      cert_update_endpoint = ""

      # Extract the certificate update endpoint from the server response
      endpoint_tag_regex = /\<CertificateUpdateEndpoint.*updateCertificate=\"(?<update_cert>(true|false))\".*(?<cert_update_endpoint>https.*RenewCertificate).*CertificateUpdateEndpoint\>/
      endpoint_tag_regex.match(server_resp) { |match|
        cert_update_endpoint = match["cert_update_endpoint"]
        update_attr = match["update_cert"]
      }
 
      if cert_update_endpoint.empty?
        log_error("Could not extract the update certificate endpoint.")
        return OMS::MISSING_CERT_UPDATE_ENDPOINT
      elsif update_attr.empty?
        log_error("Could not find the updateCertificate tag in OMS Agent management service telemetry response")
        return OMS::ERROR_EXTRACTING_ATTRIBUTES
      end

      # Update omsadmin.conf with cert_update_endpoint variable
      @CERTIFICATE_UPDATE_ENDPOINT = cert_update_endpoint
      # When apply_dsc_endpoint is called from onboarding, dsc_endpoint will be returned in file
      update_config("CERTIFICATE_UPDATE_ENDPOINT", cert_update_endpoint)
 
      # Check in the response if the certs should be renewed
      if update_attr == "true" and check_for_renew_request
        renew_certs_ret = renew_certs
        if renew_certs_ret != 0
          return renew_certs_ret
        end
      end

      return cert_update_endpoint
    end

    # Update the DSC_ENDPOINT variable in omsadmin.conf from the server XML
    def apply_dsc_endpoint(server_resp)
      dsc_endpoint = ""

      # Extract the DSC endpoint from the server response
      dsc_conf_regex = /<DscConfiguration.*<Endpoint>(?<endpoint>.*)<\/Endpoint>.*DscConfiguration>/
      dsc_conf_regex.match(server_resp) { |match|
        dsc_endpoint = match["endpoint"]
        # Insert escape characters before open and closed parentheses
        dsc_endpoint = dsc_endpoint.gsub("(", "\\\\(").gsub(")", "\\\\)")
      }

      if dsc_endpoint.empty?
        log_error("Could not extract the DSC endpoint.")
        return OMS::ERROR_EXTRACTING_ATTRIBUTES
      end

      # Update omsadmin.conf with dsc_endpoint variable
      # When apply_dsc_endpoint is called from onboarding, dsc_endpoint will be returned in file
      update_config("DSC_ENDPOINT", dsc_endpoint)

      return dsc_endpoint
    end

    # Pass the server response from an XML file to apply_dsc_endpoint and apply_certificate_update_endpoint
    # Save DSC_ENDPOINT and CERTIFICATE_UPDATE_ENDPOINT variables in file to be read outside of this script
    def apply_endpoints_file(xml_file, output_file)
      if !OMS::Common.file_exists_nonempty(xml_file)
        return OMS::MISSING_CONFIG_FILE
      end

      server_resp = File.read(xml_file)
      cert_update_applied = apply_certificate_update_endpoint(server_resp, check_for_renew_request = false)
      dsc_applied = apply_dsc_endpoint(server_resp)

      if cert_update_applied.class != String
        return cert_update_applied
      elsif dsc_applied.class != String
        return dsc_applied
      else
        output_handle = nil
        begin
          # To return endpoint strings to onboarding script, save to file
          output_handle = File.new(output_file, "w")
          chown_omsagent(output_file)
          output_handle.write("#{cert_update_applied}\n"\
                              "#{dsc_applied}\n")
        rescue => e
          log_error("Error saving endpoints to file: #{e.message}")
          return OMS::ERROR_WRITING_TO_FILE
        ensure
          if !output_handle.nil?
            output_handle.close
          end
        end
      end

      return 0
    end

    # Perform a topology request against the OMS endpoint
    def heartbeat
      # Reload config in case of updates since last topology request
      @load_config_return_code = load_config
      if @load_config_return_code != 0
        log_error("Error loading configuration from #{@omsadmin_conf_path}")
        return @load_config_return_code
      end

      # Check necessary inputs
      if @WORKSPACE_ID.nil? or @AGENT_GUID.nil? or @URL_TLD.nil? or
          @WORKSPACE_ID.empty? or @AGENT_GUID.empty? or @URL_TLD.empty?
        log_error("Missing required field from configuration file: #{@omsadmin_conf_path}")
        return OMS::MISSING_CONFIG
      elsif !OMS::Common.file_exists_nonempty(@cert_path) or !OMS::Common.file_exists_nonempty(@key_path)
        log_error("Certificates for topology request do not exist")
        return OMS::MISSING_CERTS
      end

      # Generate the request body
      begin
        body_hb_xml = AgentTopologyRequestHandler.new.handle_request(@os_info, @omsadmin_conf_path,
            @AGENT_GUID, OMS::Common.get_cert_server(@cert_path), @pid_path, telemetry=true)
        if !xml_contains_telemetry(body_hb_xml)
          log_debug("No Telemetry data was appended to OMS agent management service topology request")
        end
      rescue => e
        log_error("Error when appending Telemetry to OMS agent management service topology request: #{e.message}")
      end

      # Form headers
      headers = {}
      req_date = Time.now.utc.strftime("%Y-%m-%dT%T.%N%:z")
      headers[OMS::CaseSensitiveString.new("x-ms-Date")] = req_date
      headers["User-Agent"] = get_user_agent
      headers[OMS::CaseSensitiveString.new("Accept-Language")] = "en-US"

      # Form POST request and HTTP
      req,http = OMS::Common.form_post_request_and_http(headers, "https://#{@WORKSPACE_ID}.oms.#{@URL_TLD}/"\
                "AgentService.svc/LinuxAgentTopologyRequest", body_hb_xml,
                OpenSSL::X509::Certificate.new(File.open(@cert_path)),
                OpenSSL::PKey::RSA.new(File.open(@key_path)), @proxy_path)

      log_info("Generated topology request:\n#{req.body}") if @verbose

      # Submit request
      begin
        res = nil
        res = http.start { |http_each| http.request(req) }
      rescue => e
        log_error("Error sending the topology request to OMS agent management service: #{e.message}")
      end

      if !res.nil?
        log_info("OMS agent management service topology request response code: #{res.code}") if @verbose

        if res.code == "200"
          cert_apply_res = apply_certificate_update_endpoint(res.body)
          dsc_apply_res = apply_dsc_endpoint(res.body)
          frequency_apply_res = OMS::Configuration.apply_request_intervals(res.body)
          if cert_apply_res.class != String
            return cert_apply_res
          elsif dsc_apply_res.class != String
            return dsc_apply_res
          elsif frequency_apply_res.class != String
            return frequency_apply_res
          else
            log_info("OMS agent management service topology request success")
            return 0
          end
        else
          log_error("Error sending OMS agent management service topology request . HTTP code #{res.code}")
          return OMS::HTTP_NON_200
        end
      else
        log_error("Error sending OMS agent management service topology request . No HTTP code")
        return OMS::ERROR_SENDING_HTTP
      end
    end

    # Create the public/private key pair for the agent/workspace
    def generate_certs(workspace_id, agent_guid)
      if workspace_id.nil? or agent_guid.nil? or workspace_id.empty? or agent_guid.empty?
        log_error("Both WORKSPACE_ID and AGENT_GUID must be defined to generate certificates")
        return OMS::MISSING_CONFIG
      end

      log_info("Generating certificate ...")
      error=nil

      # Set safe certificate permissions before to prevent timing attacks
      key_file = File.new(@key_path, "w")
      cert_file = File.new(@cert_path, "w")
      File.chmod(0640, @key_path)
      File.chmod(0640, @cert_path)
      chown_omsagent([@key_path, @cert_path])

      begin
        # Create new private key of 2048 bits
        key = OpenSSL::PKey::RSA.new(2048)

        x509_version = 2  # enable X509 V3 extensions
        two_byte_range = 2**16 - 2  # 2 digit byte range for serial number
        year = 1 * 365 * 24 * 60 * 60  # 365 days validity for certificate
  
        # Generate CSR from new private key
        csr = OpenSSL::X509::Request.new
        csr.version = x509_version
        csr.subject = OpenSSL::X509::Name.new([
            ["CN", workspace_id],
            ["CN", agent_guid],
            ["OU", "Linux Monitoring Agent"],
            ["O", "Microsoft"]])
        csr.public_key = key.public_key
        csr.sign(key, OpenSSL::Digest::SHA256.new)
  
        # Self-sign CSR
        csr_cert = OpenSSL::X509::Certificate.new
        csr_cert.serial = SecureRandom.random_number(two_byte_range) + 1
        csr_cert.version = x509_version
        csr_cert.not_before = Time.now
        csr_cert.not_after = Time.now + year
        csr_cert.subject = csr.subject
        csr_cert.public_key = csr.public_key
        csr_cert.issuer = csr_cert.subject  # self-signed
        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = csr_cert
        ef.issuer_certificate = csr_cert
        csr_cert.add_extension(ef.create_extension("subjectKeyIdentifier","hash",false))
        csr_cert.add_extension(ef.create_extension("authorityKeyIdentifier","keyid:always",false))
        csr_cert.add_extension(ef.create_extension("basicConstraints","CA:TRUE",false))
        csr_cert.sign(key, OpenSSL::Digest::SHA256.new)

        # Write key and cert to files
        key_file.write(key)
        cert_file.write(csr_cert)
      rescue => e
        error = e
      ensure
        key_file.close
        cert_file.close
      end

      # Check for any error or non-existent or empty files
      if !error.nil?
        log_error("Error generating certs: #{error.message}")
        return OMS::ERROR_GENERATING_CERTS
      elsif !OMS::Common.file_exists_nonempty(@cert_path) or !OMS::Common.file_exists_nonempty(@key_path)
        log_error("Error generating certs")
        return OMS::ERROR_GENERATING_CERTS
      end

      return 0
    end

    # Simple class to support interaction with topology script helper method (obj_to_hash)
    class AgentRenewCertificateRequest < StrongTypedClass
      strongtyped_accessor :NewCertificate, String
    end

    # Restore the provided public/private key to the certs files
    def restore_old_certs(cert_old, key_old)
      cert_file = File.open(@cert_path, "w")
      cert_file.write(cert_old)
      cert_file.close

      key_file = File.open(@key_path, "w")
      key_file.write(key_old)
      key_file.close
    end
 
    # Renew certificates for agent/workspace connection
    def renew_certs
      # Check necessary inputs
      if @load_config_return_code != 0
        log_error("Error loading configuration from #{@omsadmin_conf_path}")
        return @load_config_return_code
      elsif @WORKSPACE_ID.nil? or @AGENT_GUID.nil? or @WORKSPACE_ID.empty? or @AGENT_GUID.empty?
        log_error("Missing required field from configuration file: #{@omsadmin_conf_path}")
        return OMS::MISSING_CONFIG
      elsif @CERTIFICATE_UPDATE_ENDPOINT.nil? or @CERTIFICATE_UPDATE_ENDPOINT.empty?
        log_error("Missing CERTIFICATE_UPDATE_ENDPOINT from configuration")
        return OMS::MISSING_CONFIG
      elsif !OMS::Common.file_exists_nonempty(@cert_path) or !OMS::Common.file_exists_nonempty(@key_path)
        log_error("No certificates exist; cannot renew certificates")
        return OMS::MISSING_CERTS
      end

      log_info("Renewing the certificates")

      # Save old certs
      cert_old = OpenSSL::X509::Certificate.new(File.open(@cert_path))
      key_old = OpenSSL::PKey::RSA.new(File.open(@key_path))

      generated = generate_certs(@WORKSPACE_ID, @AGENT_GUID)
      if generated != 0
        return generated
      end

      # Form POST request
      renew_certs_req = AgentRenewCertificateRequest.new
      renew_certs_req.NewCertificate = OMS::Common.get_cert_server(@cert_path)

      renew_certs_xml = "<?xml version=\"1.0\"?>\n"
      renew_certs_xml.concat(Gyoku.xml({ "CertificateUpdateRequest" => {:content! => obj_to_hash(renew_certs_req), \
:'@xmlns:xsi' => "http://www.w3.org/2001/XMLSchema-instance", :'@xmlns:xsd' => "http://www.w3.org/2001/XMLSchema", \
:@xmlns => "http://schemas.microsoft.com/WorkloadMonitoring/HealthServiceProtocol/2014/09/"}}))

      req,http = OMS::Common.form_post_request_and_http(headers = {}, @CERTIFICATE_UPDATE_ENDPOINT,
                     renew_certs_xml, cert_old, key_old, @proxy_path)

      log_info("Generated renew certificates request:\n#{req.body}") if @verbose

      # Submit request
      begin
        res = nil
        res = http.start { |http_each| http.request(req) }
      rescue => e
        log_error("Error renewing certificate: #{e.message}")
        restore_old_certs(cert_old, key_old)
        return OMS::ERROR_SENDING_HTTP
      end

      if !res.nil?
        log_info("Renew certificates response code: #{res.code}") if @verbose

        if res.code == "200"
          # Do one heartbeat for the server to acknowledge the change
          hb_return = heartbeat

          if hb_return == 0
            log_info("Certificates successfully renewed")
          else
            log_error("Error renewing certificate. Restoring old certs.")
            restore_old_certs(cert_old, key_old)
            return hb_return
          end
        else
          log_error("Error renewing certificate. HTTP code #{res.code}")
          restore_old_certs(cert_old, key_old)
          return OMS::HTTP_NON_200
        end
      else
        log_error("Error renewing certificate. No HTTP code")
        return OMS::ERROR_SENDING_HTTP
      end

      return 0
    end

  end # class Maintenance
end # module MaintenanceModule


# Define the usage of this maintenance script
def usage
  basename = File.basename($0)
  necessary_inputs = "<omsadmin_conf> <cert> <key> <pid> <proxy> <os_info> <install_info>"
  print("\nMaintenance tool for OMS Agent onboarded to workspace:"\
        "\nHeartbeat:\n"\
        "ruby #{basename} -h #{necessary_inputs}\n"\
        "ruby #{basename} --heartbeat #{necessary_inputs}\n"\
        "\nRenew certificates:\n"\
        "ruby #{basename} -r #{necessary_inputs}\n"\
        "ruby #{basename} --renew-certs #{necessary_inputs}\n"\
        "\nOptional: Add -v for verbose output\n")
end

if __FILE__ == $0
  options = {}
  OptionParser.new do |opts|
    opts.on("-h", "--heartbeat") do |h|
      options[:heartbeat] = h
    end
    opts.on("-c", "--generate-certs") do |c|
      options[:generate_certs] = c
    end
    opts.on("-r", "--renew-certs") do |r|
      options[:renew_certs] = r
    end
    opts.on("-w WORKSPACE_ID") do |w|
      options[:workspace_id] = w
    end
    opts.on("-a AGENT_GUID") do |a|
      options[:agent_guid] = a
    end
    opts.on("--endpoints XML,ENDPOINT_FILE", Array) do |e|
      options[:apply_endpoints] = e
    end
    opts.on("-v", "--verbose") do |v|
      options[:verbose] = true
    end
    # Note: this option only suppresses verbose output
    opts.on("-s", "--suppress-verbose") do |s|
      options[:verbose] = false
    end
  end.parse!

  if (ARGV.length < 7)
    usage
    exit 0
  end

  omsadmin_conf_path = ARGV[0]
  cert_path = ARGV[1]
  key_path = ARGV[2]
  pid_path = ARGV[3]
  proxy_path = ARGV[4]
  os_info = ARGV[5]
  install_info = ARGV[6]

  maintenance = MaintenanceModule::Maintenance.new(omsadmin_conf_path, cert_path, key_path,
                    pid_path, proxy_path, os_info, install_info, log = nil, options[:verbose])
  ret_code = 0

  if !maintenance.check_user
    ret_code = OMS::NON_PRIVELEGED_USER_ERROR_CODE

  elsif options[:heartbeat]
    ret_code = maintenance.heartbeat

  elsif options[:generate_certs]
    if ENV["TEST_WORKSPACE_ID"].nil? and ENV["TEST_SHARED_KEY"].nil? and !maintenance.is_current_user_root
      usage  # generate_certs only intended for onboarding script and testing
      ret_code = OMS::INVALID_OPTION_PROVIDED
    elsif options[:workspace_id].nil? or options[:agent_guid].nil?
      print("To generate certificates, you must include both -w WORKSPACE_ID and -a AGENT_GUID")
      ret_code = OMS::INVALID_OPTION_PROVIDED
    else
      ret_code = maintenance.generate_certs(options[:workspace_id], options[:agent_guid])
    end

  elsif options[:renew_certs]
    ret_code = maintenance.renew_certs

  elsif options[:apply_endpoints]
    if ENV["TEST_WORKSPACE_ID"].nil? and ENV["TEST_SHARED_KEY"].nil? and !maintenance.is_current_user_root
      usage  # apply_endpoints only intended for onboarding script and testing
      ret_code = OMS::INVALID_OPTION_PROVIDED
    elsif options[:apply_endpoints].length != 2
      print("To apply the endpoints, you must include both input XML and output file: "\
            "--endpoints XML,ENDPOINT_FILE\n")
      ret_code = OMS::INVALID_OPTION_PROVIDED
    else
      ret_code = maintenance.apply_endpoints_file(options[:apply_endpoints][0], options[:apply_endpoints][1])
    end

  else
    usage
  end

  exit ret_code
end
