const serial = @import("serial.zig");
const virtio_net = @import("virtio_net.zig");
const builtin = @import("builtin");

// --- Static network configuration ---
pub const OUR_IP = [4]u8{ 172, 16, 0, 2 };
pub const OUR_NETMASK = [4]u8{ 255, 255, 255, 0 };
pub const GATEWAY_IP = [4]u8{ 172, 16, 0, 1 };

// Ethertypes (big-endian)
const ETHERTYPE_IPV4: u16 = 0x0800;
const ETHERTYPE_ARP: u16 = 0x0806;

// IP protocols
const PROTO_UDP: u8 = 17;

const BROADCAST_MAC = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

// --- Ethernet ---

const EthHeader = extern struct {
    dst: [6]u8,
    src: [6]u8,
    ethertype: [2]u8, // big-endian
};

const ETH_HDR_SIZE = @sizeOf(EthHeader);

// Frame assembly buffer (used for building outgoing frames)
var frame_buf: [1514]u8 = undefined; // 14 eth + 1500 payload max

fn ethSend(dst_mac: [6]u8, ethertype: u16, payload: []const u8) bool {
    if (payload.len > 1500) return false;
    const our_mac = virtio_net.getMac();

    // Build ethernet header
    for (0..6) |i| frame_buf[i] = dst_mac[i];
    for (0..6) |i| frame_buf[6 + i] = our_mac[i];
    frame_buf[12] = @intCast(ethertype >> 8);
    frame_buf[13] = @intCast(ethertype & 0xFF);

    // Copy payload
    for (0..payload.len) |i| {
        frame_buf[ETH_HDR_SIZE + i] = payload[i];
    }

    const total = ETH_HDR_SIZE + payload.len;
    return virtio_net.txPacket(frame_buf[0..total]);
}

fn parseEthHeader(frame: []u8) ?struct { ethertype: u16, payload: []u8 } {
    if (frame.len < ETH_HDR_SIZE) return null;
    const et: u16 = (@as(u16, frame[12]) << 8) | @as(u16, frame[13]);
    return .{ .ethertype = et, .payload = frame[ETH_HDR_SIZE..] };
}

// --- ARP ---

const ArpPacket = extern struct {
    htype: [2]u8, // 0x0001 = Ethernet
    ptype: [2]u8, // 0x0800 = IPv4
    hlen: u8, // 6
    plen: u8, // 4
    oper: [2]u8, // 1=request, 2=reply
    sha: [6]u8, // sender MAC
    spa: [4]u8, // sender IP
    tha: [6]u8, // target MAC
    tpa: [4]u8, // target IP
};

const ARP_SIZE = @sizeOf(ArpPacket);

const ArpEntry = struct {
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    valid: bool = false,
};

const ARP_TABLE_SIZE = 8;
var arp_table: [ARP_TABLE_SIZE]ArpEntry = [_]ArpEntry{.{}} ** ARP_TABLE_SIZE;

fn arpLookup(ip: [4]u8) ?[6]u8 {
    for (arp_table) |entry| {
        if (entry.valid and ipEql(entry.ip, ip)) return entry.mac;
    }
    return null;
}

fn arpStore(ip: [4]u8, mac_val: [6]u8) void {
    // Update existing or find free slot
    for (&arp_table) |*entry| {
        if (entry.valid and ipEql(entry.ip, ip)) {
            entry.mac = mac_val;
            return;
        }
    }
    for (&arp_table) |*entry| {
        if (!entry.valid) {
            entry.ip = ip;
            entry.mac = mac_val;
            entry.valid = true;
            return;
        }
    }
    // Table full — overwrite first entry
    arp_table[0] = .{ .ip = ip, .mac = mac_val, .valid = true };
}

fn arpSendRequest(target_ip: [4]u8) void {
    var pkt: ArpPacket = undefined;
    pkt.htype = .{ 0x00, 0x01 };
    pkt.ptype = .{ 0x08, 0x00 };
    pkt.hlen = 6;
    pkt.plen = 4;
    pkt.oper = .{ 0x00, 0x01 }; // request
    pkt.sha = virtio_net.getMac();
    pkt.spa = OUR_IP;
    pkt.tha = .{ 0, 0, 0, 0, 0, 0 };
    pkt.tpa = target_ip;

    const bytes: *const [ARP_SIZE]u8 = @ptrCast(&pkt);
    _ = ethSend(BROADCAST_MAC, ETHERTYPE_ARP, bytes);
}

fn arpSendReply(target_mac: [6]u8, target_ip: [4]u8) void {
    var pkt: ArpPacket = undefined;
    pkt.htype = .{ 0x00, 0x01 };
    pkt.ptype = .{ 0x08, 0x00 };
    pkt.hlen = 6;
    pkt.plen = 4;
    pkt.oper = .{ 0x00, 0x02 }; // reply
    pkt.sha = virtio_net.getMac();
    pkt.spa = OUR_IP;
    pkt.tha = target_mac;
    pkt.tpa = target_ip;

    const bytes: *const [ARP_SIZE]u8 = @ptrCast(&pkt);
    _ = ethSend(target_mac, ETHERTYPE_ARP, bytes);
}

fn arpProcess(payload: []u8) void {
    if (payload.len < ARP_SIZE) return;
    const pkt: *const ArpPacket = @ptrCast(@alignCast(payload.ptr));

    // Only handle Ethernet/IPv4 ARP
    if (pkt.htype[0] != 0x00 or pkt.htype[1] != 0x01) return;
    if (pkt.ptype[0] != 0x08 or pkt.ptype[1] != 0x00) return;

    // Store sender in ARP table
    arpStore(pkt.spa, pkt.sha);

    const oper: u16 = (@as(u16, pkt.oper[0]) << 8) | @as(u16, pkt.oper[1]);

    if (oper == 1 and ipEql(pkt.tpa, OUR_IP)) {
        // ARP request for us — send reply
        arpSendReply(pkt.sha, pkt.spa);
    }
}

/// Resolve IP to MAC. Sends ARP request if not cached.
/// Retries a few times with short delays.
pub fn arpResolve(ip: [4]u8) ?[6]u8 {
    // Check cache first
    if (arpLookup(ip)) |m| return m;

    // Send ARP request and poll for reply
    var attempts: u32 = 0;
    while (attempts < 5) : (attempts += 1) {
        arpSendRequest(ip);

        // Poll for a bit
        var spins: u32 = 0;
        while (spins < 100_000) : (spins += 1) {
            processIncoming();
            if (arpLookup(ip)) |m| return m;
            if (comptime builtin.cpu.arch == .x86_64) {
                asm volatile ("pause");
            }
        }
    }
    return null;
}

// --- IPv4 ---

const Ipv4Header = extern struct {
    ver_ihl: u8, // 0x45 = IPv4, 20 bytes
    tos: u8,
    total_len: [2]u8, // big-endian
    id: [2]u8,
    flags_frag: [2]u8,
    ttl: u8,
    protocol: u8,
    checksum: [2]u8,
    src: [4]u8,
    dst: [4]u8,
};

const IPV4_HDR_SIZE = @sizeOf(Ipv4Header);

var ip_id_counter: u16 = 1;

// IP packet assembly buffer
var ip_buf: [1500]u8 = undefined;

fn ipChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | @as(u32, data[i + 1]);
    }
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @intCast(~sum & 0xFFFF);
}

fn ipSend(dst_ip: [4]u8, protocol: u8, payload: []const u8) bool {
    if (payload.len > 1500 - IPV4_HDR_SIZE) return false;

    const total_len: u16 = @intCast(IPV4_HDR_SIZE + payload.len);

    // Build IP header in ip_buf
    var hdr: *Ipv4Header = @ptrCast(@alignCast(&ip_buf));
    hdr.ver_ihl = 0x45;
    hdr.tos = 0;
    hdr.total_len = .{ @intCast(total_len >> 8), @intCast(total_len & 0xFF) };
    hdr.id = .{ @intCast(ip_id_counter >> 8), @intCast(ip_id_counter & 0xFF) };
    ip_id_counter +%= 1;
    hdr.flags_frag = .{ 0x40, 0x00 }; // Don't Fragment
    hdr.ttl = 64;
    hdr.protocol = protocol;
    hdr.checksum = .{ 0, 0 };
    hdr.src = OUR_IP;
    hdr.dst = dst_ip;

    // Compute checksum
    const cksum = ipChecksum(ip_buf[0..IPV4_HDR_SIZE]);
    hdr.checksum = .{ @intCast(cksum >> 8), @intCast(cksum & 0xFF) };

    // Copy payload after header
    for (0..payload.len) |i| {
        ip_buf[IPV4_HDR_SIZE + i] = payload[i];
    }

    // Determine destination MAC
    var next_hop = dst_ip;
    if (!sameSubnet(dst_ip, OUR_IP, OUR_NETMASK)) {
        next_hop = GATEWAY_IP;
    }

    const dst_mac = arpResolve(next_hop) orelse {
        serial.writeAll("net: ARP resolve failed\n");
        return false;
    };

    return ethSend(dst_mac, ETHERTYPE_IPV4, ip_buf[0..total_len]);
}

fn ipProcess(payload: []u8) void {
    if (payload.len < IPV4_HDR_SIZE) return;
    const hdr: *const Ipv4Header = @ptrCast(@alignCast(payload.ptr));

    // Only handle IPv4
    if ((hdr.ver_ihl & 0xF0) != 0x40) return;
    const ihl: usize = @as(usize, hdr.ver_ihl & 0x0F) * 4;
    if (ihl < IPV4_HDR_SIZE or ihl > payload.len) return;

    // Check destination is us
    if (!ipEql(hdr.dst, OUR_IP)) return;

    if (hdr.protocol == PROTO_UDP) {
        udpProcessIncoming(hdr.src, payload[ihl..]);
    }
}

// --- UDP ---

const UdpHeader = extern struct {
    src_port: [2]u8, // big-endian
    dst_port: [2]u8, // big-endian
    length: [2]u8, // big-endian
    checksum: [2]u8, // 0 = no checksum
};

const UDP_HDR_SIZE = @sizeOf(UdpHeader);

pub const MaxUdpSockets = 16;

const RX_BUF_SIZE = 2048;

pub const UdpSocket = struct {
    in_use: bool = false,
    local_port: u16 = 0,
    remote_ip: [4]u8 = .{ 0, 0, 0, 0 },
    remote_port: u16 = 0,
    bound: bool = false,
    connected: bool = false,
    // Simple RX buffer (single packet)
    rx_buf: [RX_BUF_SIZE]u8 = undefined,
    rx_len: usize = 0,
    rx_src_ip: [4]u8 = .{ 0, 0, 0, 0 },
    rx_src_port: u16 = 0,
    has_data: bool = false,
};

pub var udp_sockets: [MaxUdpSockets]UdpSocket = [_]UdpSocket{.{}} ** MaxUdpSockets;

// UDP send assembly buffer
var udp_buf: [1472]u8 = undefined; // 1500 - 20 (IP) - 8 (UDP)

pub fn udpSocketInit(idx: u32) void {
    if (idx >= MaxUdpSockets) return;
    udp_sockets[idx] = .{ .in_use = true };
}

pub fn udpSocketClose(idx: u32) void {
    if (idx >= MaxUdpSockets) return;
    udp_sockets[idx] = .{};
}

pub fn udpBind(idx: u32, port: u16) bool {
    if (idx >= MaxUdpSockets) return false;
    if (!udp_sockets[idx].in_use) return false;
    udp_sockets[idx].local_port = port;
    udp_sockets[idx].bound = true;
    return true;
}

pub fn udpConnect(idx: u32, ip: [4]u8, port: u16) bool {
    if (idx >= MaxUdpSockets) return false;
    if (!udp_sockets[idx].in_use) return false;
    udp_sockets[idx].remote_ip = ip;
    udp_sockets[idx].remote_port = port;
    udp_sockets[idx].connected = true;
    return true;
}

pub fn udpSend(idx: u32, data: []const u8) bool {
    if (idx >= MaxUdpSockets) return false;
    const sock = &udp_sockets[idx];
    if (!sock.in_use or !sock.connected) return false;
    if (data.len > 1472 - UDP_HDR_SIZE) return false;

    const udp_len: u16 = @intCast(UDP_HDR_SIZE + data.len);

    // Build UDP header
    udp_buf[0] = @intCast(sock.local_port >> 8);
    udp_buf[1] = @intCast(sock.local_port & 0xFF);
    udp_buf[2] = @intCast(sock.remote_port >> 8);
    udp_buf[3] = @intCast(sock.remote_port & 0xFF);
    udp_buf[4] = @intCast(udp_len >> 8);
    udp_buf[5] = @intCast(udp_len & 0xFF);
    udp_buf[6] = 0; // checksum = 0 (valid for UDP over IPv4)
    udp_buf[7] = 0;

    // Copy data
    for (0..data.len) |i| {
        udp_buf[UDP_HDR_SIZE + i] = data[i];
    }

    return ipSend(sock.remote_ip, PROTO_UDP, udp_buf[0..udp_len]);
}

fn udpProcessIncoming(src_ip: [4]u8, payload: []u8) void {
    if (payload.len < UDP_HDR_SIZE) return;

    const dst_port: u16 = (@as(u16, payload[2]) << 8) | @as(u16, payload[3]);
    const src_port: u16 = (@as(u16, payload[0]) << 8) | @as(u16, payload[1]);
    const udp_len_raw: u16 = (@as(u16, payload[4]) << 8) | @as(u16, payload[5]);

    if (udp_len_raw < UDP_HDR_SIZE or udp_len_raw > payload.len) return;
    const data_len = udp_len_raw - UDP_HDR_SIZE;
    const data = payload[UDP_HDR_SIZE .. UDP_HDR_SIZE + data_len];

    // Find matching socket
    for (&udp_sockets) |*sock| {
        if (!sock.in_use) continue;
        if (sock.bound and sock.local_port == dst_port) {
            // Deliver to this socket
            const copy_len = if (data.len > RX_BUF_SIZE) RX_BUF_SIZE else data.len;
            for (0..copy_len) |i| {
                sock.rx_buf[i] = data[i];
            }
            sock.rx_len = copy_len;
            sock.rx_src_ip = src_ip;
            sock.rx_src_port = src_port;
            sock.has_data = true;
            return;
        }
    }
}

pub fn udpRecv(idx: u32, buf: []u8) ?usize {
    if (idx >= MaxUdpSockets) return null;
    const sock = &udp_sockets[idx];
    if (!sock.in_use or !sock.has_data) return null;

    const copy_len = if (sock.rx_len > buf.len) buf.len else sock.rx_len;
    for (0..copy_len) |i| {
        buf[i] = sock.rx_buf[i];
    }
    sock.has_data = false;
    sock.rx_len = 0;
    return copy_len;
}

pub fn udpPollReadable(idx: u32) bool {
    if (idx >= MaxUdpSockets) return false;
    return udp_sockets[idx].in_use and udp_sockets[idx].has_data;
}

// --- Main receive loop ---

pub fn processIncoming() void {
    // Drain all available RX frames
    while (virtio_net.rxPoll()) |frame| {
        const parsed = parseEthHeader(frame) orelse continue;
        switch (parsed.ethertype) {
            ETHERTYPE_ARP => arpProcess(parsed.payload),
            ETHERTYPE_IPV4 => ipProcess(parsed.payload),
            else => {},
        }
    }
}

// --- Helpers ---

fn ipEql(a: [4]u8, b: [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn sameSubnet(a: [4]u8, b: [4]u8, mask: [4]u8) bool {
    return (a[0] & mask[0]) == (b[0] & mask[0]) and
        (a[1] & mask[1]) == (b[1] & mask[1]) and
        (a[2] & mask[2]) == (b[2] & mask[2]) and
        (a[3] & mask[3]) == (b[3] & mask[3]);
}
