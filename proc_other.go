//go:build !linux

package main

import "syscall"

func childAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true}
}
