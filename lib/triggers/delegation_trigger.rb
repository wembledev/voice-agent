# frozen_string_literal: true

require_relative '../trigger'
require 'json'

# Fires when the voice agent calls a classification tool.
#
# Used for AI-classified delegation: the voice agent decides when a caller's
# request should be forwarded to another AI assistant for processing.
#
# Usage:
#   trigger = DelegationTrigger.new(tool: 'classify_intent', action: :delegate)
#
#   trigger.check(
#     tool_name: 'classify_intent',
#     tool_arguments: '{"intent":"send_text","request":"send a text to mom"}',
#     tool_call_id: 'call_123'
#   )
#   # => :delegate
#
#   trigger.payload
#   # => { "intent" => "send_text", "request" => "send a text to mom" }
#
class DelegationTrigger < Trigger
  attr_reader :tool, :payload, :call_id

  # @param config [Hash]
  # @option config [String] :tool tool name to match (default: 'classify_intent')
  # @option config [Symbol] :action action to fire (:delegate by default)
  def initialize(config = {})
    super(config.merge(action: config[:action] || :delegate))
    @tool = config[:tool] || 'classify_intent'
    @payload = nil
    @call_id = nil
  end

  def check(context)
    return nil unless enabled?

    tool_name = context[:tool_name]
    return nil unless tool_name == @tool

    @call_id = context[:tool_call_id]
    args = context[:tool_arguments]

    @payload = case args
    when String
      begin
        JSON.parse(args)
      rescue JSON::ParserError
        { 'raw' => args }
      end
    when Hash then args
    else {}
    end

    @action
  end

  def once?
    false  # Can delegate multiple times per call
  end

  def name
    'delegation'
  end
end
