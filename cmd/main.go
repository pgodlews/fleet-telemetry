package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "go.uber.org/automaxprocs"

	"github.com/airbrake/gobrake/v5"
	"github.com/teslamotors/fleet-telemetry/config"
	logrus "github.com/teslamotors/fleet-telemetry/logger"
	"github.com/teslamotors/fleet-telemetry/server/airbrake"
	"github.com/teslamotors/fleet-telemetry/server/monitoring"
	"github.com/teslamotors/fleet-telemetry/server/streaming"
)

// shutdownGrace is how long an orderly shutdown may take before open
// connections are dropped so publishers still get closed.
const shutdownGrace = 20 * time.Second

func main() {
	var err error

	config, logger, err := config.LoadApplicationConfiguration()
	if err != nil {
		// logger is not available yet
		panic(fmt.Sprintf("error=load_service_config value=\"%s\"", err.Error()))
	}

	if config.Monitoring != nil && config.Monitoring.ProfilingPath != "" {
		if config.Monitoring.ProfilerFile, err = os.Create(config.Monitoring.ProfilingPath); err != nil {
			logger.ErrorLog("profiling_file_error", err, nil)
			config.Monitoring.ProfilingPath = ""
		}

		defer func() {
			config.MetricCollector.Shutdown()
			_ = config.Monitoring.ProfilerFile.Close()
		}()
	}

	airbrakeNotifier, _, err := config.CreateAirbrakeNotifier(logger)
	if err != nil {
		panic(err)
	}
	if airbrakeNotifier != nil {
		defer airbrakeNotifier.NotifyOnPanic()
		defer func() {
			if err := airbrakeNotifier.Close(); err != nil {
				logger.ErrorLog("airbrake_close_error", err, nil)
			}
		}()
	}
	if err := startServer(config, airbrakeNotifier, logger); err != nil {
		panic(err)
	}
}

func startServer(config *config.Config, airbrakeNotifier *gobrake.Notifier, logger *logrus.Logger) (err error) {
	logger.ActivityLog("starting_server", nil)
	registry := streaming.NewSocketRegistry()

	airbrakeHandler := airbrake.NewAirbrakeHandler(airbrakeNotifier)

	if config.StatusPort > 0 {
		monitoring.StartStatusServer(config, logger, airbrakeHandler)
	}
	if config.Monitoring != nil {
		monitoring.StartServerMetrics(config, logger, registry)
	}

	dispatchers, producerRules, err := config.ConfigureProducers(airbrakeHandler, logger, false)
	if err != nil {
		return err
	}
	server, _, err := streaming.InitServer(config, airbrakeHandler, producerRules, logger, registry)
	if err != nil {
		return err
	}

	if server.TLSConfig, err = config.ExtractServiceTLSConfig(logger); err != nil {
		return err
	}

	// Coordinated shutdown. Without this, SIGTERM (how the container stops)
	// killed the process outright: connections were cut mid-message and
	// producers never got their Close, so anything a dispatcher still held
	// unflushed was lost. Producers are closed below on the normal return
	// path once Shutdown has stopped accepting and drained in-flight work.
	shutdownDone := make(chan struct{})
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		defer close(shutdownDone)
		sig, ok := <-sigCh
		if !ok {
			return
		}
		logger.ActivityLog("shutdown_signal", logrus.LogInfo{"signal": sig.String()})
		ctx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
		defer cancel()
		if shutdownErr := server.Shutdown(ctx); shutdownErr != nil {
			logger.ErrorLog("server_shutdown_error", shutdownErr, nil)
			// Deadline passed with sockets still open — drop them so the
			// producer Close calls below still run.
			_ = server.Close()
		}
	}()

	err = server.ListenAndServeTLS(config.TLS.ServerCert, config.TLS.ServerKey)
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	signal.Stop(sigCh)
	close(sigCh)
	<-shutdownDone

	for dispatcher, producer := range dispatchers {
		logger.ActivityLog("attempting_to_close", logrus.LogInfo{"dispatcher": dispatcher})
		// We don't care if this fails. If it does, we'll just continue on.
		if dispatcherCloseErr := producer.Close(); dispatcherCloseErr != nil {
			logger.ErrorLog("producer_close_error", dispatcherCloseErr, logrus.LogInfo{"dispatcher": dispatcher})
		}
	}
	logger.ActivityLog("stopped_server", nil)
	return err
}
