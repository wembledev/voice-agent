# frozen_string_literal: true

require 'dotenv'
Dotenv.load(File.expand_path('../.env.local', __dir__))

require 'minitest/autorun'
require 'minitest/reporters'

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
