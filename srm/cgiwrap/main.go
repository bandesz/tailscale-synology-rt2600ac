// CGI entry for the SRM admin server. Apache runs this as the web user,
// which tailscaled treats as read-only. The file is installed setuid root
// so the process that connects to the daemon is root.
package main

import (
	"fmt"
	"os"
	"syscall"
)

func main() {
	err := syscall.Exec(
		"/var/packages/Tailscale/target/bin/tailscale",
		[]string{
			"tailscale",
			"--socket", "/var/packages/Tailscale/var/tailscaled.sock",
			"web", "-cgi",
			"-prefix", "/webman/3rdparty/Tailscale/index.cgi/",
		},
		os.Environ(),
	)
	fmt.Printf("Status: 500\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nexec tailscale: %v\n", err)
	os.Exit(1)
}
