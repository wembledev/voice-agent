# frozen_string_literal: true

require_relative '../trigger'

# Detects extended silence and fires an action.
#
# Silence is measured from when the AI *finished* speaking (not during).
# This prevents hanging up while the AI is talking.
#
# Usage:
#   trigger = SilenceTrigger.new(timeout: 10, action: :hangup)
#   
#   # Called periodically (e.g., every 2 seconds)
#   trigger.check(
#     last_response_at: Time.now - 15,  # AI finished 15s ago
#     is_speaking: false                 # AI not currently speaking
#   )
#   # => :hangup (silence exceeded 10s)
#
class SilenceTrigger < Trigger
  DEFAULT_TIMEOUT = 10  # seconds

  attr_reader :timeout, :silence_duration

  # @param config [Hash]
  # @option config [Integer, Float] :timeout seconds of silence before firing
  # @option config [Symbol] :action action to fire
  def initialize(config = {})
    super
    @timeout = config[:timeout] || DEFAULT_TIMEOUT
    @silence_duration = 0
  end

  def check(context)
    return nil unless enabled?
    
    # Don't trigger during AI speech
    if context[:is_speaking]
      @silence_duration = 0
      return nil
    end
    
    # Need a reference point (when AI finished speaking)
    last_response_at = context[:last_response_at]
    return nil unless last_response_at
    
    # Calculate silence duration
    @silence_duration = Time.now - last_response_at
    
    # Check if exceeded timeout
    return nil unless @silence_duration > @timeout
    
    @action
  end

  def once?
    true  # Only fire once (then call ends)
  end

  def name
    'silence'
  end

  # Remaining time before timeout
  def remaining
    [@timeout - @silence_duration, 0].max
  end

  # Reset the silence timer (e.g., when user speaks)
  def reset!
    @silence_duration = 0
  end
end
