package main

import "syscall"

// childAttr puts child processes (lai-engine, MCP servers) in their own
// process group so terminal Ctrl-C doesn't kill them, and has the kernel
// stop them if lai dies without cleaning up.
func childAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGTERM}
}
