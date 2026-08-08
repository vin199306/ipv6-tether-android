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
	ifaceName := ""
	prefixStr := ""
	interval := 3
	mtu := 1280

	if len(os.Args) >= 2 {
		ifaceName = os.Args[1]
	}
	if len(os.Args) >= 3 {
		prefixStr = os.Args[2]
	}
	if len(os.Args) >= 4 {
		if n, err := fmt.Sscanf(os.Args[3], "%d", &interval); n != 1 || err != nil {
			fmt.Fprintf(os.Stderr, "warning: invalid interval %q, using default %d\n", os.Args[3], interval)
		}
	}
	dnsStr := "2400:3200::1,2400:3200:baba::1"
	if len(os.Args) >= 5 {
		dnsStr = os.Args[4]
	}
	if len(os.Args) >= 6 {
		if n, err := fmt.Sscanf(os.Args[5], "%d", &mtu); n != 1 || err != nil {
			fmt.Fprintf(os.Stderr, "warning: invalid mtu %q, using default %d\n", os.Args[5], mtu)
		}
	}
	// Optional 7th arg: old prefix to deprecate (lifetime=0)
	oldPrefixStr := ""
	if len(os.Args) >= 7 {
		oldPrefixStr = os.Args[6]
	}

	if ifaceName == "" || prefixStr == "" {
		fmt.Fprintln(os.Stderr, "usage: send_ra <iface> <prefix> [interval] [dns] [mtu] [old_prefix]")
		os.Exit(1)
	}

	prefixIP := net.ParseIP(prefixStr).To16()
	if prefixIP == nil {
		fmt.Fprintf(os.Stderr, "invalid prefix: %s\n", prefixStr)
		os.Exit(1)
	}

	var oldPrefixIP net.IP
	if oldPrefixStr != "" {
		oldPrefixIP = net.ParseIP(oldPrefixStr).To16()
		if oldPrefixIP == nil {
			fmt.Fprintf(os.Stderr, "warning: invalid old prefix %s, ignoring\n", oldPrefixStr)
		}
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

	pconn := ipv6.NewPacketConn(conn)
	if err := pconn.SetHopLimit(255); err != nil {
		fmt.Fprintf(os.Stderr, "set hop limit: %v\n", err)
	}
	if err := pconn.SetMulticastHopLimit(255); err != nil {
		fmt.Fprintf(os.Stderr, "set mcast hop limit: %v\n", err)
	}

	mcastDst := &net.IPAddr{IP: net.ParseIP("ff02::1"), Zone: ifaceName}
	ra := buildRA(iface.HardwareAddr, prefixIP, dnsServers, oldPrefixIP, mtu)

	fmt.Printf("send_ra: iface=%s prefix=%s interval=%ds mtu=%d (mcast+unicast+rs)\n", ifaceName, prefixStr, interval, mtu)
	if oldPrefixIP != nil {
		fmt.Printf("send_ra: deprecating old prefix=%s (lifetime=0)\n", oldPrefixStr)
	}

	cm := &ipv6.ControlMessage{HopLimit: 255}

	// goroutine: 监听 Router Solicitation 并立即响应 RA
	go func() {
		buf := make([]byte, 1500)
		for {
			n, _, err := conn.ReadFrom(buf)
			if err != nil {
				continue
			}
			// ICMPv6 type 133 = Router Solicitation
			if n > 0 && buf[0] == 133 {
				if _, err := pconn.WriteTo(ra, cm, mcastDst); err != nil {
					fmt.Fprintf(os.Stderr, "rs-response write error: %v\n", err)
				}
			}
		}
	}()

	for {
		// 1. 发送组播 RA (Hop Limit 必须为 255，RFC 4861)
		if _, err := pconn.WriteTo(ra, cm, mcastDst); err != nil {
			fmt.Fprintf(os.Stderr, "mcast write error: %v\n", err)
		}

		// 2. 发送单播 RA 给所有已知客户端（链路本地地址）
		clients := getLinkLocalClients(ifaceName)
		for _, clientIP := range clients {
			ucastDst := &net.IPAddr{IP: clientIP, Zone: ifaceName}
			if _, err := pconn.WriteTo(ra, cm, ucastDst); err != nil {
				fmt.Fprintf(os.Stderr, "ucast write error to %s: %v\n", clientIP, err)
			}
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
		fields := strings.Fields(line)
		if len(fields) < 1 {
			continue
		}
		ipStr := fields[0]
		if !strings.HasPrefix(ipStr, "fe80:") {
			continue
		}
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

func buildRA(srcMAC net.HardwareAddr, prefix []byte, dnsServers []net.IP, oldPrefix []byte, mtu int) []byte {
	buf := make([]byte, 0, 96)
	buf = append(buf, 134, 0, 0, 0)
	// RA flags: M=0, O=0 (pure SLAAC) - addr/route/DNS all via RA
	buf = append(buf, 64, 0x00, 0x07, 0x08)
	buf = append(buf, 0, 0, 0, 0, 0, 0, 0, 0)
	// Source Link-Layer Address option (type=1, length=1, RFC 4861)
	// 让客户端无需发送 NS 即可获知路由器 MAC
	if len(srcMAC) == 6 {
		buf = append(buf, 1, 1)
		buf = append(buf, srcMAC...)
	}
	// Prefix info: type=3, length=4, prefixLen=64, flags=0xC0 (L=1, A=1)
	buf = append(buf, 3, 4, 64, 0xC0)
	var b4 [4]byte
	binary.BigEndian.PutUint32(b4[:], 86400)
	buf = append(buf, b4[:]...)
	binary.BigEndian.PutUint32(b4[:], 14400)
	buf = append(buf, b4[:]...)
	buf = append(buf, 0, 0, 0, 0)
	buf = append(buf, prefix...)
	// Deprecated prefix info (if any): same structure but lifetime=0
	// This forces clients to immediately remove the old address (RFC 4861)
	if oldPrefix != nil {
		buf = append(buf, 3, 4, 64, 0xC0)
		binary.BigEndian.PutUint32(b4[:], 0) // valid_lifetime=0
		buf = append(buf, b4[:]...)
		binary.BigEndian.PutUint32(b4[:], 0) // preferred_lifetime=0
		buf = append(buf, b4[:]...)
		buf = append(buf, 0, 0, 0, 0)
		buf = append(buf, oldPrefix...)
	}
	// MTU option: type=5, length=1
	buf = append(buf, 5, 1, 0, 0)
	binary.BigEndian.PutUint32(b4[:], uint32(mtu))
	buf = append(buf, b4[:]...)
	// RDNSS option (type=25, RFC 8106): length = 1 + 2*numDNS (in 8-byte units)
	if len(dnsServers) > 0 {
		rdnssLen := byte(1 + 2*len(dnsServers))
		buf = append(buf, 25, rdnssLen)
		buf = append(buf, 0, 0)
		binary.BigEndian.PutUint32(b4[:], 86400) // 24h lifetime
		buf = append(buf, b4[:]...)
		for _, dns := range dnsServers {
			buf = append(buf, dns.To16()...)
		}
	}
	return buf
}
