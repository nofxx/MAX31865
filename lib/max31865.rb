require 'max31865/version'
require 'pi_piper'

#
# MAX31865
#
# Thanks to https://github.com/steve71/MAX31865/blob/master/max31865.py
# https://github.com/hackenbergstefan/MAX31865/blob/master/max31865.py
class MAX31865
  attr_accessor :chip, :clock, :type, :ref, :wires, :hz

  # Resistance at 0 degC for 400ohm R_Ref
  R0 = 100.0

  # Constants for Callendar-Van-Dusen equation
  A = 0.00390830
  B = -0.000000577500
  # C = -4.18301e-12 # for -200 <= T <= 0 (degC)
  C = -0.00000000000418301
  # C = 0 # for 0 <= T <= 850 (degC)

  CHIPS = {
    0 => PiPiper::Spi::CHIP_SELECT_0,
    1 => PiPiper::Spi::CHIP_SELECT_1,
    2 => PiPiper::Spi::CHIP_SELECT_BOTH,
    3 => PiPiper::Spi::CHIP_SELECT_NONE
  }.freeze

  FAULTS = {
    0x80 => 'High threshold limit (Cable fault/open)',
    0x40 => 'Low threshold limit (Cable fault/short)',
    0x04 => 'Overvoltage or Undervoltage Error',
    0xff => 'Circuit Fault'
  }.freeze

  def initialize(chip: 0, ref: 430.0, clock: 2_000_000)
    @chip  = CHIPS[chip]
    @ref   = ref
    @clock = clock
  end

  def spi_work
    PiPiper::Spi.begin do |spi|
      # Set cpol, cpha
      PiPiper::Spi.set_mode(1, 1)

      # Setup the chip select behavior
      spi.chip_select_active_low(true)

      # Set the bit order to MSB
      spi.bit_order PiPiper::Spi::MSBFIRST

      # Set the clock divider to get a clock speed of 2MHz
      spi.clock clock

      spi.chip_select(chip) do
        yield spi
      end
    end
  end

  #
  # Run once config
  #
  #
  # Optionally set samples
  #
  # 0x8x to specify 'write register value'
  # 0xx0 to specify 'configuration register'
  #
  #
  # Config Register
  # ---------------
  # bit 7  : Vbias -> 1 (ON)
  # bit 6  : Conversion Mode -> 0 (MANUAL)
  # bit 5  : 1-shot ->1 (ON)
  # bit 4  : 3-wire select -> 1 (3 wire config)
  # bit 3-2: fault detection cycle -> 0 (none)
  # bit 1  : fault status clear -> 1 (clear any fault)
  # bit 0  : 50/60 Hz filter select -> 0 (60Hz)
  #
  # 0b11010010 or 0xD2 for continuous auto conversion
  # at 60Hz (faster conversion)
  # 0b10110010 = 0xB2
  def config(byte = 0b11010010)
    spi_work do |spi|
      spi.write(0x80, byte)
    end
    sleep 0.2 # give it 200ms for conversion
  end

  #
  # Read temperature!
  #
  def read
    spi_work do |spi|
      read_temp(spi.write(Array.new(8, 0x01)))
    end
  end

  private

  #
  # Callendar-Van Dusen equations
  #
  # Convert 0 <= raw_temp < 2^l5 to temperature in oC using quadratic polynom:
  #
  #  R(T)=R(0)(1+A*T+B*T^{2})
  #
  # => T = (-A*R(0) + sqrt(A^2 R(0)^2 - 4*B*R(0)*(R(0) - R(T)))) / (2*B*R(0))
  #
  # quadratic formula:
  # for 0 <= T <= 850 (degC)
  #
  def quadratic(adc, rtd)
    temp = -(A * R0)
    temp += Math.sqrt(A * A * R0 * R0 - 4 * B * R0 * (R0 - rtd))
    temp /= 2 * B * R0
    # puts "Callendar-Van Dusen Temp (degC > 0): #{temp}C"
    temp < 0 ? (adc / 32) - 256 : temp
  end

  # """
  # Convert 0 <= raw_temp < 2^15 to temperature in oC using quartic polynom:
  #
  #  R(T) = R(0)[1+A*T+B*T^{2}+(T-100)C*T^{3}]
  #
  # => 0 = R(0)[1 + A*T + B*T^2 - 100*C*T^3 + C*T^4] - R(T)
  #
  # Solution is calculated numerically.
  #
  def quartic(rtd)
    temp = rtd * R0 / (2**15 - 1)
    roots = [C * R0, -100 * R0 * C, B * R0, A * R0, R0 - temp]
            .map { |n| Math.sqrt(n) }
    Math.abs(roots[-1])
  end

  #
  # Read temperature
  #
  def read_temp(raw)
    read_fault(raw[7])
    rtd_msb, rtd_lsb = raw[1], raw[2]
    adc = ((rtd_msb << 8) | rtd_lsb) >> 1
    # puts "RTD ADC Code: #{adc}"
    # temp_line = (adc / 32.0) - 256.0
    # puts "Straight Line Approx. Temp: #{temp_line}C"
    rtd = (adc * ref) / 32_768.0 # PT100 Resistance
    # puts "PT100 Resistance: #{rtd} ohms"
    quadratic(adc, rtd)
  end

  #
  # Read register faults
  #
  # 10 Mohm resistor is on breakout board to help detect cable faults
  #
  # bit 7: RTD High Threshold / cable fault open
  # bit 6: RTD Low Threshold / cable fault short
  # bit 5: REFIN- > 0.85 x VBias -> must be requested
  # bit 4: REFIN- < 0.85 x VBias (FORCE- open) -> must be requested
  # bit 3: RTDIN- < 0.85 x VBias (FORCE- open) -> must be requested
  # bit 2: Overvoltage / undervoltage fault
  # bits 1,0 don't care
  # print "Status byte: #{status}"
  #
  def read_fault(byte)
    FAULTS.each do |code, fault|
      raise fault if byte & code == 1
    end
  end
end
