# frozen_string_literal: true

# Base class for call control triggers.
#
# Triggers detect conditions in voice call context and return actions.
# Subclasses implement #check to analyze transcripts, timing, etc.
#
# Usage:
#   trigger = KeywordTrigger.new(patterns: /goodbye/i, action: :hangup)
#   action = trigger.check(transcript: "Goodbye!", role: :user)
#   # => :hangup
#
class Trigger
  class Error < StandardError; end

  # @return [Symbol] the action this trigger produces when fired
  attr_reader :action

  # @return [Boolean] whether this trigger is enabled
  attr_reader :enabled

  # @param config [Hash] trigger configuration
  # @option config [Symbol] :action action to return when triggered
  # @option config [Boolean] :enabled (true) whether trigger is active
  def initialize(config = {})
    @action = config[:action]
    @enabled = config.fetch(:enabled, true)
  end

  # Check if trigger condition is met.
  #
  # @param context [Hash] current call context
  # @option context [String] :transcript latest transcript text
  # @option context [Symbol] :role (:user or :assistant) who spoke
  # @option context [Time] :last_speech_at when user last spoke
  # @option context [Time] :last_response_at when AI finished responding
  # @option context [Boolean] :is_speaking whether AI is currently speaking
  #
  # @return [Symbol, nil] action to take, or nil if not triggered
  def check(context)
    raise Error, "#{self.class} must implement #check"
  end

  # Human-readable trigger name
  def name
    self.class.name.gsub(/Trigger$/, '').downcase
  end

  def enabled?
    @enabled
  end

  def disable!
    @enabled = false
  end

  def enable!
    @enabled = true
  end
end
