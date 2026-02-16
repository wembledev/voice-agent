# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/audio_bridge'
require 'socket'
require 'tmpdir'

class AudioBridgeCodecTest < Minitest::Test
  # --- u-law encode/decode ---

  def test_silence_encodes_to_0xff
    assert_equal 0xFF, AudioBridge.linear_to_ulaw(0)
  end

  def test_silence_decodes_from_0xff
    assert_equal 0, AudioBridge.ulaw_to_linear(0xFF)
  end

  def test_positive_sample_roundtrip
    # u-law is lossy, but a roundtrip should be close
    original = 1000
    encoded = AudioBridge.linear_to_ulaw(original)
    decoded = AudioBridge.ulaw_to_linear(encoded)
    assert_in_delta original, decoded, 100, "Roundtrip should be within quantization error"
  end

  def test_negative_sample_roundtrip
    original = -1000
    encoded = AudioBridge.linear_to_ulaw(original)
    decoded = AudioBridge.ulaw_to_linear(encoded)
    assert_in_delta original, decoded, 100
  end

  def test_max_positive_clips
    encoded = AudioBridge.linear_to_ulaw(32767)
    decoded = AudioBridge.ulaw_to_linear(encoded)
    assert decoded > 30000, "Max positive should decode to near-max value"
  end

  def test_max_negative_clips
    encoded = AudioBridge.linear_to_ulaw(-32768)
    decoded = AudioBridge.ulaw_to_linear(encoded)
    assert decoded < -30000, "Max negative should decode to near-min value"
  end

  # --- batch conversion ---

  def test_s16le_to_pcmu_frame_size
    # 160 S16LE samples (320 bytes) → 160 PCMU bytes
    s16le = ([0] * 160).pack('s<*')
    pcmu = AudioBridge.s16le_to_pcmu(s16le)
    assert_equal 160, pcmu.bytesize
  end

  def test_pcmu_to_s16le_frame_size
    # 160 PCMU bytes → 160 S16LE samples (320 bytes)
    pcmu = ([0xFF] * 160).pack('C*')
    s16le = AudioBridge.pcmu_to_s16le(pcmu)
    assert_equal 320, s16le.bytesize
  end

  def test_silence_frame_roundtrip
    silence_s16le = ([0] * 160).pack('s<*')
    pcmu = AudioBridge.s16le_to_pcmu(silence_s16le)
    back = AudioBridge.pcmu_to_s16le(pcmu)

    samples = back.unpack('s<*')
    samples.each { |s| assert_equal 0, s, "Silence should survive roundtrip" }
  end

  def test_sine_wave_roundtrip_within_tolerance
    # Generate a 400 Hz sine wave at 8 kHz, 160 samples
    samples = (0...160).map { |i| (16000 * Math.sin(2 * Math::PI * 400 * i / 8000)).round }
    s16le = samples.pack('s<*')

    pcmu = AudioBridge.s16le_to_pcmu(s16le)
    back = AudioBridge.pcmu_to_s16le(pcmu)
    decoded = back.unpack('s<*')

    # u-law quantization error should be small relative to signal
    samples.each_with_index do |orig, i|
      delta = (orig - decoded[i]).abs
      max_err = [orig.abs / 8, 200].max  # ~12.5% or 200, whichever is larger
      assert delta <= max_err,
             "Sample #{i}: #{orig} -> #{decoded[i]} (delta #{delta}, max #{max_err})"
    end
  end
end

class AudioBridgeSocketTest < Minitest::Test
  def setup
    @sock_path = File.join(Dir.tmpdir, "ausock_test_#{$$}_#{rand(10000)}.sock")
    @server = UNIXServer.new(@sock_path)
    @agent = MockVoiceAgent.new
    @bridge = AudioBridge.new(@agent, socket_path: @sock_path)
  end

  def teardown
    @bridge.stop if @bridge.running?
    @server.close rescue nil
    File.delete(@sock_path) rescue nil
  end

  def test_start_connects_to_socket
    @bridge.start
    client = @server.accept
    assert client, "Bridge should connect to the socket"
    client.close
  end

  def test_read_thread_forwards_audio_to_agent
    @bridge.start
    client = @server.accept

    # Simulate caller audio: write one S16LE frame to the socket
    frame = ([1000] * AudioBridge::FRAME_SAMPLES).pack('s<*')
    client.write(frame)
    sleep 0.1

    assert @agent.audio_received.size > 0, "Agent should have received audio"
    pcmu = @agent.audio_received.first
    assert_equal AudioBridge::PCMU_BYTES, pcmu.bytesize
    client.close
  end

  def test_write_thread_sends_audio_to_socket
    @bridge.start
    client = @server.accept

    # Simulate Grok audio: enqueue PCMU for the caller
    pcmu = ([0xFF] * AudioBridge::PCMU_BYTES).pack('C*')
    @bridge.enqueue(pcmu)
    sleep 0.1

    data = client.read_nonblock(AudioBridge::FRAME_BYTES)
    assert_equal AudioBridge::FRAME_BYTES, data.bytesize
    client.close
  end

  def test_stop_cleans_up
    @bridge.start
    @server.accept
    @bridge.stop

    refute @bridge.running?
  end

  # Minimal mock that records send_audio calls
  class MockVoiceAgent
    attr_reader :audio_received

    def initialize
      @audio_received = []
    end

    def send_audio(data)
      @audio_received << data
    end
  end
end
