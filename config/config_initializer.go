package config

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/sirupsen/logrus/hooks/test"

	"github.com/teslamotors/fleet-telemetry/datastore/simple"
	logrus "github.com/teslamotors/fleet-telemetry/logger"
	"github.com/teslamotors/fleet-telemetry/metrics"
	"github.com/teslamotors/fleet-telemetry/telemetry"
)

var (
	maxVinsToTrack = 20
)

// LoadApplicationConfiguration loads the configuration from args and config files
func LoadApplicationConfiguration() (config *Config, logger *logrus.Logger, err error) {

	logger, err = logrus.NewBasicLogrusLogger("fleet-telemetry")
	if err != nil {
		return nil, nil, err
	}
	log.SetOutput(logger)

	configFilePath := loadConfigFlags()

	config, err = loadApplicationConfig(configFilePath)
	if err != nil {
		return nil, nil, err
	}

	config.configureLogger(logger)
	config.configureMetricsCollector(logger)
	return config, logger, nil
}

func loadApplicationConfig(configFilePath string) (*Config, error) {
	configFile, err := os.Open(configFilePath)
	if err != nil {
		return nil, err
	}

	config := &Config{
		LoggerConfig: &simple.Config{},
	}
	err = json.NewDecoder(configFile).Decode(&config)
	if err != nil {
		return nil, err
	}

	log, _ := test.NewNullLogger()
	logger, err := logrus.NewLogrusLogger("null_logger", map[string]interface{}{}, log.WithField("context", "metrics"))
	if err != nil {
		return nil, err
	}

	if err := validateConfig(config); err != nil {
		return nil, err
	}
	config.MetricCollector = metrics.NewCollector(config.Monitoring, logger)
	config.AckChan = make(chan *telemetry.Record)
	return config, err
}

func validateConfig(config *Config) error {
	if len(config.VinsToTrack()) > maxVinsToTrack {
		return fmt.Errorf("set the value of `vins_signal_tracking_enabled` less than %d unique vins", maxVinsToTrack)
	}
	return config.configureRateLimit()
}

// configureRateLimit converts the JSON `message_interval_time` (seconds) into
// the duration the socket actually rate limits on, and rejects bounds the
// underlying limiter cannot honor. Without this the duration stays zero and
// the limit never triggers; a non-positive limit panics the limiter on the
// first message.
func (c *Config) configureRateLimit() error {
	if c.RateLimit == nil || !c.RateLimit.Enabled {
		return nil
	}
	if c.RateLimit.MessageLimit <= 0 {
		return fmt.Errorf("rate_limit.message_limit must be greater than 0 when rate limiting is enabled, got %d", c.RateLimit.MessageLimit)
	}
	if c.RateLimit.MessageInterval <= 0 {
		return fmt.Errorf("rate_limit.message_interval_time must be greater than 0 seconds when rate limiting is enabled, got %d", c.RateLimit.MessageInterval)
	}
	c.RateLimit.MessageIntervalTimeSecond = time.Duration(c.RateLimit.MessageInterval) * time.Second
	return nil
}

func loadConfigFlags() string {
	applicationConfig := ""
	flag.StringVar(&applicationConfig, "config", "config.json", "application configuration file")

	flag.Parse()
	return applicationConfig
}
