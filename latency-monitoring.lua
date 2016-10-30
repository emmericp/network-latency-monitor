local moon      = require "libmoon"
local device    = require "device"
local stats     = require "stats"
local histogram = require "histogram"
local log       = require "log"
local memory    = require "memory"
local timer     = require "timer"
local ts        = require "timestamping"
local arp       = require "proto.arp"
local icmp      = require "proto.icmp"
local graphite  = require "graphite"

-- set constants here
local PKT_LEN   = 60
local SRC_PORT  = 1233
local NUM_PORTS = 1024 -- actual src port is SRC_PORT + math.random(NUM_PORTS)

-- the configure function is called on startup with a pre-initialized command line parser
function configure(parser)
	parser:argument("txDev", "Transmit device to use."):args(1):convert(tonumber)
	parser:argument("rxDev", "Receive device to use."):args(1):convert(tonumber)
	parser:option("--interval", "Seconds between reports."):args(1):default(10)
	parser:option("--gateway", "IP address of the gateway."):args(1):count(1)
	parser:option("--src", "Source IP address."):args(1):count(1)
	parser:option("--dst", "Destination IP address."):args(1):count(1)
	parser:option("--port", "Destination UDP port."):args(1):default(319)
	parser:option("--out-dir", "Store latency histograms as CSV in the given directory"):args(1):target("outDir")
	parser:option("--graphite", "Graphite server to write results to."):args(1)
	parser:option("--graphite-prefix", "Prefix for the graphite metric."):args(1):default("latency-monitoring"):target("graphitePrefix")
end

function master(args)
	local txDev = device.config{
		port = args.txDev,
		txQueues = 3,
		rxQueues = 3
	}
	local rxDev = device.config{
		port = args.rxDev,
		txQueues = 3,
		rxQueues = 3
	}
	device.waitForLinks()
	arp.startArpTask({
		{rxQueue = txDev:getRxQueue(1), txQueue = txDev:getTxQueue(1), ips = args.src},
		{rxQueue = rxDev:getRxQueue(1), txQueue = rxDev:getTxQueue(1), ips = args.dst},
		gratArpInterval = 1 -- just to prevent flooding in poorly configured networks
	})
	icmp.startIcmpTask({ -- use queue 0 to support NICs that don't have 5tuple filters
		{rxQueue = txDev:getRxQueue(0), txQueue = txDev:getTxQueue(0), ips = args.src},
		{rxQueue = rxDev:getRxQueue(0), txQueue = rxDev:getTxQueue(0), ips = args.dst}
	})

	log:info("Performing ARP lookup on %s.", args.gateway)
	local mac = arp.blockingLookup(args.gateway, 30)
	log:info("Destination mac: %s", mac)
	pinger(txDev:getTxQueue(2), rxDev:getRxQueue(2), mac, args)
	moon.waitForTasks()
end

function pinger(txQueue, rxQueue, dstMac, args)
	local timestamper = ts:newUdpTimestamper(txQueue, rxQueue)
	local nextReport = time() + args.interval
	local hist = histogram:new()
	local rateLimit = timer:new(0.001)
	local writer = args.graphite and graphite.newWriter(args.graphite, args.graphitePrefix)
	local packetsRx = 0
	local packetsTx = 0
	while moon.running() do
		if time() >= nextReport then
			nextReport = nextReport + args.interval
			hist:print()
			if args.outDir then
				hist:save(args.outDir .. "/hist-" .. os.date("%Y-%m-%d %H:%M:%S", os.time()))
			end
			if writer then
				writer:write("num", hist:totals())
				writer:write("lost", packetsTx - packetsRx)
				writer:write("min", hist:min())
				writer:write("median", hist:median())
				writer:write("max", hist:max())
				writer:write("99th", hist:percentile(99))
			end
			hist = histogram:new()
			packetsRx = 0
			packetsTx = 0
		end
		local lat, numPkts = timestamper:measureLatency(function(buf)
			buf:getUdpPacket():fill{
				ethSrc = txQueue,
				ethDst = dstMac,
				ip4Src = args.src,
				ip4Dst = args.dst,
				udpSrc = SRC_PORT + math.random(NUM_PORTS),
				udpDst = args.port
			}
		end)
		if lat then
			hist:update(lat)
		end
		packetsRx = packetsRx + numPkts
		packetsTx = packetsTx + 1
		rateLimit:wait()
		rateLimit:reset()
	end
end

