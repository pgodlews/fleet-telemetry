package postgres

// Config controls the PostgreSQL/TimescaleDB dispatcher.
type Config struct {
	// ConnString is a libpq-style URL, e.g.
	//   postgres://user:pass@host:5432/tesla?sslmode=disable
	ConnString string `json:"conn_string"`

	// MaxConns caps the size of the underlying pgxpool. 0 = pgx default.
	MaxConns int32 `json:"max_conns"`

	// MinConns sets the warm pool floor. 0 = pgx default.
	MinConns int32 `json:"min_conns"`
}
