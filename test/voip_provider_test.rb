# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/voip_provider'
require_relative '../lib/voip_provider/voipms'

class VoipProviderTest < Minitest::Test
  def test_base_class_raises_not_implemented
    provider = VoipProvider.new
    assert_raises(VoipProvider::NotImplementedError) { provider.balance }
    assert_raises(VoipProvider::NotImplementedError) { provider.phone_numbers }
    assert_raises(VoipProvider::NotImplementedError) { provider.registrations }
  end
end

class VoipmsTest < Minitest::Test
  def setup
    @api = VoipProvider::Voipms.new
  end

  def test_loads_credentials_from_env
    assert @api, "VoipProvider::Voipms should initialize from .env.local"
  end

  def test_balance_returns_success
    result = @api.balance
    assert_equal 'success', result['status']
    assert result['balance'], "Should include balance data"
  end

  def test_dids_returns_phone_numbers
    result = @api.dids
    assert_equal 'success', result['status']
    assert result['dids'].is_a?(Array), "Should return array of DIDs"
    assert result['dids'].any?, "Should have at least one DID"
  end

  def test_did_has_expected_fields
    result = @api.dids
    did = result['dids'].first
    assert did['did'], "DID should have a number"
    assert did['routing'], "DID should have routing"
    assert did['pop'], "DID should have a POP"
  end

  def test_phone_numbers_aliases_dids
    result = @api.phone_numbers
    assert_equal 'success', result['status']
    assert result['dids'].is_a?(Array)
  end

  def test_servers_returns_list
    result = @api.servers
    assert_equal 'success', result['status']
    assert result['servers'].is_a?(Array)
    assert result['servers'].any?
  end

  def test_server_has_expected_fields
    result = @api.servers
    server = result['servers'].first
    assert server['server_hostname'], "Server should have hostname"
    assert server['server_pop'], "Server should have POP"
  end

  def test_sub_accounts_returns_list
    result = @api.sub_accounts
    assert_equal 'success', result['status']
    assert result['accounts'].is_a?(Array)
  end
end
