package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"time"

	"golang.org/x/net/ipv6"
)

func main() {
	ifaceName := "bridge1"
	prefixStr := "240e:462:9354:368a::"
	interval := 3

	if len(os.Args) >= 2 {
		ifaceName = os.Args[1]
	}
	if len(os.Args) >= 3 {
		prefixStr = os.Args[2]
	}
	if len(os.Args) >= 4 {
		fmt.Sscanf(os.Args[3], "%d", &interval)
	}
	dnsStr := "2400:3200::1,2400:3200:baba::1"
	if len(os.Args) >= 5 {
		dnsStr = os.Args[4]
	}

	prefixIP := net.ParseIP(prefixStr).To16()
	if prefixIP == nil {
		fmt.Fprintln(os.Stderr, "invalid prefix")
		os.Exit(1)
	}

	iface, err := net.InterfaceByName(ifaceName)
	if err != nil {
		fmt.Fprintf(os.Stderr, "iface error: %v\n", err)
		os.Exit(1)
	}

	var dnsServers []net.IP
	for _, s := range strings.Split(dnsStr, ",") {
		s = strings.TrimSpace(s)
		if ip := net.ParseIP(s); ip != nil {
			dnsServers = append(dnsServers, ip.To16())
		}
	}

	conn, err := net.ListenPacket("ip6:ipv6-icmp", "::")
	if err != nil {
		fmt.Fprintf(os.Stderr, "socket error: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	// 使用 ipv6.PacketConn 设置 Hop Limit = 255（RFC 4861 要求）
	pconn := ipv6.NewPacketConn(conn)
	if err := pconn.SetHopLimit(255); err != nil {
		fmt.Fprintf(os.Stderr, "set hop limit: %v\n", err)
	}
	if err := pconn.SetMulticastHopLimit(255); err != nil {
		fmt.Fprintf(os.Stderr, "set mcast hop limit: %v\n", err)
	}

	mcastDst := &net.IPAddr{IP: net.ParseIP("ff02::1"), Zone: ifaceName}
	ra := buildRA(iface.HardwareAddr, prefixIP, dnsServers)

	fmt.Printf("send_ra: iface=%s prefix=%s interval=%ds (mcast+unicast)\n", ifaceName, prefixStr, interval)

	cm := &ipv6.ControlMessage{HopLimit: 255}
	for {
		// 1. 发送组播 RA (Hop Limit 必须为 255，RFC 4861)
		pconn.WriteTo(ra, cm, mcastDst)

		// 2. 发送单播 RA 给所有已知客户端（链路本地地址）
		clients := getLinkLocalClients(ifaceName)
		for _, clientIP := range clients {
			ucastDst := &net.IPAddr{IP: clientIP, Zone: ifaceName}
			pconn.WriteTo(ra, cm, ucastDst)
		}

		time.Sleep(time.Duration(interval) * time.Second)
	}
}

// getLinkLocalClients 从 ip -6 neigh 读取链路本地地址（fe80::），排除网关自身
func getLinkLocalClients(ifaceName string) []net.IP {
	var clients []net.IP

	out, err := exec.Command("ip", "-6", "neigh", "show", "dev", ifaceName).Output()
	if err != nil {
		return clients
	}

	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// 格式: fe80::xxxx lladdr xx:xx:xx:xx:xx:xx REACHABLE
		fields := strings.Fields(line)
		if len(fields) < 1 {
			continue
		}
		ipStr := fields[0]
		if !strings.HasPrefix(ipStr, "fe80:") {
			continue
		}
		// 排除 FAILED 状态
		if strings.Contains(line, "FAILED") {
			continue
		}
		ip := net.ParseIP(ipStr)
		if ip != nil {
			clients = append(clients, ip)
		}
	}
	return clients
}

func buildRA(srcMAC net.HardwareAddr, prefix []byte, dnsServers []net.IP) []byte {
	buf := make([]byte, 0, 64)
	buf = append(buf, 134, 0, 0, 0)
	// RA flags: M=0, O=0 (pure SLAAC) - addr/route/DNS all via RA
	buf = append(buf, 64, 0x00, 0x07, 0x08)
	buf = append(buf, 0, 0, 0, 0, 0, 0, 0, 0)
	// Prefix info: type=3, length=4, prefixLen=64, flags=0xC0 (L=1, A=1)
	buf = append(buf, 3, 4, 64, 0xC0)
	var b4 [4]byte
	binary.BigEndian.PutUint32(b4[:], 86400)
	buf = append(buf, b4[:]...)
	binary.BigEndian.PutUint32(b4[:], 14400)
	buf = append(buf, b4[:]...)
	buf = append(buf, 0, 0, 0, 0)
	buf = append(buf, prefix...)
	// MTU option: type=5, length=1
	buf = append(buf, 5, 1, 0, 0)
	binary.BigEndian.PutUint32(b4[:], 1280)
	buf = append(buf, b4[:]...)
	// RDNSS option (type=25, RFC 8106): length = 1 + 2*numDNS (in 8-byte units)
	if len(dnsServers) > 0 {
		rdnssLen := byte(1 + 2*len(dnsServers))
		buf = append(buf, 25, rdnssLen)
		// reserved (2 bytes) + lifetime (4 bytes) = 6 bytes
		buf = append(buf, 0, 0)
		binary.BigEndian.PutUint32(b4[:], 86400) // 24h lifetime
		buf = append(buf, b4[:]...)
		for _, dns := range dnsServers {
			buf = append(buf, dns.To16()...)
		}
	}
	return buf
}
