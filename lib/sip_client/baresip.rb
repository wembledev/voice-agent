# frozen_string_literal: true

require_relative '../sip_client'
require 'socket'
require 'timeout'
require 'fileutils'
require 'json'

class SipClient
  class Baresip < SipClient
    DEFAULT_CONFIG_DIR = File.join(File.expand_path('../..', __dir__), 'tmp', 'baresip')
    DEFAULT_CTRL_PORT = 4444

    attr_reader :config_dir, :ctrl_port

    def initialize(config = {})
      super
      @config_dir = @config[:config_dir] || DEFAULT_CONFIG_DIR
      @voice_socket = @config[:voice_socket]
      @pid = nil  # PID of baresip process we spawned (nil if pre-existing)
      load_sip_config
      ensure_config!
    end

    # Cleanly shut down a baresip process we spawned.
    # Sends the ctrl_tcp 'quit' command first (clean SIP deregister),
    # falls back to SIGTERM if that fails.
    def shutdown
      return unless @pid
      send_command('quit') rescue nil
      # Wait up to 2s for clean exit before sending SIGTERM
      20.times do
        break unless process_alive?(@pid)
        sleep 0.1
      end
      if process_alive?(@pid)
        Process.kill('TERM', @pid) rescue Errno::ESRCH
        sleep 0.5
      end
      @pid = nil
    end

    # Make a call
    def call(number, **opts)
      ensure_running!

      # Guard against multiple simultaneous calls
      active = calls
      unless active.empty?
        raise Error, "Call already active (#{active.size} in progress). Hang up first: bin/call hangup"
      end

      sip_number = format_number(number)
      uri = "sip:#{sip_number}@#{@sip_server}"

      send_command('dial', uri)

      sleep 2
      calls
    end

    # Get registration status
    def status
      ensure_running!
      response = send_command('reginfo')
      {
        registered: response.include?('OK'),
        response: response
      }
    end

    # Hangup current call
    def hangup
      send_command('hangup')
    end

    # Get list of active calls
    def calls
      response = send_command('listcalls')
      parse_calls(response)
    end

    private

    def load_sip_config
      @sip_username = @config[:sip_username] || raise(Error, 'sip_username not set')
      @sip_password = @config[:sip_password] || raise(Error, 'sip_password not set')
      @sip_server   = @config[:sip_server]   || raise(Error, 'sip_server not set')
      @module_path  = @config[:module_path]  || '/opt/homebrew/Cellar/baresip/4.5.0/lib/baresip/modules'
      @ctrl_port    = (@config[:ctrl_port]   || DEFAULT_CTRL_PORT).to_i
    end

    def ensure_config!
      FileUtils.mkdir_p(@config_dir)

      # Write accounts file
      accounts = File.join(@config_dir, 'accounts')
      File.write(accounts, "<sip:#{@sip_username}@#{@sip_server}>;auth_pass=#{@sip_password}\n")

      # Write minimal config
      config_file = File.join(@config_dir, 'config')
      File.write(config_file, baresip_config)
    end

    def baresip_config
      lines = []
      lines << "# baresip config (auto-generated)"
      lines << "module_path\t\t#{@module_path}"
      lines << ""
      lines << "# UI"
      lines << "module\t\t\tstdio.so"
      lines << ""
      lines << "# Audio"
      lines << "module\t\t\tg711.so"

      if @voice_socket
        lines << "module\t\t\tausock.so"
        lines << "audio_source\t\tausock,#{@voice_socket}"
        lines << "audio_player\t\tausock,#{@voice_socket}"
      end

      lines << ""
      lines << "# Apps"
      lines << "module_app\t\taccount.so"
      lines << "module_app\t\tmenu.so"
      lines << "module_app\t\tctrl_tcp.so"
      lines << ""
      lines << "ctrl_tcp_listen\t\t127.0.0.1:#{@ctrl_port}"
      lines << ""

      lines.join("\n")
    end

    def ensure_running!
      return if running?

      # Start baresip in background
      @pid = spawn("baresip -f #{@config_dir} > /dev/null 2>&1")
      Process.detach(@pid)

      # Wait for it to start
      10.times do
        sleep 0.5
        return if running?
      end

      raise Error, "Failed to start baresip"
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def running?
      send_command('reginfo')
      true
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Timeout::Error, Error
      false
    end

    def send_command(cmd, params = '')
      Timeout.timeout(2) do
        socket = TCPSocket.new('127.0.0.1', @ctrl_port)
        # baresip ctrl_tcp: netstring-encoded JSON
        # Commands use bare names (no / prefix): reginfo, listcalls, dial, hangup
        payload = { command: cmd, params: params }
        json = payload.to_json
        netstring = "#{json.length}:#{json},"
        socket.write(netstring)
        socket.close_write
        response = socket.read
        socket.close
        # Parse netstring response and extract data
        parsed = parse_netstring(response)
        return parsed unless parsed.start_with?('{')

        result = JSON.parse(parsed)
        result['data'] || result['error'] || parsed
      end
    rescue Errno::ECONNREFUSED
      raise Error, "baresip not running (ctrl port #{@ctrl_port} refused)"
    rescue JSON::ParserError
      parsed
    end

    def parse_netstring(data)
      return '' if data.nil? || data.empty?

      # Netstring format: <length>:<data>,
      if data =~ /^(\d+):(.+),?$/m
        length = $1.to_i
        content = $2
        content[0, length]
      else
        data
      end
    end

    def format_number(number)
      # Strip non-digits
      digits = number.gsub(/\D/, '')

      # Add 1 prefix for North American numbers if needed
      if digits.length == 10
        "1#{digits}"
      else
        digits
      end
    end

    def parse_calls(response)
      # Simple parser for /listcalls output
      # Example: "> [line 1, id abc123]  0:00:05  ESTABLISHED  sip:15550100@server.example.com"
      calls = []
      response.each_line do |line|
        if line =~ /\[line (\d+).*?\]\s+(\S+)\s+(\w+)\s+sip:(\S+)/
          calls << {
            line: $1.to_i,
            duration: $2,
            state: $3,
            uri: $4
          }
        end
      end
      calls
    end

  end
end
