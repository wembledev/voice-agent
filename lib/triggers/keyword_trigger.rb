# frozen_string_literal: true

require_relative '../trigger'

# Detects keywords in transcripts and fires an action.
#
# Example: Detect farewell phrases to trigger hangup.
#
# Usage:
#   trigger = KeywordTrigger.new(
#     patterns: /\b(goodbye|bye|see you)\b/i,
#     action: :hangup,
#     role: :user  # Only check user transcripts
#   )
#
#   trigger.check(transcript: "Goodbye!", role: :user)
#   # => :hangup
#
#   trigger.check(transcript: "Goodbye!", role: :assistant)
#   # => nil (wrong role)
#
class KeywordTrigger < Trigger
  # Default farewell patterns (matches garbo-phone)
  FAREWELL_PATTERNS = /\b(goodbye|good bye|bye bye|bye|see you|talk to you later|gotta go|got to go|take care|later|have a good one|catch you later|see ya|peace out)\b/i

  attr_reader :patterns, :role, :matched

  # @param config [Hash]
  # @option config [Regexp, String, Array<String>] :patterns keyword patterns
  # @option config [Symbol] :action action to fire
  # @option config [Symbol] :role (:user, :assistant, nil) which role to check
  # @option config [Boolean] :once (true) only fire once per call
  def initialize(config = {})
    super
    @patterns = build_pattern(config[:patterns] || FAREWELL_PATTERNS)
    @role = config.key?(:role) ? config[:role] : :user
    @once = config.fetch(:once, true)
    @matched = nil
  end

  def check(context)
    return nil unless enabled?
    
    transcript = context[:transcript]
    return nil if transcript.nil? || transcript.empty?
    
    # Check role filter
    if @role && context[:role] && context[:role] != @role
      return nil
    end
    
    # Check pattern
    match = transcript.match(@patterns)
    return nil unless match
    
    @matched = match[0]
    @action
  end

  def once?
    @once
  end

  def name
    'keyword'
  end

  private

  def build_pattern(input)
    case input
    when Regexp
      input
    when String
      /\b#{Regexp.escape(input)}\b/i
    when Array
      words = input.map { |w| Regexp.escape(w) }.join('|')
      /\b(#{words})\b/i
    else
      raise Trigger::Error, "Invalid pattern type: #{input.class}"
    end
  end
end
