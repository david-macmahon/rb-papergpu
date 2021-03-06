#!/usr/bin/env ruby

# paper_ctl.rb - Script to control PAPER correlator (basically start/stop
#                integrations).

require 'rubygems'
require 'optparse'
require 'redis'
require 'hashpipe/keys'

include Hashpipe::RedisKeys


# Computes mcounts per second.  chan_per_pkt must be a factor of 1024 for
# correct results.  Rounds up to the nearest multiple of 2048.
#
def mcnts_per_second(spectra_per_mcnt=8)
  mcnt_per_spectrum = Rational(1, spectra_per_mcnt)

  samples_per_spectrum = 2048
  spectra_per_sample = Rational(1, samples_per_spectrum)

  samples_per_second = 200e6

  (mcnt_per_spectrum * spectra_per_sample * samples_per_second + 2047).to_i / 2048 * 2048
end
#p mcnts_per_second; exit


OPTS = {
  :num_xbox => 8,
  :num_inst => 4,
  :intcount => 2048,
  :intdelay => 10,
  :server   => 'redishost',
}

OP = OptionParser.new do |op|
  op.program_name = File.basename($0)

  op.banner = "Usage: #{op.program_name} [OPTIONS] {start|stop}"
  op.separator('')
  op.separator('Start and stop PAPER correlator integrations')
  op.separator('')
  op.separator('Options:')
  op.on('-d', '--delay=SECONDS', Integer,
        "Delay before starting [#{OPTS[:intdelay]}]") do |o|
    # TODO Put reasonable bounds on it
    OPTS[:intdelay] = o
  end
  op.on('-n', '--intcount=N', Integer,
        "GPU blocks per integration [#{OPTS[:intcount]}]") do |o|
    # TODO Put reasonable bounds on it
    OPTS[:intcount] = o
  end
  op.on('-i', '--numinst=N', Integer,
        "Number of instances per X host [#{OPTS[:num_inst]}]") do |o|
    OPTS[:num_inst] = o
  end
  op.on('-s', '--server=NAME',
        "Host running redis-server [#{OPTS[:server]}]") do |o|
    OPTS[:server] = o
  end
  op.on('-x', '--numxhost=N', Integer,
        "Number of X hosts [#{OPTS[:num_xbox]}]") do |o|
    OPTS[:num_inst] = o
  end
  op.separator('')
  op.on_tail('-h','--help','Show this message') do
    puts op.help
    exit
  end
end
OP.parse!
#p OPTS; exit

cmd = ARGV.shift
if cmd != 'start' && cmd != 'stop' && cmd != 'test'
  puts OP.help
  exit 1
end

# Create status keys for px1/0 to px#{num_xbox}/#{num_inst-1}
xboxes = (1..OPTS[:num_xbox]).to_a
insts  = (0...OPTS[:num_inst]).to_a
STATUS_KEYS = xboxes.product(insts).map {|x,i| status_key("px#{x}", i)}
#p STATUS_KEYS; exit

# Function to get values for Hashpipe status key +skey+ from all Redis keys +hkeys+
# hashes in Redis.
def get_hashpipe_status_values(redis, skey, *hkeys)
  hkeys.flatten.map! do |hk|
    sval = redis.hget(hk, skey)
    block_given? ? yield(sval) : sval
  end
end

def start(redis)
  gpumcnts = get_hashpipe_status_values(redis, 'GPUMCNT', STATUS_KEYS)
  #p gpumcnts
  gpumcnts.compact!
  #p gpumcnts

  if gpumcnts.empty?
    puts "#{File.basename($0)}: no GPUMCNT values found, cannot start"
    return
  end

  if gpumcnts.length != STATUS_KEYS.length
    missing = STATUS_KEYS.length - gpumcnts.length
    puts "#{File.basename($0)}: warning: missing GPUMCNT for #{missing} X engine instances"
  end

  # Convert to ints
  gpumcnts.map! {|s| s.to_i(0)}
  #p gpumcnts

  min_gpumcnt, max_gpumcnt = gpumcnts.minmax
  #p [min_gpumcnt, max_gpumcnt]; exit

  intdelay_mcnts = (((OPTS[:intdelay] * mcnts_per_second) + 2047).floor / 2048) * 2048

  intsync = max_gpumcnt + intdelay_mcnts

  puts "Min GPUMCNT is %d" % min_gpumcnt
  puts "Max GPUMCNT is %d  (range %d)" % [max_gpumcnt, max_gpumcnt - min_gpumcnt]
  puts "Delay  MCNT is %d" % intdelay_mcnts
  puts "Sync   MCNT is %d" % intsync

  start_msg = "INTSYNC=#{intsync}\nINTCOUNT=#{OPTS[:intcount]}\nINTSTAT=start\nOUTDUMPS=0"

  redis.publish(bcast_set_channel, start_msg)
end

def stop(redis)
  intstats = get_hashpipe_status_values(redis, 'INTSTAT', STATUS_KEYS)
  #p intstats
  intstats.compact!
  #p intstats

  if intstats.empty?
    puts "#{File.basename($0)}: no INTSTAT values found, nothing to stop"
    return
  end

  if intstats.length != STATUS_KEYS.length
    missing = STATUS_KEYS.length - intstats.length
    puts "#{File.basename($0)}: warning: missing INTSTAT for #{missing} X engine instances"
  end

  stop_msg = "INTSTAT=stop"

  redis.publish(bcast_set_channel, stop_msg)
end

redis = Redis.new(:host => OPTS[:server])

case cmd
when 'start'; start(redis)
when 'stop' ; stop(redis)
when 'test' ; nil
else
  # Should never happen
  raise "Invalid command: '#{cmd}'"
end
