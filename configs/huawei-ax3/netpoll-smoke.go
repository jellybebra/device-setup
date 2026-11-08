// Standalone on-device check for the Go eventfd-to-pipe fallback.
package main

import (
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func main() {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	must(err)
	defer l.Close()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, err := net.DialTimeout("tcp4", l.Addr().String(), 3*time.Second)
			must(err)
			defer c.Close()
			for j := 0; j < 20; j++ {
				must(c.SetDeadline(time.Now().Add(3 * time.Second)))
				_, err = c.Write([]byte("wakeup"))
				must(err)
				b := make([]byte, 6)
				_, err = io.ReadFull(c, b)
				must(err)
				if string(b) != "wakeup" {
					panic("corrupted echo")
				}
				time.Sleep(time.Millisecond)
			}
			must(c.SetReadDeadline(time.Now().Add(20 * time.Millisecond)))
			_, err = c.Read(make([]byte, 1))
			if e, ok := err.(net.Error); !ok || !e.Timeout() {
				panic("deadline did not fire")
			}
		}()
	}
	wg.Wait()
	u, err := net.ListenPacket("udp4", "127.0.0.1:0")
	must(err)
	defer u.Close()
	v, err := net.Dial("udp4", u.LocalAddr().String())
	must(err)
	defer v.Close()
	must(u.SetDeadline(time.Now().Add(3 * time.Second)))
	_, err = v.Write([]byte("udp"))
	must(err)
	b := make([]byte, 10)
	n, _, err := u.ReadFrom(b)
	must(err)
	if string(b[:n]) != "udp" {
		panic("corrupted UDP")
	}
	fmt.Println("PASS: 160 TCP echoes, concurrent timers, eight read deadlines, UDP")
}
