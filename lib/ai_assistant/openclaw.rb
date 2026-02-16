# frozen_string_literal: true

require_relative '../ai_assistant'
require 'net/http'
require 'json'
require 'uri'

class AiAssistant
  class OpenClaw < AiAssistant
    def initialize(config = {})
      super
      load_config
      @messages = []
      @verbose = config[:verbose] || false
    end

    def configured?
      !@api_key.empty?
    end

    def name
      @name
    end

    def instructions
      @instructions
    end

    def chat(message)
      @messages << { role: 'user', content: message }

      response = api_call(@messages)
      reply = response.dig('choices', 0, 'message', 'content')
      @messages << { role: 'assistant', content: reply }
      reply
    end

    def sessions_send(intent:, request:)
      vlog "sessions_send: intent=#{intent} request=#{request.inspect}"
      reply = chat("[Delegation] Intent: #{intent}\nRequest: #{request}")
      vlog "sessions_send: reply=#{reply&.[](0, 200).inspect} (#{reply.to_s.bytesize}B)"
      reply
    end

    private

    def load_config
      @api_key = @config[:api_key] || ENV['OPENCLAW_API_KEY'] || ENV['OPENCLAW_GATEWAY_TOKEN'] || gateway_token || ''
      @api_url = @config[:api_url] || ENV['OPENCLAW_API_URL'] || 'http://127.0.0.1:18789/v1/chat/completions'
      @model = @config[:model] || ENV['OPENCLAW_MODEL'] || 'openclaw:main'
      @name = @config[:name] || 'OpenClaw'
      @instructions = @config[:instructions] || "You are #{@name}, a helpful AI assistant."
    end

    def api_call(messages)
      uri = URI(@api_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'

      request = Net::HTTP::Post.new(uri.path)
      request['Authorization'] = "Bearer #{@api_key}"
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate({
        model: @model,
        messages: [{ role: 'system', content: @instructions }] + messages
      })

      vlog "api_call: POST #{uri} model=#{@model} messages=#{messages.size}"
      response = http.request(request)
      vlog "api_call: HTTP #{response.code} (#{response.body.bytesize}B)"

      parsed = JSON.parse(response.body)
      unless response.code == '200'
        vlog "api_call: ERROR body=#{response.body[0, 300]}"
      end
      parsed
    end

    def vlog(msg)
      return unless @verbose
      $stderr.puts "[openclaw] #{msg}"
    end

    def gateway_token
      token = `openclaw config get gateway.auth.token 2>/dev/null`.strip
      token.empty? ? nil : token
    rescue Errno::ENOENT
      nil
    end

  end
end
