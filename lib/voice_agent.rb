# frozen_string_literal: true

# Base class for AI voice agent implementations
class VoiceAgent
  class Error < StandardError; end

  # Telephony audio defaults — subclasses can override via config
  CODEC        = 'PCMU'        # G.711 μ-law
  AUDIO_FORMAT = 'audio/pcmu'  # MIME type for realtime APIs
  SAMPLE_RATE  = 8000          # Hz

  def initialize(config = {})
    @config = config
    @codec       = config[:codec]       || self.class::CODEC
    @audio_format = config[:audio_format] || self.class::AUDIO_FORMAT
    @sample_rate = config[:sample_rate]  || self.class::SAMPLE_RATE
  end

  # Start a voice session (WebSocket connection)
  # @param on_audio [Proc] callback receiving audio chunks (binary G.711u)
  # @param on_text [Proc] callback receiving text transcripts
  def connect(**callbacks)
    raise Error, "#{self.class} must implement #connect"
  end

  # Send audio data to the agent
  # @param data [String] binary audio (G.711u)
  def send_audio(data)
    raise Error, "#{self.class} must implement #send_audio"
  end

  # Send text to the agent
  def send_text(text)
    raise Error, "#{self.class} must implement #send_text"
  end

  # Disconnect the session
  def disconnect
    raise Error, "#{self.class} must implement #disconnect"
  end

  # Is the session connected?
  def connected?
    false
  end
end
