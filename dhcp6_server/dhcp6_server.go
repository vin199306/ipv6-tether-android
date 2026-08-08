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

// DHCPv6 消息类型
const (
	MsgSolicit     = 1
	MsgAdvertise   = 2
	MsgRequest     = 3
	MsgConfirm     = 4
	MsgRenew       = 5
	MsgRebind      = 6
	MsgReply       = 7
	MsgRelease     = 8
	MsgDecline     = 9
	MsgInfoRequest = 11
)

// DHCPv6 选项类型
const (
	OptClientID    = 1
	OptServerID    = 2
	OptIANA        = 3
	OptIAAddr      = 5
	OptORO         = 6
	OptPreference  = 7
	OptRapidCommit = 14
	OptDNS         = 23
	OptDomain      = 24
	OptRoute       = 34 // RFC 7078
)

func main() {
	ifaceName := "bridge1"
	prefixStr := "240e:462:9264:3a33::"
	dnsStr := "2400:3200::1,2400:3200:baba::1"

	if len(os.Args) >= 2 {
		ifaceName = os.Args[1]
	}
	if len(os.Args) >= 3 {
		prefixStr = os.Args[2]
	}
	if len(os.Args) >= 4 {
		dnsStr = os.Args[3]
	}

	prefix := net.ParseIP(prefixStr).To16()
	if prefix == nil {
		fmt.Fprintln(os.Stderr, "invalid prefix")
		os.Exit(1)
	}

	iface, err := net.InterfaceByName(ifaceName)
	if err != nil {
		fmt.Fprintf(os.Stderr, "iface error: %v\n", err)
		os.Exit(1)
	}

	serverID := buildServerID(iface.HardwareAddr)

	var dnsServers []net.IP
	for _, s := range splitDNS(dnsStr) {
		ip := net.ParseIP(s)
		if ip != nil {
			dnsServers = append(dnsServers, ip.To16())
		}
	}

	// 获取接口的链路本地地址作为网关
	var gateway net.IP
	if addrs, err := iface.Addrs(); err == nil {
		for _, addr := range addrs {
			if ipnet, ok := addr.(*net.IPNet); ok {
				if ipnet.IP.IsLinkLocalUnicast() {
					gateway = ipnet.IP.To16()
					break
				}
			}
		}
	}
	if gateway == nil {
		gateway = net.ParseIP("fe80::1")
	}
	fmt.Printf("dhcp6_server: gateway=%s\n", gateway)

	// 监听 DHCPv6 端口 547，绑定到接口
	conn, err := net.ListenUDP("udp6", &net.UDPAddr{
		IP:   net.IPv6unspecified,
		Port: 547,
		Zone: ifaceName,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen error: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	// 加入 All DHCPv6 Relay Agents and Servers 组播组 ff02::1:2
	pconn := ipv6.NewPacketConn(conn)
	mcastAddr := net.ParseIP("ff02::1:2")
	if err := pconn.JoinGroup(iface, &net.UDPAddr{IP: mcastAddr}); err != nil {
		fmt.Fprintf(os.Stderr, "join mcast ff02::1:2: %v\n", err)
	}

	fmt.Printf("dhcp6_server: iface=%s prefix=%s dns=%v\n", ifaceName, prefixStr, dnsServers)

	buf := make([]byte, 1500)
	for {
		n, addr, err := conn.ReadFrom(buf)
		if err != nil {
			fmt.Fprintf(os.Stderr, "read: %v\n", err)
			continue
		}

		msg := buf[:n]
		if len(msg) < 4 {
			continue
		}

		msgType := msg[0]
		txID := msg[1:4]
		opts := parseOptions(msg[4:])

		switch msgType {
		case MsgSolicit:
			handleSolicit(conn, addr, txID, opts, serverID, prefix, dnsServers, gateway)
		case MsgRequest:
			handleRequest(conn, addr, txID, opts, serverID, prefix, dnsServers, gateway)
		case MsgInfoRequest:
			handleInfoRequest(conn, addr, txID, opts, serverID, dnsServers, gateway)
		case MsgRenew, MsgRebind:
			handleRenew(conn, addr, txID, opts, serverID, prefix, dnsServers, gateway)
		}
	}
}

func splitDNS(s string) []string {
	var result []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == ',' {
			result = append(result, s[start:i])
			start = i + 1
		}
	}
	result = append(result, s[start:])
	return result
}

func buildServerID(mac net.HardwareAddr) []byte {
	duid := make([]byte, 0, 14)
	duid = append(duid, 0x00, 0x02) // type=2 (DUID-LLT)
	duid = append(duid, 0x00, 0x01) // hwtype=1 (Ethernet)
	duid = append(duid, 0x00, 0x00, 0x00, 0x01)
	duid = append(duid, mac...)
	return duid
}

func parseOptions(data []byte) map[uint16][]byte {
	opts := make(map[uint16][]byte)
	for len(data) >= 4 {
		optCode := binary.BigEndian.Uint16(data[0:2])
		optLen := int(binary.BigEndian.Uint16(data[2:4]))
		if len(data) < 4+optLen {
			break
		}
		opts[optCode] = data[4 : 4+optLen]
		data = data[4+optLen:]
	}
	return opts
}

func extractClientMAC(opts map[uint16][]byte) net.HardwareAddr {
	clientID, ok := opts[OptClientID]
	if !ok || len(clientID) < 14 {
		return nil
	}
	duidType := binary.BigEndian.Uint16(clientID[0:2])
	switch duidType {
	case 1: // DUID-LLT
		if len(clientID) >= 14 {
			return net.HardwareAddr(clientID[8:14])
		}
	case 3: // DUID-LL
		if len(clientID) >= 10 {
			return net.HardwareAddr(clientID[4:10])
		}
	}
	return nil
}

func extractIAID(iaNa []byte) (uint32, []byte) {
	if len(iaNa) < 12 {
		return 0, nil
	}
	iaid := binary.BigEndian.Uint32(iaNa[0:4])
	return iaid, iaNa[12:]
}

func macToEUI64(mac net.HardwareAddr) []byte {
	eui := make([]byte, 8)
	eui[0] = mac[0] ^ 0x02
	eui[1] = mac[1]
	eui[2] = mac[2]
	eui[3] = 0xFF
	eui[4] = 0xFE
	eui[5] = mac[3]
	eui[6] = mac[4]
	eui[7] = mac[5]
	return eui
}

func generateAddr(prefix []byte, mac net.HardwareAddr) net.IP {
	if mac == nil {
		mac = net.HardwareAddr{0x02, 0x00, 0x00, 0x00, 0x00, 0x01}
	}
	addr := make([]byte, 16)
	copy(addr[:8], prefix[:8])
	eui := macToEUI64(mac)
	copy(addr[8:], eui)
	return net.IP(addr)
}

func buildOption(code uint16, data []byte) []byte {
	buf := make([]byte, 4+len(data))
	binary.BigEndian.PutUint16(buf[0:2], code)
	binary.BigEndian.PutUint16(buf[2:4], uint16(len(data)))
	copy(buf[4:], data)
	return buf
}

func buildIANA(iaid uint32, addr net.IP, prefLife, validLife uint32) []byte {
	iaNaData := make([]byte, 12)
	binary.BigEndian.PutUint32(iaNaData[0:4], iaid)
	binary.BigEndian.PutUint32(iaNaData[4:8], prefLife/2)
	binary.BigEndian.PutUint32(iaNaData[8:12], prefLife*3/4)

	iaAddrData := make([]byte, 24)
	copy(iaAddrData[0:16], addr.To16())
	binary.BigEndian.PutUint32(iaAddrData[16:20], prefLife)
	binary.BigEndian.PutUint32(iaAddrData[20:24], validLife)

	iaNaData = append(iaNaData, buildOption(OptIAAddr, iaAddrData)...)
	return buildOption(OptIANA, iaNaData)
}

// buildDefaultRoute 构建 ::/0 默认路由选项 (RFC 7078 OPTION_ROUTE)
// gateway 必须是链路本地地址
func buildDefaultRoute(gateway net.IP) []byte {
	routeData := make([]byte, 0, 25)
	// prefix length: 0 (default route)
	routeData = append(routeData, 0)
	// preference: 0 (medium)
	routeData = append(routeData, 0)
	// reserved (1 byte)
	routeData = append(routeData, 0)
	// prefix: :: (16 bytes, all zeros for default route)
	routeData = append(routeData, make([]byte, 16)...)
	// gateway: link-local address of the router (16 bytes)
	routeData = append(routeData, gateway.To16()...)
	return buildOption(OptRoute, routeData)
}

func buildDNS(dnsServers []net.IP) []byte {
	data := make([]byte, 0, 16*len(dnsServers))
	for _, dns := range dnsServers {
		data = append(data, dns.To16()...)
	}
	return buildOption(OptDNS, data)
}

func handleSolicit(conn net.PacketConn, addr net.Addr, txID []byte, opts map[uint16][]byte, serverID []byte, prefix []byte, dnsServers []net.IP, gateway net.IP) {
	clientID := opts[OptClientID]
	if clientID == nil {
		return
	}

	_, hasRapidCommit := opts[OptRapidCommit]

	clientMAC := extractClientMAC(opts)
	udpAddr := addr.(*net.UDPAddr)
	if clientMAC == nil {
		clientMAC = getNeighborMAC(udpAddr.IP)
	}

	addr6 := generateAddr(prefix, clientMAC)

	var resp []byte
	if hasRapidCommit {
		resp = buildReply(txID, clientID, serverID, opts, addr6, dnsServers, gateway)
	} else {
		resp = buildAdvertise(txID, clientID, serverID, opts, addr6, dnsServers, gateway)
	}

	conn.WriteTo(resp, addr)
	fmt.Printf("[dhcp6] SOLICIT from %s -> %s addr=%s\n", udpAddr.IP, msgTypeName(resp[0]), addr6)
}

func handleRequest(conn net.PacketConn, addr net.Addr, txID []byte, opts map[uint16][]byte, serverID []byte, prefix []byte, dnsServers []net.IP, gateway net.IP) {
	clientID := opts[OptClientID]
	if clientID == nil {
		return
	}

	clientMAC := extractClientMAC(opts)
	udpAddr := addr.(*net.UDPAddr)
	if clientMAC == nil {
		clientMAC = getNeighborMAC(udpAddr.IP)
	}

	addr6 := generateAddr(prefix, clientMAC)
	resp := buildReply(txID, clientID, serverID, opts, addr6, dnsServers, gateway)
	conn.WriteTo(resp, addr)
	fmt.Printf("[dhcp6] REQUEST from %s -> REPLY addr=%s\n", udpAddr.IP, addr6)
}

func handleInfoRequest(conn net.PacketConn, addr net.Addr, txID []byte, opts map[uint16][]byte, serverID []byte, dnsServers []net.IP, gateway net.IP) {
	clientID := opts[OptClientID]
	if clientID == nil {
		return
	}

	resp := make([]byte, 0, 256)
	resp = append(resp, MsgReply)
	resp = append(resp, txID...)
	resp = append(resp, buildOption(OptClientID, clientID)...)
	resp = append(resp, buildOption(OptServerID, serverID)...)
	resp = append(resp, buildDNS(dnsServers)...)
	resp = append(resp, buildDefaultRoute(gateway)...)

	conn.WriteTo(resp, addr)
	udpAddr := addr.(*net.UDPAddr)
	fmt.Printf("[dhcp6] INFO-REQUEST from %s -> REPLY (DNS+route)\n", udpAddr.IP)
}

func handleRenew(conn net.PacketConn, addr net.Addr, txID []byte, opts map[uint16][]byte, serverID []byte, prefix []byte, dnsServers []net.IP, gateway net.IP) {
	clientID := opts[OptClientID]
	if clientID == nil {
		return
	}

	clientMAC := extractClientMAC(opts)
	udpAddr := addr.(*net.UDPAddr)
	if clientMAC == nil {
		clientMAC = getNeighborMAC(udpAddr.IP)
	}

	addr6 := generateAddr(prefix, clientMAC)
	resp := buildReply(txID, clientID, serverID, opts, addr6, dnsServers, gateway)
	conn.WriteTo(resp, addr)
	fmt.Printf("[dhcp6] RENEW from %s -> REPLY addr=%s\n", udpAddr.IP, addr6)
}

func buildAdvertise(txID, clientID, serverID []byte, opts map[uint16][]byte, addr6 net.IP, dnsServers []net.IP, gateway net.IP) []byte {
	resp := make([]byte, 0, 512)
	resp = append(resp, MsgAdvertise)
	resp = append(resp, txID...)
	resp = append(resp, buildOption(OptClientID, clientID)...)
	resp = append(resp, buildOption(OptServerID, serverID)...)

	if iaNa, ok := opts[OptIANA]; ok {
		iaid, _ := extractIAID(iaNa)
		resp = append(resp, buildIANA(iaid, addr6, 14400, 86400)...)
	}

	resp = append(resp, buildOption(OptPreference, []byte{255})...)
	resp = append(resp, buildDNS(dnsServers)...)
	resp = append(resp, buildDefaultRoute(gateway)...)
	return resp
}

func buildReply(txID, clientID, serverID []byte, opts map[uint16][]byte, addr6 net.IP, dnsServers []net.IP, gateway net.IP) []byte {
	resp := make([]byte, 0, 512)
	resp = append(resp, MsgReply)
	resp = append(resp, txID...)
	resp = append(resp, buildOption(OptClientID, clientID)...)
	resp = append(resp, buildOption(OptServerID, serverID)...)

	if iaNa, ok := opts[OptIANA]; ok {
		iaid, _ := extractIAID(iaNa)
		resp = append(resp, buildIANA(iaid, addr6, 14400, 86400)...)
	}

	resp = append(resp, buildDNS(dnsServers)...)
	resp = append(resp, buildDefaultRoute(gateway)...)
	return resp
}

// getNeighborMAC 从链路本地地址反推MAC（EUI-64规则）
func getNeighborMAC(ip net.IP) net.HardwareAddr {
	if ip.IsLinkLocalUnicast() && len(ip) == 16 {
		mac := make([]byte, 6)
		mac[0] = ip[8] ^ 0x02
		mac[1] = ip[9]
		mac[2] = ip[10]
		mac[3] = ip[13]
		mac[4] = ip[14]
		mac[5] = ip[15]
		return net.HardwareAddr(mac)
	}
	// 尝试从邻居表获取
	out, err := exec.Command("ip", "neigh", "show").Output()
	if err == nil {
		lines := strings.Split(string(out), "\n")
		for _, line := range lines {
			fields := strings.Fields(line)
			if len(fields) >= 5 && fields[0] == ip.String() {
				mac, err := net.ParseMAC(fields[4])
				if err == nil {
					return mac
				}
			}
		}
	}
	return nil
}

func msgTypeName(b byte) string {
	switch b {
	case MsgAdvertise:
		return "ADVERTISE"
	case MsgReply:
		return "REPLY"
	default:
		return fmt.Sprintf("MSG(%d)", b)
	}
}

var _ = time.Second
