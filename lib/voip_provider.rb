# frozen_string_literal: true

# Base class for VoIP provider implementations
class VoipProvider
  class Error < StandardError; end
  class NotImplementedError < Error; end

  def initialize(config = {})
    @config = config
  end

  # Account balance
  def balance
    raise NotImplementedError, "#{self.class} must implement #balance"
  end

  # List phone numbers (DIDs)
  def phone_numbers
    raise NotImplementedError, "#{self.class} must implement #phone_numbers"
  end

  # SIP registration status
  def registrations
    raise NotImplementedError, "#{self.class} must implement #registrations"
  end
end
