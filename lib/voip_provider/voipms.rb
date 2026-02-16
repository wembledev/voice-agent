# frozen_string_literal: true

require_relative '../voip_provider'
require 'net/http'
require 'json'
require 'uri'

class VoipProvider
  class Voipms < VoipProvider
    BASE_URL = 'https://voip.ms/api/v1/rest.php'

    def initialize(config = {})
      super
      load_voipms_config
    end

    def call(method, params = {})
      params = params.merge(
        api_username: @username,
        api_password: @password,
        method: method,
        content_type: 'json'
      )
      uri = URI(BASE_URL)
      uri.query = URI.encode_www_form(params)
      response = Net::HTTP.get_response(uri)
      JSON.parse(response.body)
    end

    def balance;       call('getBalance'); end
    def dids;          call('getDIDsInfo'); end
    def did_info(did); call('getDIDInfo', did: did); end
    def pops;          call('getPOPs'); end

    alias phone_numbers dids

    def registrations(account = nil)
      params = {}
      params[:account] = account if account
      call('getRegistrationStatus', params)
    end

    def sub_accounts(main_account = nil)
      params = {}
      params[:account] = main_account if main_account
      call('getSubAccounts', params)
    end

    def allowed_codecs(account)
      call('getAllowedCodecs', account: account)
    end

    def servers(location = nil)
      params = {}
      params[:server_pop] = location if location
      call('getServersInfo', params)
    end

    def set_sub_account(account_id, params = {})
      call('setSubAccount', params.merge(id: account_id))
    end

    private

    def load_voipms_config
      @username = @config[:username] || ENV['VOIPMS_API_USERNAME'] || raise(Error, 'VOIPMS_API_USERNAME not set')
      @password = @config[:password] || ENV['VOIPMS_API_PASSWORD'] || raise(Error, 'VOIPMS_API_PASSWORD not set')
    end
  end
end
