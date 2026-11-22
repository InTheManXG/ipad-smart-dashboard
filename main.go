package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

func envDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func healthcheck() error {
	client := &http.Client{Timeout: 3 * time.Second}
	response, err := client.Get("http://127.0.0.1:18086/api/mode")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	var value Object
	if err := json.NewDecoder(io.LimitReader(response.Body, 1024)).Decode(&value); err != nil {
		return err
	}
	if response.StatusCode != 200 || value["mode"] != envDefault("DISPLAY_MODE", "pairing") {
		return fmt.Errorf("服务模式不正确")
	}
	return nil
}

func run() error {
	health := flag.Bool("healthcheck", false, "检查本地服务是否可用")
	flag.Parse()
	if *health {
		return healthcheck()
	}
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	app, err := newServer(root, envDefault("RELAY_DATA_DIR", filepath.Join(root, ".relay-data")), envDefault("DISPLAY_MODE", "pairing"))
	if err != nil {
		return err
	}
	if app.store != nil {
		defer app.store.Close()
	}
	server := &http.Server{
		Addr: net.JoinHostPort(envDefault("DISPLAY_BIND", "127.0.0.1"), "18086"), Handler: app,
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 8 * time.Second,
		WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10,
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	shutdownDone := make(chan struct{})
	go func() {
		<-ctx.Done()
		// 容器停止时先等待正在确认的指令，再关闭数据库。
		shutdown, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
		close(shutdownDone)
	}()
	log.Print("iPad 看板已启动，端口 18086")
	err = server.ListenAndServe()
	if err == http.ErrServerClosed {
		<-shutdownDone
		return nil
	}
	return err
}

func main() {
	if err := run(); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
