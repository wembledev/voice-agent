# frozen_string_literal: true

require_relative '../voice_agent'
require 'websocket-client-simple'
require 'json'
require 'base64'

class VoiceAgent
  class Grok < VoiceAgent
    REALTIME_URL = 'wss://api.x.ai/v1/realtime'

    CLASSIFY_INTENT_TOOL = {
      type: 'function',
      name: 'classify_intent',
      description: 'Classify the caller\'s intent when they make a request that needs action beyond conversation. ' \
                   'IMPORTANT: Always briefly acknowledge the request out loud before calling this tool ' \
                   '(e.g., "Let me look into that for you" or "One moment while I check"). ' \
                   'Call this when the caller asks you to do something like send a message, set a reminder, look something up, etc.',
      parameters: {
        type: 'object',
        properties: {
          intent: {
            type: 'string',
            description: 'Short intent label (e.g., send_text, set_reminder, check_weather, lookup_info)'
          },
          request: {
            type: 'string',
            description: 'The full natural language request from the caller'
          }
        },
        required: ['intent', 'request']
      }
    }.freeze

    def initialize(config = {})
      super
      load_config
      @ws = nil
      @connected = false
      @callbacks = {}
      @tools = config[:tools] || []
      @verbose = config[:verbose] || false
    end

    # Connect to Grok Realtime API
    # Callbacks: on_ready, on_audio, on_text, on_transcript, on_error, on_close
    def connect(**callbacks)
      @callbacks = callbacks

      url = REALTIME_URL
      headers = {
        'Authorization' => "Bearer #{@api_key}",
        'Content-Type' => 'application/json'
      }

      @ws = WebSocket::Client::Simple.connect(url, headers: headers)
      agent = self

      @ws.on :open do
        agent.send(:on_open)
      end

      @ws.on :message do |msg|
        agent.send(:on_message, msg)
      end

      @ws.on :error do |e|
        agent.send(:on_error_event, e)
      end

      @ws.on :close do |e|
        agent.send(:on_close_event, e)
      end

      self
    end

    # Send audio chunk (raw G.711μ bytes, will be base64 encoded)
    def send_audio(data)
      return unless @connected

      @ws.send(JSON.generate({
        type: 'input_audio_buffer.append',
        audio: Base64.strict_encode64(data)
      }))
    end

    # Send text input
    def send_text(text)
      return unless @connected

      @ws.send(JSON.generate({
        type: 'conversation.item.create',
        item: {
          type: 'message',
          role: 'user',
          content: [{ type: 'input_text', text: text }]
        }
      }))

      # Request a response with text + audio
      @ws.send(JSON.generate({
        type: 'response.create',
        response: {
          modalities: ['text', 'audio']
        }
      }))
    end

    # Send a tool result back to the agent
    def send_tool_result(call_id, output)
      unless @connected
        vlog "send_tool_result: NOT CONNECTED — dropping result for call_id=#{call_id}"
        return
      end

      output_str = output.to_s
      vlog "send_tool_result: call_id=#{call_id} output=#{output_str[0, 200].inspect} (#{output_str.bytesize}B)"

      @ws.send(JSON.generate({
        type: 'conversation.item.create',
        item: {
          type: 'function_call_output',
          call_id: call_id,
          output: output_str
        }
      }))
      vlog "send_tool_result: sent function_call_output"

      @ws.send(JSON.generate({
        type: 'response.create',
        response: {
          modalities: ['text', 'audio']
        }
      }))
      vlog "send_tool_result: sent response.create — agent should now speak the result"
    end

    # Request a response with custom instructions (no user message).
    # Used to prompt the agent to say something specific.
    def prompt_response(instructions)
      return unless @connected

      @ws.send(JSON.generate({
        type: 'response.create',
        response: {
          modalities: ['text', 'audio'],
          instructions: instructions
        }
      }))
    end

    def disconnect
      @connected = false
      @ws&.close
    rescue IOError, Errno::EPIPE
      # WebSocket already closed or broken pipe — safe to ignore
    end

    def connected?
      @connected
    end

    private

    def load_config
      @api_key = @config[:api_key] || ENV.fetch('XAI_API_KEY') { raise "XAI_API_KEY not set in environment" }
      @voice = @config[:voice] || 'Rex'
      @agent_name = @config[:agent_name] || 'Assistant'
    end

    def vlog(msg)
      return unless @verbose
      $stderr.puts "[grok] #{msg}"
    end

    def on_open
      @connected = true

      # Configure session for telephony audio (format from base class config)
      session = {
        voice: @voice,
        modalities: ['text', 'audio'],
        instructions: @config[:instructions] || "You are #{@agent_name}, a helpful AI voice assistant. Be concise and conversational.",
        turn_detection: { type: 'server_vad' },
        audio: {
          input:  { format: { type: @audio_format } },
          output: { format: { type: @audio_format } }
        }
      }
      session[:tools] = @tools if @tools.any?

      @ws.send(JSON.generate({
        type: 'session.update',
        session: session
      }))

      @callbacks[:on_ready]&.call
    end

    def on_message(msg)
      return if msg.data.nil? || msg.data.empty?

      begin
        event = JSON.parse(msg.data)
      rescue JSON::ParserError
        return
      end

      case event['type']
      when 'response.output_audio.delta'
        audio = Base64.decode64(event['delta'])
        @callbacks[:on_audio]&.call(audio)

      when 'response.output_audio_transcript.delta'
        @callbacks[:on_text]&.call(event['delta'])

      when 'response.output_audio_transcript.done'
        @callbacks[:on_transcript]&.call(event['transcript'])

      when 'response.done'
        @callbacks[:on_response_done]&.call(event)

      when 'input_audio_buffer.speech_started'
        @callbacks[:on_speech_started]&.call

      when 'input_audio_buffer.speech_stopped'
        @callbacks[:on_speech_stopped]&.call

      when 'conversation.item.input_audio_transcription.completed'
        @callbacks[:on_input_transcript]&.call(event['transcript'])

      when 'response.function_call_arguments.done'
        vlog "tool_call: name=#{event['name']} call_id=#{event['call_id']} args=#{event['arguments']&.[](0, 200)}"
        @callbacks[:on_tool_call]&.call(
          event['name'],
          event['arguments'],
          event['call_id']
        )

      when 'error'
        vlog "ws error: #{event['error'].inspect}"
        @callbacks[:on_error]&.call(event['error'])

      when 'session.created', 'session.updated', 'conversation.created'
        @callbacks[:on_session]&.call(event)
      end
    end

    def on_error_event(e)
      @callbacks[:on_error]&.call(e)
    end

    def on_close_event(_e)
      @connected = false
      @callbacks[:on_close]&.call
    end

  end
end
