require 'max31865/version'
require 'pi_piper'

#
# MAX31865
#
class MAX31865
  attr_accessor :chip, :type, :clock

  # Thermocouple Temperature Data Resolution
  TC_RES = 0.0078125
  # Cold-Junction Temperature Data Resolution
  CJ_RES = 0.015625

  # Read registers
  REG_CJ    = 0x08 # Cold Junction status register
  REG_TC    = 0x0c # Thermocouple status register
  REG_FAULT = 0x0F # Fault status register

  #
  # Config Register 1
  # ------------------
  # bit 7: Conversion Mode                         -> 1 (Normally Off Mode)
  # bit 6: 1-shot                                  -> 0 (off)
  # bit 5: open-circuit fault detection            -> 0 (off)
  # bit 4: open-circuit fault detection type k     -> 1 (on)
  # bit 3: Cold-junction sensor disabled           -> 0 (default)
  # bit 2: Fault Mode                              -> 0 (default)
  # bit 1: fault status clear                      -> 1 (clear any fault)
  # bit 0: 50/60 Hz filter select                  -> 0 (60Hz)
  #
  REG_1 = [0x00, 0b10010010].freeze

  #
  # Config Register 2
  # ------------------
  # bit 7: Reserved                                -> 0
  # bit 6: Averaging Mode 1 Sample                 -> 0 (default)
  # bit 5: Averaging Mode 1 Sample                 -> 0 (default)
  # bit 4: Averaging Mode 1 Sample                 -> 0 (default)
  # bit 3: Thermocouple Type -> K Type (default)   -> 0 (default)
  # bit 2: Thermocouple Type -> K Type (default)   -> 0 (default)
  # bit 1: Thermocouple Type -> K Type (default)   -> 1 (default)
  # bit 0: Thermocouple Type -> K Type (default)   -> 1 (default)
  #
  REG_2 = 0x01

  #
  # Config Register 2
  # ------------------
  # bit 7: Nil
  # bit 6: Nil
  # bit 5: Cold-Junction High Fault Threshold              -> 0 (default)
  # bit 4: Cold-Junction Low Fault Threshold               -> 0 (default)
  # bit 3: Thermocouple Temperature High Fault Threshold   -> 0 (default)
  # bit 2: Thermocouple Temperature Low Fault Threshold    -> 0 (default)
  # bit 1: Over-voltage or Undervoltage Input Fault        -> 1 (default)
  # bit 0: Thermocouple Open-Circuit Fault                 -> 1 (default)
  #
  REG_3 = [0x02, 0b11111100].freeze

  TYPES = {
    b: 0x00,
    e: 0x01,
    j: 0x02,
    k: 0x03,
    n: 0x04,
    r: 0x05,
    s: 0x06,
    t: 0x07
  }.freeze

  CHIPS = {
    0 => PiPiper::Spi::CHIP_SELECT_0,
    1 => PiPiper::Spi::CHIP_SELECT_1,
    2 => PiPiper::Spi::CHIP_SELECT_BOTH,
    3 => PiPiper::Spi::CHIP_SELECT_NONE
  }.freeze

  FAULTS = {
    0x80 => 'Cold Junction Out-of-Range',
    0x40 => 'Thermocouple Out-of-Range',
    0x20 => 'Cold-Junction High Fault',
    0x10 => 'Cold-Junction Low Fault',
    0x08 => 'Thermocouple Temperature High Fault',
    0x04 => 'Thermocouple Temperature Low Fault',
    0x02 => 'Overvoltage or Undervoltage Input Fault',
    0x01 => 'Thermocouple Open-Circuit Fault'
  }.freeze

  def initialize(type = :k, chip = 0, clock = 2_000_000)
    @type = TYPES[type]
    @chip = CHIPS[chip]
    @clock = clock
  end

  def spi_work
    PiPiper::Spi.begin do |spi|
      # Set cpol, cpha
      PiPiper::Spi.set_mode(0, 1)

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
  # CR1_AVERAGE_1_SAMPLE                    0x00
  # CR1_AVERAGE_2_SAMPLES                   0x10
  # CR1_AVERAGE_4_SAMPLES                   0x20
  # CR1_AVERAGE_8_SAMPLES                   0x30
  # CR1_AVERAGE_16_SAMPLES                  0x40
  #
  # define CR1_VOLTAGE_MODE_GAIN_8                 0x08
  # define CR1_VOLTAGE_MODE_GAIN_32                0x0C
  #
  # Optionally set samples
  def config(samples = 0x10)
    spi_work do |spi|
      spi.write(write_reg(REG_1))
      spi.write(write_reg([REG_2, (samples | type)]))
      spi.write(write_reg(REG_3))
    end
    sleep 0.2 # give it 200ms for conversion
  end

  # Set 0x80 on first for writes
  def write_reg(ary)
    ary[1..-1].unshift(ary[0] | 0x80)
  end

  #
  # Read both
  #
  def read
    tc = cj = 0
    spi_work do |spi|
      cj = read_cj(spi.write(Array.new(4, 0xff).unshift(REG_CJ)))
      sleep 0.2
      tc = read_tc(spi.write(Array.new(4, 0xff).unshift(REG_TC)))
    end
    [tc, cj]
  end

  #
  # Read cold-junction
  #
  def read_cj(raw)
    lb, mb, _offset = raw.reverse # Offset already on sum
    # MSB << 8 | LSB and remove last 2
    temp = ((mb << 8) | lb) >> 2

    # Handle negative
    temp -= 0x4000 unless (mb & 0x80).zero?

    # Convert to Celsius
    temp * CJ_RES
  end

  #
  # Read thermocouple
  #
  def read_tc(raw)
    fault, lb, mb, hb = raw.reverse
    FAULTS.each do |f, txt|
      raise txt if fault & f == 1
    end
    # MSB << 8 | LSB and remove last 5
    temp = ((hb << 16) | (mb << 8) | lb) >> 5

    # Handle negative
    temp -= 0x80000 unless (hb & 0x80).zero?

    # Convert to Celsius
    temp * TC_RES
  end

  # Read register faults
  def read_fault
    spi_work do |spi|
      fault = spi.write(REG_FAULT, 0xff)
      p [fault, fault.last.to_s(2).rjust(8, '0')]
    end
  end
end
