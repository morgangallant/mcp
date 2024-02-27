package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/joho/godotenv"
)

var logLevels = map[string]slog.Level{
	"DEBUG": slog.LevelDebug,
	"INFO":  slog.LevelInfo,
	"WARN":  slog.LevelWarn,
	"ERROR": slog.LevelError,
}

var (
	production_once   sync.Once
	production_cached bool
)

func production() bool {
	production_once.Do(func() {
		hostname, err := os.Hostname()
		if err != nil {
			panic(err)
		}
		production_cached = runtime.GOOS != "darwin" && hostname != "mbp"
	})
	return production_cached
}

func main() {
	_ = godotenv.Load()

	var logLevel slog.Level
	if level, ok := logLevels[os.Getenv("LOG_LEVEL")]; ok {
		logLevel = level
	}

	var logger *slog.Logger
	if production() {
		logger = slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
			Level: logLevel,
		}))
	} else {
		logLevel = slog.LevelDebug
		logger = slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
			Level: logLevel,
		}))
	}

	rctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	if err := run(rctx, logger, cancel); err != nil {
		logger.Error("top-level error", slog.String("error", err.Error()))
		os.Exit(1)
	}
}

func run(ctx context.Context, logger *slog.Logger, shutdown context.CancelFunc) error {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "End of line.")
	})

	var port uint16 = 8080
	if portStr, ok := os.LookupEnv("PORT"); ok {
		parsed, err := strconv.ParseUint(portStr, 10, 16)
		if err != nil {
			return fmt.Errorf("parsing PORT: %w", err)
		}
		port = uint16(parsed)
	} else if production() {
		port = 80
	}

	httpAddr := fmt.Sprintf("0.0.0.0:%d", port)
	httpSrv := &http.Server{
		Addr:         httpAddr,
		Handler:      mux,
		ReadTimeout:  time.Second,
		WriteTimeout: time.Second * 10,
	}
	go func() {
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error(
				"http server failed, initiating shutdown",
				slog.String("error", err.Error()),
			)
			shutdown()
		}
	}()
	defer func() {
		sctx, cancel := context.WithTimeout(context.Background(), time.Second*3)
		defer cancel()
		if err := httpSrv.Shutdown(sctx); err != nil {
			logger.Warn("http server shutdown failed", slog.String("error", err.Error()))
		}
	}()

	<-ctx.Done()
	return nil
}
