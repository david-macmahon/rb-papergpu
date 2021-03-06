#!/usr/bin/env ruby

# paper_feng_init.rb - Script to initialize PAPER F engine(s)

require 'rubygems'
require 'optparse'
require 'ipaddr'
require 'papergpu/roach2_fengine'
require 'redis'
#require 'hashpipe/keys'
#
#include Hashpipe::RedisKeys


OPTS = {
  :ctmode    => 0,
  :eq        => Rational(600),
  :fftshift  => (1<<11)-1, # All 11 stages
  :redishost => 'redishost',
  :seed      => 0x11111111,
  :sync      => true,
  :noise     => false,
  :verbose   => false
}

OP = OptionParser.new do |op|
  op.program_name = File.basename($0)

  op.banner = "Usage: #{op.program_name} [OPTIONS] HOST[:FID] ..."
  op.separator('')
  op.separator('Initialize 32-input ROACH2 F Engine(s).')
  op.separator('If HOST is "pfN", then the ":FID" suffix can be omitted')
  op.separator('and FID will be N-1 (e.g. "pf1" will get FID=0).');
  op.separator('')
  op.separator('Options:')
  op.on('-e', '--eq=COEFF', Integer,
        "Specify FFT shift schedule [#{OPTS[:eq]}]") do |o|
    OPTS[:eq] = Rational((128*Rational(o)).round, 128)
  end
  op.on('-f', '--fftshift=SHIFTVAL', Integer,
        "Specify FFT shift schedule [#{OPTS[:fftshift]}]") do |o|
    OPTS[:fftshift] = o
  end
  op.on('-m', '--mode=CTMODE', Integer,
        "Specify corner turner mode [#{OPTS[:ctmode]}]") do |o|
    OPTS[:ctmode] = o
  end
  op.on('-r', '--redishost=NAME',
        "Host running redis-server [#{OPTS[:redishost]}]") do |o|
    OPTS[:redishost] = o
  end
  op.on('-s', '--no-sync', "Arm sync generator [#{OPTS[:sync]}]") do |o|
    OPTS[:sync] = o
  end
  op.on('-n', '--noise', "Use digital noise generators [#{OPTS[:noise]}]") do |o|
    OPTS[:noise] = o
  end
  op.on('-v', '--[no-]verbose', "Be verbose [#{OPTS[:verbose]}]") do |o|
    OPTS[:verbose] = o
  end
  op.separator('')
  op.on_tail('-h','--help','Show this message') do
    puts op.help
    exit
  end
end
OP.parse!
#p OPTS; exit

if ARGV.empty?
  puts OP.help
  exit
end

# String representation of ctmodes
CTMODES = [
  '8 F engines', # ctmode 0
  '4 F engines', # ctmode 1
  '2 F engines', # ctmode 2
  '1 F engine'   # ctmode 3
]

# Parse host and FIDs from command line arguments
host_fids = ARGV.map do |hf|
  host, fid = hf.split(':')
  if fid
    # Use given FID
    fid = Integer(fid)
  else
    # Parse fid from pfN host
    fid = $1 if host =~ /^pf(\d+)$/
    if fid.nil?
      puts "Cannot determine FID from '#{hf}'"
      exit 1
    end
    fid = Integer(fid) - 1
  end
  puts "initializing #{host} as FID #{fid}"
  [host, fid]
end

# Create list of FIDs
fids = host_fids.map {|host, fid| fid}

# Create Roach2Fengine objects
fe_fids = host_fids.map do |host, fid|
  puts "connecting to #{host}"
  fe = Paper::Roach2Fengine.new(host) rescue nil
  return nil unless fe
  # Verify that device is already programmed
  if ! fe.programmed?
    puts "error: #{host} is not programmed"
    return nil
  end
  # Verify that given design appears to be the roach2_fengine
  if ! fe.listdev.grep('eth_0_xip').any?
    puts "error: #{host} is not programmed with an roach2_fengine design."
    return nil
  end
  # Display RCS revision info
  rcs = fe.rcs
  if rcs[:app].has_key? :rev
    app_rev = rcs[:app][:rev]
    lib_rev = rcs[:lib][:rev]
    puts "#{host} roach2_fengine app/lib revision #{app_rev}/#{lib_rev}"
  end
  [fe, fid]
end

# Compact fe_fids (remove nils) in case any errors were encountered
fe_fids.compact!

# Disable network transmission
puts "disabling network transmission"
fe_fids.each do |fe, fid|
  puts "  disabling #{fe.host} network transmission" if OPTS[:verbose]
  fe.eth_sw_en = 0
  fe.eth_gpu_en = 0
end

# Set FID registers
fe_fids.each do |fe, fid|
  puts "setting #{fe.host} FID to #{fid}"
  fe.fid = fid
end

# Set FFT shift
puts "setting fftshift to #{OPTS[:fftshift]}"
fe_fids.each do |fe, fid|
  fe.fft_shift = OPTS[:fftshift]
end

# Set EQ
puts "setting eq to #{OPTS[:eq]}"
eq = NArray.int(2048).add!(128*OPTS[:eq])
fe_fids.each do |fe, fid|
  16.times do |i|
    bram = fe.send("eq_#{i}_coeffs")
    bram[0] = eq
  end
end

# Setup details ofr 10 GbE cores
sw_mac_base = 0x0202_0a0a_0a00
sw_ip_base  =      0x0a0a_0a00

sw_arp_table = NArray.int(2,256).indgen!.div!(2).add!(sw_mac_base&0xffff_ffff)
sw_arp_table[0,nil] = (sw_mac_base >> 32)

gpu_mac_base = 0x0202_c0a8_0000
gpu_ip_base  =      0x0a0a_0000

puts "configuring 10 GbE interfaces"
fe_fids.each do |fe, fid|
  # Setup switch 10 GbE cores
  4.times do |i|
    puts "  configuring #{fe.host}:eth_#{i}_sw" if OPTS[:verbose]
    eth_sw = fe.send("eth_#{i}_sw")
    # IP
    ip = sw_ip_base + 32 + 8*i + fid
    printf("    IP  %s\n", IPAddr.new(ip, Socket::AF_INET)) if OPTS[:verbose]
    eth_sw.ip = ip
    # MAC
    mac = sw_mac_base + 32 + 8*i + fid
    printf("    MAC %s\n", ('%012x'%mac).scan(/../).join(':')) if OPTS[:verbose]
    eth_sw.mac = mac
    # Populate ARP table
    puts "    ARP table" if OPTS[:verbose]
    eth_sw.set(0x0c00, sw_arp_table)
  end

  # Setup gpu 10 GbE cores and xip registers
  4.times do |i|
    puts "  configuring #{fe.host}:eth_#{i}_gpu" if OPTS[:verbose]
    eth_gpu = fe.send("eth_#{i}_gpu")

    # IP
    ip = gpu_ip_base + 512 + 256*i + fid + 1
    printf("    IP  %s\n", IPAddr.new(ip, Socket::AF_INET)) if OPTS[:verbose]
    eth_gpu.ip = ip
    # MAC
    mac = gpu_mac_base + 512 + 256*i + fid + 1
    printf("    MAC %s\n", ('%012x'%mac).scan(/../).join(':')) if OPTS[:verbose]
    eth_gpu.mac = mac
    ## Populate ARP table
    #puts "  ARP table" if OPTS[:verbose]
    #eth_sw.set(0x0c00, sw_arp_table)

    # X engine is hostname "px#{fid-1}-#{i+2}"
    # (e.g. for FID 0, eth_0_gpu is connected to "px1-2"
    xip = IPAddr.new(Addrinfo.ip("px#{fid+1}-#{i+2}").ip_address)
    printf("    XIP %s\n", xip) if OPTS[:verbose]
    fe.send("eth_#{i}_xip=", xip.to_i)
  end
end

# Set ctmode
modestr = CTMODES[OPTS[:ctmode]]
puts "setting corner turner mode #{OPTS[:ctmode]} (#{modestr})"
fe_fids.each do |fe, fid|
  puts "  setting #{fe.host} corner turner mode #{OPTS[:ctmode]} (#{modestr})" if OPTS[:verbose]
  fe.ctmode = OPTS[:ctmode]
end

# Arm sync generator
if OPTS[:sync]
  # Some strange FPGA-side issue means that the first sync sometimes
  # leaves a subset of f-engine boards 1 packet out of sync
  # with the others. Sync twice here, as an empirically tested workaround
  fe0 = fe_fids[0][0]
  # We are potentially doing a batch of F engines so we want to get the arm
  # signals delivered to all F engines as close as possible.  Because of this,
  # we perform the arming "manually" rather than using the #arm_sync method on
  # each F engine.
  fe_fids.each {|fe, fid| fe.wordwrite(:sync_arm, 0)}
  sync_time = 0
  2.times do
    puts "arming sync generator(s)"
    # BEGIN WORKAROUND
    #  This code would work if the 1 PPS signal were sync'd to real time (e.g. via
    #  GPS), but in the basement of Evans Hall that is not the case.  So we loop on
    #  the first F engine until its sync_count counter increments.
    #  # Sleep until just after top of next second
    #  sleep(1.1 - (Time.now.to_f % 1))
    sync_count = fe0.sync_count
    true while fe0.sync_count == sync_count
    # END WORKAROUND
    # Arm all the F engines
    fe_fids.each {|fe, fid| fe.wordwrite(:sync_arm, 1)}
    fe_fids.each {|fe, fid| fe.wordwrite(:sync_arm, 0)}
    # Compute sync time
    sync_time = Time.now.to_i + 1
    # Sleep 1 second to wait for sync
    sleep 1
  end
  # Store sync time in redis
  puts "storing sync time in redis on #{OPTS[:redishost]}"
  redis = Redis.new(:host => OPTS[:redishost])
  redis['roachf_init_time'] = sync_time

  puts "seeding noise generators"
  fe_fids.each do |fe, fid|
    fe.seed_0 = OPTS[:seed]
    fe.seed_1 = OPTS[:seed]
    fe.seed_2 = OPTS[:seed]
    fe.seed_3 = OPTS[:seed]
  end

  puts "arming noise generator(s)"
  sync_count = fe0.sync_count
  true while fe0.sync_count == sync_count
  fe_fids.each {|fe, fid| fe.arm_noise}
end

if OPTS[:noise]
  puts "Setting F-Engine inputs to digital noise generators"
  fe_fids.each do |fe, fid|
    fe.insel(:n0 => 0..31)
  end
else
  puts "Setting F-Engine inputs to ADC signals"
  fe_fids.each do |fe, fid|
    fe.insel(:adc => 0..31)
  end
end

# Reset network cores
puts "resetting network interfaces"
fe_fids.each do |fe, fid|
  puts "  resetting #{fe.host} network interfaces" if OPTS[:verbose]
  [0, 1, 0].each do |v|
    fe.eth_cnt_rst = v
    fe.eth_gpu_rst = v
    fe.eth_sw_rst = v
  end
end

# Enable network transmission
puts "enable transmission to X engines"
fe_fids.each do |fe, fid|
  puts "  enable #{fe.host} transmission to X engines" if OPTS[:verbose]
  fe.eth_gpu_en = 1
end

puts "enable transmission to switch"
fe_fids.each do |fe, fid|
  puts "  enable #{fe.host} transmission to switch" if OPTS[:verbose]
  fe.eth_sw_en = 1
end

puts 'all done'
