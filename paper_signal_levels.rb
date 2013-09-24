#!/usr/bin/env ruby

# This script tests the signal levels going into the roach.

require 'optparse'
require 'ostruct'
require './quantgain'

OPTS = OpenStruct.new
OPTS.in_rms = 16
OPTS.nshift = 12
OPTS.eq = 1500

OptionParser.new do |op|
  op.program_name = File.basename($0)

  op.banner = "Usage: #{op.program_name} [OPTIONS]"
  op.separator('')
  op.separator('Compute PAPER F engine output levels.')
  op.separator('')
  #op.on('-q', '--quant', dest='quantize', default=4, type='int',help='How many bits to quantize to. ')
  op.on('-i', '--in-rms=RMS', Float, "RMS value of input signal [#{OPTS.in_rms}]") do |o|
    OPTS.in_rms = o
  end
  op.on('-f', '--fft=NSHIFT', Integer, "Number of shifts in the fft [#{OPTS.nshift}]") do |o|
    OPTS.nshift = o
  end
  op.on('-e', '--eq=COEF', Float, "Equalizer coefficient [#{OPTS.eq}]") do |o|
    OPTS.eq = (128*o).round / 128.0
  end
  op.on_tail('-h','--help','Show this message') do
    puts op.help
    exit
  end
end.parse!

NSTAGES = 12

pf_rms, fft_rms, reim_rms, eq_rms, quant_rms = paper_levels(OPTS.in_rms, NSTAGES, (1<<OPTS.nshift)-1, OPTS.eq)

printf "ADC   output RMS %8.4f counts\n", OPTS.in_rms
printf "PFB   output RMS %f\n", pf_rms
printf "FFT   output RMS %f\n", fft_rms
printf "ReIm  output RMS %f\n", reim_rms
printf "EQ    output RMS %f\n", eq_rms
printf "QUANT output RMS %f\n", quant_rms
printf "AUTOCORRELATION  %f\n", quant_rms**2 * 2
