# frozen_string_literal: true

require_relative '../trigger'

# Captures requests prefixed with a wake phrase and delegates to AI assistant.
#
# Example: "Hey Garbo, send a text to mom" → delegates "send a text to mom"
#
# Usage:
#   trigger = RequestCapture.new(
#     prefix: /hey\s+garbo[,.]?\s*/i,
#     action: :delegate
#   )
#   
#   trigger.check(transcript: "Hey Garbo, what's the weather?", role: :user)
#   # => :delegate
#   
#   trigger.payload
#   # => "what's the weather?"
#
class RequestCapture < Trigger
  # Default wake phrases
  DEFAULT_PREFIXES = [
    /hey\s+garbo[,.]?\s*/i,
    /garbo[,.]?\s+can\s+you\s*/i,
    /garbo[,.]?\s+please\s*/i,
    /garbo[,.]?\s*/i
  ]

  attr_reader :prefixes, :role, :payload

  # @param config [Hash]
  # @option config [Regexp, Array<Regexp>] :prefix wake phrase patterns
  # @option config [Symbol] :action action to fire (:delegate by default)
  # @option config [Symbol] :role which role to check (:user by default)
  def initialize(config = {})
    super(config.merge(action: config[:action] || :delegate))
    @prefixes = Array(config[:prefix] || config[:prefixes] || DEFAULT_PREFIXES)
    @role = config[:role] || :user
    @payload = nil
  end

  def check(context)
    return nil unless enabled?
    
    transcript = context[:transcript]
    return nil if transcript.nil? || transcript.empty?
    
    # Check role filter
    if @role && context[:role] && context[:role] != @role
      return nil
    end
    
    # Try each prefix
    @prefixes.each do |prefix|
      match = transcript.match(/\A#{prefix}(.+)/i)
      if match
        @payload = match[1].strip
        # Ignore if payload is empty or just punctuation
        next if @payload.empty? || @payload.match?(/\A[,.\s!?]+\z/)
        return @action
      end
    end
    
    nil
  end

  def once?
    false  # Can fire multiple times per call
  end

  def name
    'request'
  end

  # Get the captured request text
  def request_text
    @payload
  end
end
