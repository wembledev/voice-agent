# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# SMS client for garbo-voice-agent (uses voip.ms API)
class SMS
  class Error < StandardError; end

  def initialize(user:, password:, did:)
    @user = user
    @password = password
    @did = did
  end

  # Send SMS via voip.ms
  def send(to:, message:)
    # Normalize phone number
    to_clean = to.gsub(/[\s\-\+\(\)]/, '')

    uri = URI('https://voip.ms/api/v1/rest.php')
    params = {
      api_username: @user,
      api_password: @password,
      method: 'sendSMS',
      did: @did,
      dst: to_clean,
      message: message,
      content_type: 'json'
    }
    uri.query = URI.encode_www_form(params)

    response = Net::HTTP.get_response(uri)
    result = JSON.parse(response.body)

    unless result['status'] == 'success'
      raise Error, "SMS failed: #{result['status']} - #{result['message']}"
    end

    result
  end

  # Get recent SMS messages
  def get_recent(limit: 10, type: 1)
    uri = URI('https://voip.ms/api/v1/rest.php')
    params = {
      api_username: @user,
      api_password: @password,
      method: 'getSMS',
      did: @did,
      limit: limit,
      type: type, # 1=received, 2=sent
      content_type: 'json'
    }
    uri.query = URI.encode_www_form(params)

    response = Net::HTTP.get_response(uri)
    result = JSON.parse(response.body)

    unless result['status'] == 'success'
      raise Error, "getSMS failed: #{result['status']}"
    end

    result['sms'] || []
  end

  class << self
    # Create from environment variables
    def from_env
      new(
        user: ENV['VOIPMS_API_USERNAME'] || ENV['SIP_USERNAME'] || ENV['VOIPMS_USER'],
        password: ENV['VOIPMS_API_PASSWORD'] || ENV['SIP_PASSWORD'] || ENV['VOIPMS_PASSWORD'],
        did: ENV['VOIPMS_DID'] || '5550100'
      )
    end
  end
end
