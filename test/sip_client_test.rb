# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/sip_client'
require_relative '../lib/sip_client/baresip'
require 'tmpdir'

class SipClientTest < Minitest::Test
  def test_base_class_raises_not_implemented
    client = SipClient.new
    assert_raises(SipClient::NotImplementedError) { client.call("555") }
    assert_raises(SipClient::NotImplementedError) { client.status }
    assert_raises(SipClient::NotImplementedError) { client.hangup }
    assert_raises(SipClient::NotImplementedError) { client.calls }
  end
end

class BaresipTest < Minitest::Test
  def setup
    @config_dir = Dir.mktmpdir('baresip-test')
    @client = SipClient::Baresip.new(
      sip_username: 'test_user',
      sip_password: 'test_pass',
      sip_server: 'sip.example.com',
      config_dir: @config_dir
    )
  end

  def teardown
    FileUtils.rm_rf(@config_dir)
  end

  def test_initializes_with_config
    assert @client
  end

  def test_generates_config_dir
    assert File.directory?(@client.config_dir), "Should create config directory"
  end

  def test_generates_accounts_file
    accounts_file = File.join(@client.config_dir, 'accounts')
    assert File.exist?(accounts_file), "Should generate accounts file"
    content = File.read(accounts_file)
    assert_match(/sip:test_user@sip\.example\.com/, content, "Accounts should contain SIP URI")
  end

  def test_generates_config_file
    config_file = File.join(@client.config_dir, 'config')
    assert File.exist?(config_file), "Should generate config file"
    content = File.read(config_file)
    assert_match(/module_path/, content)
    assert_match(/ctrl_tcp/, content)
    assert_match(/g711/, content)
  end

  def test_format_number_adds_country_code
    formatted = @client.send(:format_number, "5550100")
    assert_equal "15550100", formatted
  end

  def test_format_number_keeps_full_number
    formatted = @client.send(:format_number, "15550100")
    assert_equal "15550100", formatted
  end

  def test_format_number_strips_non_digits
    formatted = @client.send(:format_number, "(555) 010-0100")
    assert_equal "15550100", formatted
  end

  def test_default_ctrl_port
    assert_equal 4444, @client.ctrl_port
  end

  def test_ctrl_port_from_config
    client = SipClient::Baresip.new(
      sip_username: 'test_user',
      sip_password: 'test_pass',
      sip_server: 'sip.example.com',
      config_dir: @config_dir,
      ctrl_port: 5555
    )
    assert_equal 5555, client.ctrl_port
  end
end
