// Local upstream for sing-box. Direct DoH sockets stay on the selected physical interface.
package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/miekg/dns"
	"golang.org/x/sys/unix"
)

var aliases = map[string]string{
	"64.29.17.3": "64.29.17.195", "64.29.17.67": "64.29.17.195", "64.29.17.131": "64.29.17.195",
	"216.198.79.3": "216.198.79.195", "216.198.79.67": "216.198.79.195", "216.198.79.131": "216.198.79.195",
}

type selector struct {
	client       *http.Client
	servers      []string
	firstFailure sync.Once
}

func newSelector(iface string) (*selector, error) {
	dev, err := net.InterfaceByName(iface)
	if err != nil {
		return nil, err
	}
	d := net.Dialer{Control: func(network, address string, c syscall.RawConn) error {
		var bindErr error
		err := c.Control(func(fd uintptr) { bindErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, dev.Index) })
		return errors.Join(err, bindErr)
	}}
	transport := &http.Transport{DialContext: d.DialContext, ForceAttemptHTTP2: true, MaxIdleConnsPerHost: 8}
	return &selector{client: &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
		servers: []string{"https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"}}, nil
}

func (s *selector) query(ctx context.Context, q *dns.Msg, rewrite bool) (*dns.Msg, error) {
	wire, err := q.Pack()
	if err != nil {
		return nil, err
	}
	var failures []error
	for i, url := range s.servers {
		limit := 4 * time.Second
		if i == 0 {
			limit = time.Second
		}
		attempt, cancel := context.WithTimeout(ctx, limit)
		answer, err := s.exchange(attempt, url, wire, q)
		cancel()
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", url, err))
			continue
		}
		if rewrite {
			for _, rr := range answer.Answer {
				if a, ok := rr.(*dns.A); ok {
					if ip, ok := aliases[a.A.String()]; ok {
						a.A = net.ParseIP(ip)
						answer.AuthenticatedData = false
					}
				}
			}
		}
		return answer, nil
	}
	return nil, fmt.Errorf("direct DoH: %w", errors.Join(failures...))
}

func (s *selector) exchange(ctx context.Context, url string, wire []byte, q *dns.Msg) (*dns.Msg, error) {
	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(wire))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("DoH HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 65536))
	if err != nil {
		return nil, err
	}
	a := new(dns.Msg)
	if err = a.Unpack(body); err != nil {
		return nil, err
	}
	if !a.Response || a.Id != q.Id || len(a.Question) != 1 || a.Question[0].Qclass != q.Question[0].Qclass || a.Question[0].Qtype != q.Question[0].Qtype || !strings.EqualFold(a.Question[0].Name, q.Question[0].Name) || a.Truncated || a.Rcode == dns.RcodeServerFailure {
		return nil, errors.New("invalid DNS response")
	}
	return a, nil
}
func (s *selector) ServeDNS(w dns.ResponseWriter, q *dns.Msg) {
	var a *dns.Msg
	if len(q.Question) == 1 {
		var err error
		a, err = s.query(context.Background(), q, true)
		if err != nil {
			s.firstFailure.Do(func() { fmt.Fprintln(os.Stderr, "DoH:", strings.ReplaceAll(err.Error(), "\n", " / ")) })
		}
	}
	if a == nil {
		a = new(dns.Msg).SetRcode(q, dns.RcodeServerFailure)
	}
	_ = w.WriteMsg(a)
}
func main() {
	iface := flag.String("interface", "", "physical interface")
	port := flag.Uint("port", 0, "loopback DNS port")
	name := flag.String("resolve", "", "resolve an endpoint before starting TUN")
	flag.Parse()
	s, err := newSelector(*iface)
	if err == nil && *name != "" {
		q := new(dns.Msg).SetQuestion(dns.Fqdn(*name), dns.TypeA)
		var a *dns.Msg
		a, err = s.query(context.Background(), q, false)
		if err == nil {
			for _, rr := range a.Answer {
				if ip, ok := rr.(*dns.A); ok {
					fmt.Println(ip.A)
					return
				}
			}
			err = errors.New("no endpoint A record")
		}
	} else if err == nil && *port > 0 && *port <= 65535 {
		server := dns.Server{Addr: fmt.Sprintf("127.0.0.1:%d", *port), Net: "tcp", Handler: s}
		err = server.ListenAndServe()
	} else if err == nil {
		err = errors.New("missing port")
	}
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
