package main

import (
	"context"
	"github.com/miekg/dns"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPerQueryFallbackAndAliases(t *testing.T) {
	primaryCalls := 0
	primary := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		primaryCalls++
		w.WriteHeader(503)
	}))
	defer primary.Close()
	backup := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		q := new(dns.Msg)
		_ = q.Unpack(data)
		a := new(dns.Msg).SetReply(q)
		a.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET}, A: net.ParseIP("64.29.17.67")}}
		wire, _ := a.Pack()
		_, _ = w.Write(wire)
	}))
	defer backup.Close()
	s := selector{client: http.DefaultClient, servers: []string{primary.URL, backup.URL}}
	for _, rewrite := range []bool{true, false, true} {
		a, err := s.query(context.Background(), new(dns.Msg).SetQuestion("example.com.", dns.TypeA), rewrite)
		if err != nil {
			t.Fatal(err)
		}
		expected := "64.29.17.67"
		if rewrite {
			expected = "64.29.17.195"
		}
		if ip := a.Answer[0].(*dns.A).A.String(); ip != expected {
			t.Fatalf("got %s, want %s", ip, expected)
		}
	}
	if primaryCalls != 3 {
		t.Fatalf("primary attempts = %d", primaryCalls)
	}
}
